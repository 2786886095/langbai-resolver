from __future__ import annotations

import asyncio
import shutil
import uuid
from pathlib import Path

import yt_dlp
from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

from app.config import settings
from app.models import (
    CreateJobRequest,
    DownloadJob,
    HealthResponse,
    MediaInfo,
    MusicFile,
    MusicSearchResult,
    ResolveRequest,
    SniffRequest,
    SniffResponse,
    TransferRequest,
    UpdateManifest,
    UpdatePlatformRelease,
)
from app.services.extractor import ResolverService
from app.services.jobs import JobManager
from app.services.music import OpenMusicService
from app.services.security import UnsafeUrlError
from app.services.sniffer import SnifferService

app = FastAPI(
    title="langbai解析 API",
    version="1.0.3",
    description="公开、无 DRM 媒体的统一解析与下载服务。",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=list(settings.cors_origins),
    allow_credentials=settings.cors_origins != ("*",),
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

resolver = ResolverService(settings)
jobs = JobManager(settings, resolver)
sniffer = SnifferService(settings)
music = OpenMusicService(
    jamendo_client_id=settings.jamendo_client_id,
    audius_api_key=settings.audius_api_key,
)


@app.get("/api/v1/health", response_model=HealthResponse)
def health() -> HealthResponse:
    ffmpeg = (
        settings.ffmpeg_location.is_file()
        if settings.ffmpeg_location
        else shutil.which("ffmpeg") is not None
    )
    return HealthResponse(
        status="ok",
        extractor=f"yt-dlp {yt_dlp.version.__version__}",
        ffmpeg_available=ffmpeg,
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
        return await resolver.resolve(
            request.url,
            use_browser_cookies=request.use_browser_cookies,
        )
    except UnsafeUrlError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except yt_dlp.utils.DownloadError as exc:
        message = str(exc).rsplit("ERROR:", 1)[-1].strip()
        raise HTTPException(status_code=422, detail=message[:500]) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"解析失败：{str(exc)[:400]}") from exc


@app.post("/api/v1/jobs", response_model=DownloadJob, status_code=202)
async def create_job(request: CreateJobRequest) -> DownloadJob:
    try:
        return jobs.create(request.media_id, request.option_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc).strip("'")) from exc


@app.get("/api/v1/jobs/{job_id}", response_model=DownloadJob)
def get_job(job_id: str) -> DownloadJob:
    job = jobs.get(job_id)
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
        return await asyncio.to_thread(sniffer.sniff, request.url)
    except UnsafeUrlError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"网页嗅探失败：{str(exc)[:400]}") from exc


@app.post("/api/v1/tools/process", response_model=DownloadJob, status_code=202)
async def process_local_media(
    file: UploadFile = File(...),
    operation: str = Form(...),
    output_format: str = Form(""),
    quality: int = Form(78),
) -> DownloadJob:
    suffix = Path(file.filename or "media.bin").suffix.lower()
    if len(suffix) > 12 or not all(character.isalnum() or character == "." for character in suffix):
        suffix = ".bin"
    upload_dir = settings.download_dir / "_uploads"
    upload_dir.mkdir(parents=True, exist_ok=True)
    upload_path = upload_dir / f"{uuid.uuid4().hex}{suffix}"
    written = 0
    max_size = 4 * 1024 * 1024 * 1024
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
    except Exception as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"创建工具任务失败：{str(exc)[:300]}") from exc
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
                    raise HTTPException(status_code=413, detail="种子文件不能超过 32 MB")
                output.write(chunk)
        return jobs.create_torrent_file(upload_path)
    except HTTPException:
        upload_path.unlink(missing_ok=True)
        raise
    except Exception as exc:
        upload_path.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"创建种子任务失败：{str(exc)[:300]}") from exc
    finally:
        await file.close()


@app.get("/api/v1/tools/status")
def tool_status() -> dict[str, bool]:
    return {
        "ffmpeg": shutil.which("ffmpeg") is not None,
        "ffprobe": shutil.which("ffprobe") is not None,
        "aria2": shutil.which("aria2c") is not None,
        "segmented_direct_download": True,
        "static_web_sniff": True,
        "open_music_search": True,
    }


@app.get("/api/v1/music/search", response_model=list[MusicSearchResult])
async def search_music(
    q: str = Query(min_length=1, max_length=160),
) -> list[MusicSearchResult]:
    try:
        return await asyncio.to_thread(music.search, q)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"音乐来源查询失败：{str(exc)[:300]}") from exc


@app.get("/api/v1/music/{identifier}/files", response_model=list[MusicFile])
async def music_files(identifier: str) -> list[MusicFile]:
    try:
        return await asyncio.to_thread(music.files, identifier)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"音乐文件查询失败：{str(exc)[:300]}") from exc


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host=settings.host, port=settings.port, reload=False)
