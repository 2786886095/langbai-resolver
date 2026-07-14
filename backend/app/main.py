from __future__ import annotations

import asyncio
import hmac
import ipaddress
import re
import shutil
import uuid
from contextlib import asynccontextmanager
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yt_dlp
from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

from app.config import settings
from app.models import (
    CreateJobRequest,
    DownloadJob,
    HealthResponse,
    MediaInfo,
    MusicFile,
    MusicSearchResult,
    MusicSourceStatus,
    ResolveRequest,
    SniffRequest,
    SniffResponse,
    TransferRequest,
    UpdateManifest,
    UpdatePlatformRelease,
)
from app.services.extractor import (
    ResolverService,
    clean_ytdlp_error,
)
from app.services.jobs import JobManager, QueueFullError, StorageLimitError
from app.services.music import OpenMusicService
from app.services.security import UnsafeUrlError
from app.services.sniffer import SnifferService


@asynccontextmanager
async def lifespan(_app: FastAPI):
    yield
    manager = globals().get("jobs")
    if manager is not None:
        manager.shutdown()
    executor = globals().get("analysis_executor")
    if executor is not None:
        executor.shutdown(wait=False, cancel_futures=True)


app = FastAPI(
    title="langbai解析 API",
    version="1.1.6",
    description="公开、无 DRM 媒体的统一解析与下载服务。",
    lifespan=lifespan,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=list(settings.cors_origins),
    allow_credentials=settings.cors_origins != ("*",),
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["*"],
)


@app.middleware("http")
async def require_instance_token(request: Request, call_next):
    """Require the per-process token for every API route when configured."""
    expected = settings.instance_token
    is_api = request.url.path.startswith("/api/v1/")
    if is_api and expected and request.method != "OPTIONS":
        supplied = request.headers.get("X-Langbai-Instance-Token", "")
        if not hmac.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8")):
            return JSONResponse(
                status_code=401,
                content={
                    "detail": "实例令牌无效",
                    "error_code": "invalid_instance_token",
                },
                headers={"WWW-Authenticate": "Langbai-Instance-Token"},
            )
    elif is_api and not expected:
        if not _request_is_loopback(request):
            return JSONResponse(
                status_code=401,
                content={
                    "detail": "非本机请求必须配置实例令牌",
                    "error_code": "instance_token_required",
                },
                headers={"WWW-Authenticate": "Langbai-Instance-Token"},
            )
        if not _browser_origin_is_allowed(request):
            return JSONResponse(
                status_code=403,
                content={
                    "detail": "未授权的跨站请求",
                    "error_code": "cross_origin_request_denied",
                },
            )
    upload_limit = None
    if request.url.path == "/api/v1/tools/process":
        upload_limit = settings.max_upload_bytes + 1024 * 1024
    elif request.url.path == "/api/v1/tools/torrent":
        upload_limit = 33 * 1024 * 1024
    if upload_limit is not None:
        declared = request.headers.get("content-length")
        try:
            if declared and int(declared) > upload_limit:
                return JSONResponse(
                    status_code=413,
                    content={
                        "detail": "上传请求超过服务器限制",
                        "error_code": "upload_too_large",
                    },
                )
        except ValueError:
            return JSONResponse(
                status_code=400,
                content={
                    "detail": "Content-Length 无效",
                    "error_code": "invalid_content_length",
                },
            )
    return await call_next(request)


resolver = ResolverService(settings)
jobs = JobManager(settings, resolver)
sniffer = SnifferService(settings)
music = OpenMusicService(
    jamendo_client_id=settings.jamendo_client_id,
    audius_api_key=settings.audius_api_key,
)
analysis_slots = asyncio.Semaphore(max(2, settings.max_concurrent_jobs * 2))
analysis_executor = ThreadPoolExecutor(
    max_workers=max(2, settings.max_concurrent_jobs * 2),
    thread_name_prefix="langbai-analysis",
)


def _is_loopback_address(value: object) -> bool:
    host = str(value or "").strip().strip("[]").split("%", 1)[0].lower()
    if host in {"localhost", "localhost.localdomain"}:
        return True
    try:
        address = ipaddress.ip_address(host)
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            return address.ipv4_mapped.is_loopback
        return address.is_loopback
    except ValueError:
        return False


def _request_is_loopback(request: Request) -> bool:
    client_host = request.client.host if request.client else ""
    server = request.scope.get("server")
    server_host = server[0] if isinstance(server, (tuple, list)) and server else ""
    return _is_loopback_address(client_host) and _is_loopback_address(server_host)


def _browser_origin_is_allowed(request: Request) -> bool:
    origin = request.headers.get("origin")
    if origin:
        return origin != "null" and origin in settings.cors_origins
    return request.headers.get("sec-fetch-site", "").lower() != "cross-site"


async def _analysis_call(function, *args):
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(analysis_executor, lambda: function(*args))


def _safe_detail(value: object, limit: int = 400) -> str:
    message = clean_ytdlp_error(value).replace(
        str(settings.download_dir), "<download-dir>"
    )
    message = re.sub(r"(https?://[^\s?]+)\?[^\s]+", r"\1?<redacted>", message)
    return message[:limit]


def _media_binary_available(name: str) -> bool:
    if settings.ffmpeg_location and name in {"ffmpeg", "ffprobe"}:
        location = settings.ffmpeg_location
        if location.is_dir():
            return (location / name).is_file() or (location / f"{name}.exe").is_file()
        candidate = location if name == "ffmpeg" else location.with_name("ffprobe")
        return candidate.is_file() or candidate.with_suffix(".exe").is_file()
    return shutil.which(name) is not None


@app.get("/api/v1/health", response_model=HealthResponse)
def health() -> HealthResponse:
    ffmpeg = _media_binary_available("ffmpeg")
    return HealthResponse(
        status="ok",
        extractor=f"yt-dlp {yt_dlp.version.__version__}",
        ffmpeg_available=ffmpeg,
        instance_id=settings.instance_id,
        authenticated=bool(settings.instance_token),
    )


@app.get("/api/v1/update", response_model=UpdateManifest)
def update_manifest() -> UpdateManifest:
    """Return the release metadata used by every langbai client."""
    return UpdateManifest(
        version=settings.update_version,
        notes=settings.update_notes,
        platforms={
            "windows": UpdatePlatformRelease(
                url=settings.update_windows_url,
                sha256=settings.update_windows_sha256,
                size_bytes=settings.update_windows_size_bytes,
                signing_certificate_sha256=(
                    settings.update_windows_signing_certificate_sha256
                ),
            ),
            "android": UpdatePlatformRelease(url=settings.update_android_url),
            "ios": UpdatePlatformRelease(url=settings.update_ios_url),
            "web": UpdatePlatformRelease(url=settings.update_web_url),
            "macos": UpdatePlatformRelease(url=settings.update_web_url),
            "linux": UpdatePlatformRelease(url=settings.update_web_url),
        },
    )


@app.post("/api/v1/resolve", response_model=MediaInfo)
async def resolve_media(request: ResolveRequest) -> MediaInfo:
    try:
        async with asyncio.timeout(min(settings.job_timeout_seconds, 120)):
            async with analysis_slots:
                return await resolver.resolve(request.url, request.bilibili_cookie)
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail="解析任务超时") from exc
    except UnsafeUrlError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)[:400]) from exc
    except yt_dlp.utils.DownloadError as exc:
        message = clean_ytdlp_error(exc)
        raise HTTPException(status_code=422, detail=message[:500]) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=502, detail=f"解析失败：{_safe_detail(exc)}"
        ) from exc


@app.post("/api/v1/jobs", response_model=DownloadJob, status_code=202)
async def create_job(request: CreateJobRequest) -> DownloadJob:
    try:
        return jobs.create(request.media_id, request.option_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc).strip("'")) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except QueueFullError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except StorageLimitError as exc:
        raise HTTPException(status_code=507, detail=str(exc)) from exc


@app.get("/api/v1/jobs/{job_id}", response_model=DownloadJob)
def get_job(job_id: str) -> DownloadJob:
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="下载任务不存在或已过期")
    return job


@app.delete("/api/v1/jobs/{job_id}", response_model=DownloadJob)
def cancel_job(job_id: str) -> DownloadJob:
    job = jobs.cancel(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="下载任务不存在或已过期")
    return job


@app.get("/api/v1/jobs/{job_id}/file")
def download_file(job_id: str) -> FileResponse:
    path = jobs.file_for(job_id)
    if not path:
        raise HTTPException(status_code=404, detail="文件尚未就绪或已过期")
    return FileResponse(
        path=Path(path),
        filename=path.name,
        media_type="application/octet-stream",
    )


@app.post("/api/v1/sniff", response_model=SniffResponse)
async def sniff_page(request: SniffRequest) -> SniffResponse:
    try:
        async with asyncio.timeout(min(settings.job_timeout_seconds, 90)):
            async with analysis_slots:
                return await _analysis_call(sniffer.sniff, request.url)
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail="网页嗅探超时") from exc
    except UnsafeUrlError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=422, detail=f"网页嗅探失败：{_safe_detail(exc)}"
        ) from exc


@app.post("/api/v1/tools/process", response_model=DownloadJob, status_code=202)
async def process_local_media(
    file: UploadFile = File(...),
    operation: str = Form(...),
    output_format: str = Form(""),
    quality: int = Form(78),
) -> DownloadJob:
    suffix = Path(file.filename or "media.bin").suffix.lower()
    if len(suffix) > 12 or not all(
        character.isalnum() or character == "." for character in suffix
    ):
        suffix = ".bin"
    upload_dir = settings.download_dir / "_uploads"
    upload_dir.mkdir(parents=True, exist_ok=True)
    upload_path = upload_dir / f"{uuid.uuid4().hex}{suffix}"
    written = 0
    max_size = settings.max_upload_bytes
    try:
        with upload_path.open("wb") as output:
            while chunk := await file.read(1024 * 1024):
                written += len(chunk)
                if written > max_size:
                    raise HTTPException(status_code=413, detail="上传文件不能超过 4 GB")
                output.write(chunk)
        return jobs.create_tool(
            upload_path,
            operation=operation,
            output_format=output_format,
            quality=quality,
            display_name=file.filename,
        )
    except HTTPException:
        upload_path.unlink(missing_ok=True)
        raise
    except ValueError as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except QueueFullError as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except StorageLimitError as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(status_code=507, detail=str(exc)) from exc
    except Exception as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(
            status_code=500, detail=f"创建工具任务失败：{_safe_detail(exc, 300)}"
        ) from exc
    finally:
        await file.close()


@app.post("/api/v1/tools/transfer", response_model=DownloadJob, status_code=202)
async def create_transfer(request: TransferRequest) -> DownloadJob:
    try:
        sources = [item.strip() for item in request.sources if item.strip()]
        if request.source and request.source.strip():
            sources.insert(0, request.source.strip())
        return jobs.create_transfer(sources)
    except (ValueError, UnsafeUrlError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except QueueFullError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except StorageLimitError as exc:
        raise HTTPException(status_code=507, detail=str(exc)) from exc


@app.post("/api/v1/tools/torrent", response_model=DownloadJob, status_code=202)
async def create_torrent_file(file: UploadFile = File(...)) -> DownloadJob:
    if not (file.filename or "").lower().endswith(".torrent"):
        raise HTTPException(status_code=400, detail="请选择 .torrent 种子文件")
    upload_dir = settings.download_dir / "_uploads"
    upload_dir.mkdir(parents=True, exist_ok=True)
    upload_path = upload_dir / f"{uuid.uuid4().hex}.torrent"
    written = 0
    try:
        with upload_path.open("wb") as output:
            while chunk := await file.read(512 * 1024):
                written += len(chunk)
                if written > 32 * 1024 * 1024:
                    raise HTTPException(
                        status_code=413, detail="种子文件不能超过 32 MB"
                    )
                output.write(chunk)
        return jobs.create_torrent_file(upload_path)
    except HTTPException:
        upload_path.unlink(missing_ok=True)
        raise
    except ValueError as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except QueueFullError as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except StorageLimitError as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(status_code=507, detail=str(exc)) from exc
    except Exception as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(
            status_code=500, detail=f"创建种子任务失败：{_safe_detail(exc, 300)}"
        ) from exc
    finally:
        await file.close()


@app.get("/api/v1/tools/status")
def tool_status() -> dict[str, bool]:
    return {
        "ffmpeg": _media_binary_available("ffmpeg"),
        "ffprobe": _media_binary_available("ffprobe"),
        "aria2": shutil.which("aria2c") is not None,
        "segmented_direct_download": True,
        "static_web_sniff": True,
        "open_music_search": True,
        "peer_to_peer": settings.allow_peer_to_peer,
    }


@app.get("/api/v1/music/search", response_model=list[MusicSearchResult])
async def search_music(
    q: str = Query(min_length=1, max_length=160),
) -> list[MusicSearchResult]:
    try:
        async with asyncio.timeout(min(settings.job_timeout_seconds, 90)):
            async with analysis_slots:
                return await _analysis_call(music.search, q)
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail="音乐来源查询超时") from exc
    except Exception as exc:
        raise HTTPException(
            status_code=502, detail=f"音乐来源查询失败：{_safe_detail(exc, 300)}"
        ) from exc


@app.get("/api/v1/music/{identifier}/files", response_model=list[MusicFile])
async def music_files(identifier: str) -> list[MusicFile]:
    try:
        async with asyncio.timeout(min(settings.job_timeout_seconds, 90)):
            async with analysis_slots:
                return await _analysis_call(music.files, identifier)
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail="音乐文件查询超时") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=502, detail=f"音乐文件查询失败：{_safe_detail(exc, 300)}"
        ) from exc


@app.get("/api/v1/music/sources", response_model=list[MusicSourceStatus])
def music_sources() -> list[MusicSourceStatus]:
    return music.source_statuses()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host=settings.host, port=settings.port, reload=False)
