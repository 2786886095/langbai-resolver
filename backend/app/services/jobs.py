from __future__ import annotations

import asyncio
import json
import multiprocessing
import os
import queue
import re
import signal
import shutil
# Media processing requires fixed argv subprocesses; shell execution is never used.
import subprocess  # nosec B404
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

import httpx
import yt_dlp
from PIL import Image, ImageOps, ImageSequence

from app.config import Settings
from app.models import DownloadJob, JobState
from app.services.extractor import (
    DownloadSpec,
    ResolverService,
    SafeYoutubeDL,
    temporary_bilibili_cookie_file,
)
from app.services.security import (
    UnsafeUrlError,
    stream_public_response_async,
    validate_public_url,
)


_ANSI_ESCAPE_RE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")


class QueueFullError(RuntimeError):
    pass


class StorageLimitError(RuntimeError):
    pass


class JobCancelledError(RuntimeError):
    pass


def _safe_stem(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value).strip(" .")
    return cleaned[:120] or "media"


def _reject_unsafe_ytdlp_info(
    info: dict[str, Any], *, incomplete: bool = False
) -> str | None:
    """Keep nested live manifests out of external FFmpeg network handling."""
    if incomplete:
        return None
    live_status = str(info.get("live_status") or "").lower()
    if info.get("is_live") or live_status in {"is_live", "is_upcoming", "post_live"}:
        return "实时流下载已禁用；外部 FFmpeg 无法应用逐请求 SSRF 防护"
    formats = info.get("requested_formats") or [info]
    for item in formats:
        protocol = str(item.get("protocol") or "").lower()
        if protocol.startswith(("rtmp", "rtsp", "mms", "ftp")):
            return "该媒体协议需要绕过逐请求 SSRF 防护的外部下载器"
    return None


def _run_ytdlp_worker(
    source_url: str,
    spec: DownloadSpec,
    job_dir: Path,
    settings: Settings,
    result_queue: Any,
) -> None:
    """Run yt-dlp in a killable process so FFmpeg children cannot outlive a job."""
    if os.name != "nt":
        try:
            os.setsid()
        except OSError:
            pass
    last_report = 0.0

    def progress_hook(data: dict[str, Any]) -> None:
        nonlocal last_report
        if data.get("status") != "downloading":
            return
        downloaded = int(data.get("downloaded_bytes") or 0)
        if downloaded > settings.max_download_bytes:
            raise yt_dlp.utils.DownloadCancelled("任务输出超过单任务大小限制")
        now = time.monotonic()
        if now - last_report < 0.2:
            return
        last_report = now
        total = data.get("total_bytes") or data.get("total_bytes_estimate")
        result_queue.put(
            (
                "progress",
                downloaded,
                int(total) if total else None,
                float(data.get("speed")) if data.get("speed") else None,
                int(data.get("eta")) if data.get("eta") is not None else None,
            )
        )

    options: dict[str, Any] = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "format": spec.selector or "bestvideo+bestaudio/best",
        "outtmpl": str(job_dir / "%(title).120B [%(id)s].%(ext)s"),
        "continuedl": True,
        "overwrites": False,
        "retries": 4,
        "fragment_retries": 4,
        "socket_timeout": 30,
        "max_filesize": settings.max_download_bytes,
        "concurrent_fragment_downloads": 1,
        "hls_prefer_native": True,
        "external_downloader": {"m3u8": "native", "dash": "native"},
        "match_filter": _reject_unsafe_ytdlp_info,
        "progress_hooks": [progress_hook],
        "http_headers": {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            )
        },
    }
    if spec.option.kind.value == "video" and spec.option.requires_merge:
        options["merge_output_format"] = (
            spec.option.extension
            if spec.option.extension in {"mp4", "mkv", "webm"}
            else "mp4"
        )
    if spec.preferred_codec:
        options["postprocessors"] = [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": spec.preferred_codec,
                "preferredquality": spec.preferred_quality or "192",
            }
        ]
    if settings.ffmpeg_location:
        options["ffmpeg_location"] = str(settings.ffmpeg_location)
    if spec.headers:
        options["http_headers"].update(spec.headers)

    try:
        job_dir.mkdir(parents=True, exist_ok=True)
        with temporary_bilibili_cookie_file(spec.cookie_header) as cookie_file:
            if cookie_file:
                options["cookiefile"] = cookie_file
            with SafeYoutubeDL(
                options,
                allow_fake_ip_dns=settings.allow_fake_ip_dns,
            ) as ydl:
                ydl.download([source_url])
        files = [
            path
            for path in job_dir.iterdir()
            if path.is_file() and path.suffix not in {".part", ".ytdl", ".temp"}
        ]
        if not files:
            raise RuntimeError("下载完成但未找到输出文件")
        result = max(files, key=lambda path: path.stat().st_mtime)
        if result.stat().st_size > settings.max_download_bytes:
            result.unlink(missing_ok=True)
            raise StorageLimitError("下载结果超过单任务大小限制")
        result_queue.put(("result", str(result)))
    except BaseException as exc:
        result_queue.put(("error", type(exc).__name__, str(exc)))


def _torrent_urls(data: bytes) -> tuple[list[str], list[str]]:
    """Parse only enough bencode to read tracker and web-seed fields safely."""
    position = 0
    items = 0

    def parse(depth: int = 0):
        nonlocal position, items
        items += 1
        if depth > 32 or items > 20_000 or position >= len(data):
            raise ValueError("种子文件结构无效或过于复杂")
        marker = data[position : position + 1]
        if marker == b"i":
            end = data.find(b"e", position + 1)
            if end < 0:
                raise ValueError("种子整数未结束")
            value = int(data[position + 1 : end])
            position = end + 1
            return value
        if marker == b"l":
            position += 1
            values = []
            while data[position : position + 1] != b"e":
                values.append(parse(depth + 1))
            position += 1
            return values
        if marker == b"d":
            position += 1
            values = {}
            while data[position : position + 1] != b"e":
                key = parse(depth + 1)
                if not isinstance(key, bytes):
                    raise ValueError("种子字典键无效")
                values[key] = parse(depth + 1)
            position += 1
            return values
        if marker.isdigit():
            separator = data.find(b":", position)
            if separator < 0:
                raise ValueError("种子字符串长度无效")
            length = int(data[position:separator])
            if length < 0 or length > len(data):
                raise ValueError("种子字符串过长")
            position = separator + 1
            end = position + length
            if end > len(data):
                raise ValueError("种子字符串被截断")
            value = data[position:end]
            position = end
            return value
        raise ValueError("种子文件不是有效 bencode")

    root = parse()
    if not isinstance(root, dict) or position != len(data):
        raise ValueError("种子文件结构无效")

    def flatten(value: object) -> list[str]:
        if isinstance(value, bytes):
            return [value.decode("utf-8", errors="strict")]
        if isinstance(value, list):
            result: list[str] = []
            for item in value:
                result.extend(flatten(item))
            return result
        return []

    trackers = flatten(root.get(b"announce")) + flatten(root.get(b"announce-list"))
    web_seeds = flatten(root.get(b"url-list")) + flatten(root.get(b"httpseeds"))
    return list(dict.fromkeys(trackers)), list(dict.fromkeys(web_seeds))


@dataclass(slots=True)
class ToolJobSpec:
    operation: str
    input_path: Path | None = None
    source: str | None = None
    sources: tuple[str, ...] = ()
    output_format: str = ""
    quality: int = 78


class JobManager:
    def __init__(self, settings: Settings, resolver: ResolverService) -> None:
        self._settings = settings
        self._resolver = resolver
        self._jobs: dict[str, DownloadJob] = {}
        self._files: dict[str, Path] = {}
        self._tool_specs: dict[str, ToolJobSpec] = {}
        self._semaphore = asyncio.Semaphore(settings.max_concurrent_jobs)
        self._lock = threading.RLock()
        self._capacity_lock = threading.Lock()
        self._tasks: dict[str, asyncio.Task[None]] = {}
        self._cancel_events: dict[str, threading.Event] = {}
        self._processes: dict[str, subprocess.Popen[str]] = {}
        self._worker_processes: dict[str, Any] = {}
        self._reservations: dict[str, int] = {}
        settings.download_dir.mkdir(parents=True, exist_ok=True)
        self._prune_orphans()

    def create(self, media_id: str, option_id: str) -> DownloadJob:
        self._prune()
        entry = self._resolver.get(media_id)
        if not entry:
            raise KeyError("解析结果已过期，请重新解析链接")
        if option_id not in entry.specs:
            raise KeyError("所选资源不存在")

        selected = entry.specs[option_id]
        if selected.direct_url:
            validate_public_url(
                selected.direct_url, self._settings.allow_fake_ip_dns
            )
        now = time.time()
        job_id = uuid.uuid4().hex
        self._reserve_capacity(job_id, self._download_reservation(selected))
        job = DownloadJob(
            id=job_id,
            media_id=media_id,
            option_id=option_id,
            state=JobState.QUEUED,
            created_at=now,
            updated_at=now,
        )
        try:
            with self._lock:
                self._jobs[job.id] = job
                self._cancel_events[job.id] = threading.Event()
                self._tasks[job.id] = asyncio.create_task(self._run(job.id))
        except BaseException:
            self._remove_job(job_id)
            raise
        return job.model_copy(deep=True)

    def create_tool(
        self,
        source_path: Path,
        operation: str,
        output_format: str = "",
        quality: int = 78,
        display_name: str | None = None,
    ) -> DownloadJob:
        self._prune()
        allowed = {"extract_audio", "compress_video", "compress_image", "metadata"}
        if operation not in allowed:
            raise ValueError("不支持的工具操作")
        now = time.time()
        job_id = uuid.uuid4().hex
        self._reserve_capacity(job_id, self._tool_reservation(source_path))
        job = DownloadJob(
            id=job_id,
            media_id="local-tool",
            option_id=operation,
            state=JobState.QUEUED,
            created_at=now,
            updated_at=now,
        )
        try:
            job_dir = self._settings.download_dir / job_id
            job_dir.mkdir(parents=True, exist_ok=True)
            display_stem = _safe_stem(Path(display_name or source_path.name).stem)
            target = job_dir / f"{display_stem}{source_path.suffix.lower()}"
            shutil.move(str(source_path), target)
            with self._lock:
                self._jobs[job_id] = job
                self._tool_specs[job_id] = ToolJobSpec(
                    operation=operation,
                    input_path=target,
                    output_format=output_format.lower(),
                    quality=min(max(quality, 1), 100),
                )
                self._cancel_events[job_id] = threading.Event()
                self._tasks[job_id] = asyncio.create_task(self._run_tool(job_id))
        except BaseException:
            self._remove_job(job_id)
            raise
        return job.model_copy(deep=True)

    def create_transfer(self, sources: str | list[str]) -> DownloadJob:
        self._prune()
        candidates = [sources] if isinstance(sources, str) else sources
        normalized = tuple(
            dict.fromkeys(item.strip() for item in candidates if item.strip())
        )
        if not normalized:
            raise ValueError("请输入直链、Magnet 或种子链接")
        if len(normalized) > 8:
            raise ValueError("多线路下载最多支持 8 条镜像直链")
        if any(len(item) > 8192 for item in normalized):
            raise ValueError("下载链接过长")
        if any(
            not item.startswith(("magnet:", "http://", "https://"))
            for item in normalized
        ):
            raise ValueError("只支持 Magnet 或公开的 http/https 链接")
        for item in normalized:
            if item.startswith(("http://", "https://")):
                validate_public_url(item, self._settings.allow_fake_ip_dns)
        magnets = [item for item in normalized if item.startswith("magnet:")]
        if magnets and len(normalized) != 1:
            raise ValueError("Magnet 任务不能与其他下载线路混合")
        if (
            any(item.startswith("magnet:") for item in normalized)
            and not self._settings.allow_peer_to_peer
        ):
            raise ValueError("磁力与种子任务默认关闭；仅可在隔离网络中显式启用")
        if any(
            item.startswith(("http://", "https://"))
            and urlparse(item).path.lower().endswith(".torrent")
            for item in normalized
        ):
            raise ValueError("远程种子链接不受支持，请上传 .torrent 文件")
        now = time.time()
        job_id = uuid.uuid4().hex
        self._reserve_capacity(job_id, self._settings.max_download_bytes * 2)
        job = DownloadJob(
            id=job_id,
            media_id="aria2-transfer",
            option_id="multi-source" if len(normalized) > 1 else "transfer",
            state=JobState.QUEUED,
            created_at=now,
            updated_at=now,
        )
        try:
            with self._lock:
                self._jobs[job_id] = job
                self._tool_specs[job_id] = ToolJobSpec(
                    operation="transfer",
                    source=normalized[0],
                    sources=normalized,
                )
                self._cancel_events[job_id] = threading.Event()
                self._tasks[job_id] = asyncio.create_task(self._run_tool(job_id))
        except BaseException:
            self._remove_job(job_id)
            raise
        return job.model_copy(deep=True)

    def create_torrent_file(self, source_path: Path) -> DownloadJob:
        self._prune()
        if source_path.suffix.lower() != ".torrent":
            raise ValueError("请选择 .torrent 种子文件")
        if not self._settings.allow_peer_to_peer:
            raise ValueError("磁力与种子任务默认关闭；仅可在隔离网络中显式启用")
        now = time.time()
        job_id = uuid.uuid4().hex
        self._reserve_capacity(
            job_id, self._tool_reservation(source_path, output_multiplier=2)
        )
        job = DownloadJob(
            id=job_id,
            media_id="aria2-transfer",
            option_id="torrent-file",
            state=JobState.QUEUED,
            created_at=now,
            updated_at=now,
        )
        try:
            job_dir = self._settings.download_dir / job_id
            job_dir.mkdir(parents=True, exist_ok=True)
            target = job_dir / "task.torrent"
            shutil.move(str(source_path), target)
            with self._lock:
                self._jobs[job_id] = job
                self._tool_specs[job_id] = ToolJobSpec(
                    operation="transfer", input_path=target
                )
                self._cancel_events[job_id] = threading.Event()
                self._tasks[job_id] = asyncio.create_task(self._run_tool(job_id))
        except BaseException:
            self._remove_job(job_id)
            raise
        return job.model_copy(deep=True)

    def get(self, job_id: str) -> DownloadJob | None:
        self._prune()
        with self._lock:
            job = self._jobs.get(job_id)
        return job.model_copy(deep=True) if job else None

    def file_for(self, job_id: str) -> Path | None:
        with self._lock:
            job = self._jobs.get(job_id)
            path = self._files.get(job_id)
        if not job or job.state != JobState.COMPLETED or not path or not path.is_file():
            return None
        return path

    def cancel(self, job_id: str) -> DownloadJob | None:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job:
                return None
            if job.state in {JobState.COMPLETED, JobState.FAILED, JobState.CANCELLED}:
                return job.model_copy(deep=True)
            was_queued = job.state == JobState.QUEUED
            event = self._cancel_events.get(job_id)
            if event:
                event.set()
            process = self._processes.get(job_id)
            worker_process = self._worker_processes.get(job_id)
            task = self._tasks.get(job_id)
            job.state = JobState.CANCELLED
            job.error = "任务已取消"
            job.error_code = "cancelled"
            job.updated_at = time.time()
            snapshot = job.model_copy(deep=True)
        if process and process.poll() is None:
            process.kill()
        if worker_process is not None and worker_process.is_alive():
            self._kill_worker_process(worker_process)
        if task and not task.done():
            task.cancel()
        if was_queued:
            self._release_reservation(job_id)
        return snapshot

    def shutdown(self) -> None:
        with self._lock:
            active = [
                job_id
                for job_id, job in self._jobs.items()
                if job.state in {JobState.QUEUED, JobState.RUNNING}
            ]
        for job_id in active:
            self.cancel(job_id)
        self._resolver.shutdown()

    async def _run(self, job_id: str) -> None:
        try:
            async with asyncio.timeout(self._settings.job_timeout_seconds):
                await self._run_inner(job_id)
        except TimeoutError:
            self._cancel_event(job_id).set()
            self._terminate_process(job_id)
            self._fail(job_id, "任务超过总运行时间限制", "timeout")
        except asyncio.CancelledError:
            pass
        finally:
            with self._lock:
                self._tasks.pop(job_id, None)
            self._cleanup_partials(job_id)
            self._release_reservation(job_id)

    async def _run_inner(self, job_id: str) -> None:
        async with self._semaphore:
            with self._lock:
                job = self._jobs.get(job_id)
            if not job:
                return
            entry = self._resolver.get(job.media_id)
            if not entry or job.option_id not in entry.specs:
                self._fail(job_id, "解析结果已过期，请重新解析")
                return
            spec = entry.specs[job.option_id]
            with self._lock:
                if job.state == JobState.CANCELLED:
                    return
                job.state = JobState.RUNNING
                job.updated_at = time.time()
            job_dir = self._settings.download_dir / job.id
            job_dir.mkdir(parents=True, exist_ok=True)
            try:
                if spec.direct_url:
                    path = await self._download_direct(
                        job_id, entry.media.title, spec, job_dir
                    )
                else:
                    path = await self._download_ytdlp_isolated(
                        job_id,
                        entry.media.source_url,
                        spec,
                        job_dir,
                    )
                self._complete(job_id, path)
            except JobCancelledError:
                self.cancel(job_id)
            except Exception as exc:  # Download errors vary by extractor.
                self._fail(job_id, self._clean_error(exc), "download_failed")

    async def _run_tool(self, job_id: str) -> None:
        try:
            async with asyncio.timeout(self._settings.job_timeout_seconds):
                await self._run_tool_inner(job_id)
        except TimeoutError:
            self._cancel_event(job_id).set()
            self._terminate_process(job_id)
            self._fail(job_id, "任务超过总运行时间限制", "timeout")
        except asyncio.CancelledError:
            pass
        finally:
            with self._lock:
                self._tasks.pop(job_id, None)
            self._cleanup_partials(job_id)
            self._release_reservation(job_id)

    async def _run_tool_inner(self, job_id: str) -> None:
        async with self._semaphore:
            with self._lock:
                job = self._jobs.get(job_id)
                spec = self._tool_specs.get(job_id)
            if not job or not spec:
                return
            with self._lock:
                if job.state == JobState.CANCELLED:
                    return
                job.state = JobState.RUNNING
                job.progress = 0.01
                job.updated_at = time.time()
            job_dir = self._settings.download_dir / job_id
            job_dir.mkdir(parents=True, exist_ok=True)
            try:
                if spec.operation == "transfer":
                    source = spec.source or str(spec.input_path or "")
                    if spec.sources and all(
                        item.startswith(("http://", "https://"))
                        and not urlparse(item).path.lower().endswith(".torrent")
                        for item in spec.sources
                    ):
                        path = await self._download_mirrors(
                            job_id, list(spec.sources), job_dir
                        )
                    else:
                        path = await asyncio.to_thread(
                            self._run_transfer, job_id, source, job_dir
                        )
                else:
                    path = await asyncio.to_thread(
                        self._process_tool, job_id, spec, job_dir
                    )
                self._complete(job_id, path)
            except JobCancelledError:
                self.cancel(job_id)
            except Exception as exc:
                self._fail(job_id, self._clean_error(exc), "tool_failed")

    async def _download_direct(
        self, job_id: str, title: str, spec: DownloadSpec, job_dir: Path
    ) -> Path:
        if not spec.direct_url:
            raise ValueError("直链下载任务缺少资源地址")
        filename = f"{_safe_stem(title)}.{spec.option.extension}"
        path = job_dir / filename
        headers: dict[str, str] = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            )
        }
        headers.update(spec.headers or {})
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(30, read=60),
            follow_redirects=False,
            trust_env=False,
        ) as client:
            total: int | None = None
            supports_ranges = False
            try:
                async with stream_public_response_async(
                    client,
                    "HEAD",
                    spec.direct_url,
                    headers=headers,
                    allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
                    max_redirects=self._settings.max_redirects,
                ) as head:
                    if head.is_success:
                        total = int(head.headers.get("content-length", "0")) or None
                        if total and total > self._settings.max_download_bytes:
                            raise StorageLimitError("远程文件超过单任务下载大小限制")
                        supports_ranges = (
                            head.headers.get("accept-ranges", "").lower() == "bytes"
                        )
            except (httpx.HTTPError, ValueError):
                pass
            if total and total >= 8 * 1024 * 1024 and supports_ranges:
                try:
                    await self._download_segmented(
                        client,
                        [spec.direct_url],
                        path,
                        job_id,
                        total,
                        segments=8,
                        headers=headers,
                    )
                    return path
                except (JobCancelledError, StorageLimitError, UnsafeUrlError):
                    raise
                except (httpx.HTTPError, OSError, RuntimeError, ValueError):
                    # Broken Range implementations are common. Retry the same
                    # object as one guarded sequential GET before failing.
                    path.unlink(missing_ok=True)
                    total = None
            partial = path.with_suffix(f"{path.suffix}.part")
            try:
                async with stream_public_response_async(
                    client,
                    "GET",
                    spec.direct_url,
                    headers=headers,
                    allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
                    max_redirects=self._settings.max_redirects,
                ) as response:
                    response.raise_for_status()
                    total = (
                        total
                        or int(response.headers.get("content-length", "0"))
                        or None
                    )
                    if total and total > self._settings.max_download_bytes:
                        raise StorageLimitError("远程文件超过单任务下载大小限制")
                    downloaded = 0
                    with partial.open("wb") as output:
                        async for chunk in response.aiter_bytes(256 * 1024):
                            self._check_cancelled(job_id)
                            downloaded += len(chunk)
                            if downloaded > self._settings.max_download_bytes:
                                raise StorageLimitError(
                                    "远程文件超过单任务下载大小限制"
                                )
                            output.write(chunk)
                            self._update_progress(job_id, downloaded, total, None, None)
                partial.replace(path)
            finally:
                partial.unlink(missing_ok=True)
        return path

    async def _download_segmented(
        self,
        client: httpx.AsyncClient,
        urls: list[str],
        target: Path,
        job_id: str,
        total: int,
        segments: int,
        headers: dict[str, str] | None = None,
    ) -> None:
        if total > self._settings.max_download_bytes:
            raise StorageLimitError("远程文件超过单任务下载大小限制")
        part_size = (total + segments - 1) // segments
        downloaded = [0 for _ in range(segments)]
        lock = asyncio.Lock()
        part_paths = [
            target.with_suffix(f"{target.suffix}.part{index}")
            for index in range(segments)
        ]

        async def fetch(index: int) -> None:
            start = index * part_size
            end = min(total - 1, start + part_size - 1)
            if start > end:
                return
            expected = end - start + 1
            last_error: Exception | None = None
            for offset in range(len(urls)):
                url = urls[(index + offset) % len(urls)]
                try:
                    range_headers = dict(headers or {})
                    range_headers["Range"] = f"bytes={start}-{end}"
                    async with stream_public_response_async(
                        client,
                        "GET",
                        url,
                        headers=range_headers,
                        allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
                        max_redirects=self._settings.max_redirects,
                    ) as response:
                        if response.status_code != 206:
                            raise RuntimeError("服务器未按 Range 返回分段内容")
                        content_range = response.headers.get("content-range", "")
                        if content_range != f"bytes {start}-{end}/{total}":
                            raise RuntimeError("下载线路返回了不匹配的 Content-Range")
                        with part_paths[index].open("wb") as output:
                            async for chunk in response.aiter_bytes(256 * 1024):
                                self._check_cancelled(job_id)
                                async with lock:
                                    next_part_size = downloaded[index] + len(chunk)
                                    if next_part_size > expected:
                                        raise RuntimeError("下载分段返回了超出范围的内容")
                                    aggregate = (
                                        sum(downloaded)
                                        - downloaded[index]
                                        + next_part_size
                                    )
                                    if aggregate > self._settings.max_download_bytes:
                                        raise StorageLimitError(
                                            "远程文件超过单任务下载大小限制"
                                        )
                                    downloaded[index] = next_part_size
                                    self._update_progress(
                                        job_id, aggregate, total, None, None
                                    )
                                output.write(chunk)
                    if part_paths[index].stat().st_size != expected:
                        raise RuntimeError("下载分段大小与预期不一致")
                    return
                except (JobCancelledError, StorageLimitError, UnsafeUrlError):
                    raise
                except (httpx.HTTPError, OSError, RuntimeError) as exc:
                    last_error = exc
                    async with lock:
                        downloaded[index] = 0
                        self._update_progress(
                            job_id, sum(downloaded), total, None, None
                        )
                    part_paths[index].unlink(missing_ok=True)
            raise RuntimeError(
                f"所有下载线路均无法获取分段 {index + 1}"
            ) from last_error

        try:
            tasks = [asyncio.create_task(fetch(index)) for index in range(segments)]
            try:
                await asyncio.gather(*tasks)
            except BaseException:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                raise
            with target.open("wb") as output:
                for part in part_paths:
                    with part.open("rb") as source:
                        while chunk := source.read(1024 * 1024):
                            if (
                                self._storage_usage() + len(chunk)
                                > self._settings.max_total_storage_bytes
                            ):
                                raise StorageLimitError(
                                    "下载缓存超过总容量限制"
                                )
                            output.write(chunk)
                    part.unlink(missing_ok=True)
            if target.stat().st_size != total:
                target.unlink(missing_ok=True)
                raise RuntimeError("合并后的文件大小与远程对象不一致")
        except BaseException:
            target.unlink(missing_ok=True)
            raise
        finally:
            for part in part_paths:
                part.unlink(missing_ok=True)

    async def _download_mirrors(
        self, job_id: str, urls: list[str], job_dir: Path
    ) -> Path:
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            )
        }
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(30, read=60),
            follow_redirects=False,
            trust_env=False,
        ) as client:

            async def probe(
                url: str,
            ) -> tuple[str, int | None, bool, str | None, str | None, float]:
                started = time.monotonic()
                try:
                    async with stream_public_response_async(
                        client,
                        "HEAD",
                        url,
                        headers=headers,
                        allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
                        max_redirects=self._settings.max_redirects,
                    ) as response:
                        response.raise_for_status()
                        size = int(response.headers.get("content-length", "0")) or None
                        if size and size > self._settings.max_download_bytes:
                            raise StorageLimitError("远程文件超过单任务下载大小限制")
                        ranges = (
                            response.headers.get("accept-ranges", "").lower() == "bytes"
                        )
                        return (
                            url,
                            size,
                            ranges,
                            response.headers.get("etag"),
                            response.headers.get("last-modified"),
                            time.monotonic() - started,
                        )
                except (httpx.HTTPError, ValueError, StorageLimitError):
                    return url, None, False, None, None, float("inf")

            probes = await asyncio.gather(*(probe(url) for url in urls))
            available = sorted(probes, key=lambda item: item[5])
            responsive = [item for item in available if item[5] != float("inf")]
            if not responsive:
                raise RuntimeError("所有下载线路均不可用")
            selected = responsive[0][0] if responsive else urls[0]
            filename = Path(unquote(urlparse(selected).path)).name or "download.bin"
            raw_suffix = Path(filename).suffix
            suffix = raw_suffix if 1 < len(raw_suffix) <= 12 else ".bin"
            target = job_dir / f"{_safe_stem(Path(filename).stem)}{suffix}"

            range_probes = [item for item in responsive if item[1] and item[2]]
            if range_probes:
                identity_groups: dict[tuple[int, str, str], list[str]] = {}
                for url, size, _, etag, modified, _ in range_probes:
                    if size is None:
                        continue
                    # Cross-mirror segmentation is allowed only with a shared
                    # strong validator. Otherwise one origin serves all parts.
                    validator = etag or modified or f"single:{url}"
                    identity_groups.setdefault(
                        (
                            size,
                            "etag" if etag else "modified" if modified else "single",
                            validator,
                        ),
                        [],
                    ).append(url)
                identity, compatible = max(
                    identity_groups.items(), key=lambda item: (len(item[1]), item[0][0])
                )
                total = identity[0]
                if total >= 8 * 1024 * 1024:
                    segments = min(8, max(4, len(compatible) * 2))
                    try:
                        await self._download_segmented(
                            client,
                            compatible,
                            target,
                            job_id,
                            total,
                            segments=segments,
                            headers=headers,
                        )
                        return target
                    except (JobCancelledError, StorageLimitError, UnsafeUrlError):
                        raise
                    except (httpx.HTTPError, OSError, RuntimeError):
                        # A server may advertise broken range support. Retry the
                        # complete object on each responsive mirror below.
                        target.unlink(missing_ok=True)

            last_error: Exception | None = None
            partial = target.with_suffix(f"{target.suffix}.part")
            try:
                for url, *_ in responsive:
                    partial.unlink(missing_ok=True)
                    try:
                        async with stream_public_response_async(
                            client,
                            "GET",
                            url,
                            headers=headers,
                            allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
                            max_redirects=self._settings.max_redirects,
                        ) as response:
                            response.raise_for_status()
                            total = (
                                int(response.headers.get("content-length", "0")) or None
                            )
                            if total and total > self._settings.max_download_bytes:
                                raise StorageLimitError(
                                    "远程文件超过单任务下载大小限制"
                                )
                            downloaded = 0
                            with partial.open("wb") as output:
                                async for chunk in response.aiter_bytes(256 * 1024):
                                    self._check_cancelled(job_id)
                                    downloaded += len(chunk)
                                    if downloaded > self._settings.max_download_bytes:
                                        raise StorageLimitError(
                                            "远程文件超过单任务下载大小限制"
                                        )
                                    output.write(chunk)
                                    self._update_progress(
                                        job_id, downloaded, total, None, None
                                    )
                        partial.replace(target)
                        return target
                    except (httpx.HTTPError, OSError, ValueError) as exc:
                        last_error = exc
                raise RuntimeError("所有下载线路均失败") from last_error
            finally:
                partial.unlink(missing_ok=True)

    def _process_tool(self, job_id: str, spec: ToolJobSpec, job_dir: Path) -> Path:
        if not spec.input_path or not spec.input_path.is_file():
            raise RuntimeError("上传文件不存在")
        source = spec.input_path
        if source.suffix.lower() in {".m3u", ".m3u8", ".sdp"}:
            raise ValueError("不处理可嵌套网络地址的播放列表文件")
        try:
            with source.open("rb") as stream:
                if stream.read(16).lstrip().startswith(b"#EXTM3U"):
                    raise ValueError("不处理可嵌套网络地址的播放列表文件")
        except OSError:
            pass
        stem = _safe_stem(source.stem)
        if spec.operation == "compress_image":
            extension = (
                spec.output_format
                if spec.output_format in {"jpg", "jpeg", "png", "webp"}
                else "webp"
            )
            target = job_dir / f"{stem}-compressed.{extension}"
            with Image.open(source) as image:
                icc_profile = image.info.get("icc_profile")
                if getattr(image, "is_animated", False):
                    if extension != "webp":
                        raise ValueError("动图压缩请使用 WEBP，以避免静默丢失动画帧")
                    frames: list[Image.Image] = []
                    durations: list[int] = []
                    for frame in ImageSequence.Iterator(image):
                        converted = ImageOps.exif_transpose(frame.copy()).convert(
                            "RGBA"
                        )
                        converted.thumbnail((3840, 3840), Image.Resampling.LANCZOS)
                        frames.append(converted)
                        durations.append(
                            int(
                                frame.info.get("duration")
                                or image.info.get("duration")
                                or 100
                            )
                        )
                    if not frames:
                        raise ValueError("动图没有可处理帧")
                    frames[0].save(
                        target,
                        save_all=True,
                        append_images=frames[1:],
                        duration=durations,
                        loop=int(image.info.get("loop") or 0),
                        quality=spec.quality,
                        method=6,
                        icc_profile=icc_profile,
                    )
                    self._set_progress(job_id, 0.99)
                    return target
                image = ImageOps.exif_transpose(image)
                original_exif = image.info.get("exif")
                image.thumbnail((3840, 3840), Image.Resampling.LANCZOS)
                if extension in {"jpg", "jpeg"} and image.mode not in {"RGB", "L"}:
                    image = image.convert("RGB")
                save_options: dict[str, Any] = {
                    "quality": spec.quality,
                    "optimize": True,
                }
                if original_exif and extension in {"jpg", "jpeg", "webp"}:
                    save_options["exif"] = original_exif
                if icc_profile:
                    save_options["icc_profile"] = icc_profile
                image.save(target, **save_options)
            self._set_progress(job_id, 0.99)
            return target
        if spec.operation == "metadata":
            target = job_dir / f"{stem}-metadata.json"
            command = [
                self._ffprobe_binary(),
                "-protocol_whitelist",
                "file,pipe,fd,crypto",
                "-v",
                "quiet",
                "-show_format",
                "-show_streams",
                "-of",
                "json",
                str(source),
            ]
            output = self._run_captured(job_id, command)
            parsed = json.loads(output)
            target.write_text(
                json.dumps(parsed, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            self._set_progress(job_id, 0.99)
            return target
        if spec.operation == "extract_audio":
            extension = (
                spec.output_format
                if spec.output_format in {"mp3", "m4a", "flac", "wav"}
                else "mp3"
            )
            target = job_dir / f"{stem}-audio.{extension}"
            codec_args = {
                "mp3": ["-codec:a", "libmp3lame", "-b:a", "320k"],
                "m4a": ["-codec:a", "aac", "-b:a", "256k"],
                "flac": ["-codec:a", "flac"],
                "wav": ["-codec:a", "pcm_s16le"],
            }[extension]
            self._run_ffmpeg(job_id, source, target, ["-vn", *codec_args])
            return target
        if spec.operation == "compress_video":
            target = job_dir / f"{stem}-compressed.mp4"
            crf = round(34 - spec.quality * 0.18)
            crf = min(max(crf, 18), 33)
            self._run_ffmpeg(
                job_id,
                source,
                target,
                [
                    "-map",
                    "0:v:0",
                    "-map",
                    "0:a?",
                    "-map_metadata",
                    "0",
                    "-map_chapters",
                    "0",
                    "-c:v",
                    "libx264",
                    "-preset",
                    "medium",
                    "-crf",
                    str(crf),
                    "-c:a",
                    "aac",
                    "-b:a",
                    "128k",
                    "-movflags",
                    "+faststart",
                ],
            )
            return target
        raise RuntimeError("未知工具操作")

    def _run_ffmpeg(
        self,
        job_id: str,
        source: Path,
        target: Path,
        output_args: list[str],
    ) -> None:
        command = [
            self._ffmpeg_binary(),
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-protocol_whitelist",
            "file,pipe,fd,crypto",
            "-i",
            str(source),
            *output_args,
            str(target),
        ]
        # Every argument is a separate argv item and shell execution is disabled.
        process = subprocess.Popen(  # nosec B603
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self._register_process(job_id, process)
        self._set_progress(job_id, 0.1)
        try:
            output, _ = self._communicate_guarded(
                job_id,
                process,
                timeout_message="FFmpeg 处理超时",
                watched_path=target,
            )
        finally:
            self._unregister_process(job_id, process)
        self._check_cancelled(job_id)
        if process.returncode != 0:
            tail_output = [
                line.strip() for line in (output or "").splitlines() if line.strip()
            ][-4:]
            raise RuntimeError("FFmpeg 处理失败：" + " | ".join(tail_output))
        return

    def _run_captured(self, job_id: str, command: list[str]) -> str:
        # Every argument is a separate argv item and shell execution is disabled.
        process = subprocess.Popen(  # nosec B603
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self._register_process(job_id, process)
        try:
            output, _ = self._communicate_guarded(
                job_id,
                process,
                timeout_message="媒体工具执行超时",
            )
        finally:
            self._unregister_process(job_id, process)
        self._check_cancelled(job_id)
        if process.returncode != 0:
            tail = [
                line.strip() for line in (output or "").splitlines() if line.strip()
            ][-4:]
            raise RuntimeError("媒体工具执行失败：" + " | ".join(tail))
        return output or ""

    def _probe_duration(self, source: Path) -> float | None:
        # Every argument is a separate argv item and shell execution is disabled.
        result = subprocess.run(  # nosec B603
            [
                self._ffprobe_binary(),
                "-protocol_whitelist",
                "file,pipe,fd,crypto",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(source),
            ],
            capture_output=True,
            text=True,
            timeout=min(self._settings.job_timeout_seconds, 60),
        )
        try:
            return float(result.stdout.strip())
        except ValueError:
            return None

    def _ffmpeg_binary(self) -> str:
        if self._settings.ffmpeg_location:
            location = self._settings.ffmpeg_location
            if location.is_dir():
                candidate = location / "ffmpeg"
                return str(
                    candidate.with_suffix(".exe")
                    if candidate.with_suffix(".exe").is_file()
                    else candidate
                )
            return str(location)
        return shutil.which("ffmpeg") or "ffmpeg"

    def _ffprobe_binary(self) -> str:
        if self._settings.ffmpeg_location:
            location = self._settings.ffmpeg_location
            if location.is_dir():
                candidate = location / "ffprobe"
            else:
                candidate = location.with_name("ffprobe")
            return str(
                candidate.with_suffix(".exe")
                if candidate.with_suffix(".exe").is_file()
                else candidate
            )
        return shutil.which("ffprobe") or "ffprobe"

    def _run_transfer(self, job_id: str, source: str, job_dir: Path) -> Path:
        if source.startswith(("http://", "https://")):
            validate_public_url(source, self._settings.allow_fake_ip_dns)
        else:
            self._validate_p2p_source(source)
        aria2 = shutil.which("aria2c")
        if not aria2:
            raise RuntimeError("服务器未安装 aria2，无法处理磁力或种子任务")
        command = [
            aria2,
            "--dir",
            str(job_dir),
            "--seed-time=0",
            "--bt-enable-lpd=false",
            "--enable-peer-exchange=false",
            "--enable-dht=false",
            "--enable-dht6=false",
            "--disable-ipv6=true",
            "--follow-torrent=false",
            "--file-allocation=none",
            "--auto-file-renaming=true",
            "--summary-interval=0",
            "--console-log-level=warn",
            "--bt-max-peers=50",
            source,
        ]
        # Every argument is a separate argv item and shell execution is disabled.
        process = subprocess.Popen(  # nosec B603
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self._register_process(job_id, process)
        try:
            output, _ = self._communicate_guarded(
                job_id,
                process,
                timeout_message="aria2 下载超时",
                watched_path=job_dir,
            )
        finally:
            self._unregister_process(job_id, process)
        self._check_cancelled(job_id)
        if process.returncode != 0:
            tail_output = [
                line.strip() for line in (output or "").splitlines() if line.strip()
            ][-4:]
            raise RuntimeError("aria2 下载失败：" + " | ".join(tail_output))
        self._set_progress(job_id, 0.99)
        return self._collect_transfer_output(job_id, job_dir)

    def _collect_transfer_output(self, job_id: str, job_dir: Path) -> Path:
        files = [
            path
            for path in job_dir.rglob("*")
            if path.is_file() and path.suffix not in {".aria2", ".torrent"}
        ]
        if not files:
            raise RuntimeError("下载完成但未找到文件")
        total_size = sum(path.stat().st_size for path in files)
        if total_size > self._settings.max_download_bytes:
            raise StorageLimitError("下载结果超过单任务大小限制")
        if len(files) == 1:
            return files[0]
        archive_base = job_dir.parent / f"{job_id}-files"
        archive_path = Path(shutil.make_archive(str(archive_base), "zip", job_dir))
        target = job_dir / "torrent-files.zip"
        shutil.move(str(archive_path), target)
        return target

    def _validate_p2p_source(self, source: str) -> None:
        if not self._settings.allow_peer_to_peer:
            raise ValueError("磁力与种子任务默认关闭")
        if source.startswith("magnet:"):
            trackers = parse_qs(urlparse(source).query).get("tr", [])
            if not trackers:
                raise ValueError("磁力链接必须提供可校验的公开 HTTPS tracker")
            for tracker in trackers:
                parsed = urlparse(tracker)
                if parsed.scheme != "https":
                    raise ValueError("仅允许 HTTPS tracker；UDP/HTTP tracker 已禁用")
                validate_public_url(tracker, self._settings.allow_fake_ip_dns)
            return
        path = Path(source)
        if path.suffix.lower() != ".torrent" or not path.is_file():
            raise ValueError("无效的种子任务")
        trackers, web_seeds = _torrent_urls(path.read_bytes())
        if web_seeds:
            raise ValueError("种子文件包含 Web Seed；为防止嵌套网络访问已拒绝")
        if not trackers:
            raise ValueError("种子文件缺少可校验的公开 HTTPS tracker")
        for tracker in trackers:
            if not tracker.startswith("https://"):
                raise ValueError("种子文件包含非 HTTPS tracker")
            validate_public_url(tracker, self._settings.allow_fake_ip_dns)

    def _multiprocessing_context(self):
        return multiprocessing.get_context("spawn")

    async def _download_ytdlp_isolated(
        self,
        job_id: str,
        source_url: str,
        spec: DownloadSpec,
        job_dir: Path,
    ) -> Path:
        context = self._multiprocessing_context()
        result_queue = context.Queue()
        process = context.Process(
            target=_run_ytdlp_worker,
            args=(source_url, spec, job_dir, self._settings, result_queue),
            name=f"langbai-ytdlp-{job_id[:8]}",
        )
        result_path: Path | None = None
        worker_error: str | None = None

        def drain_messages() -> None:
            nonlocal result_path, worker_error
            while True:
                try:
                    message = result_queue.get_nowait()
                except queue.Empty:
                    return
                if not message:
                    continue
                if message[0] == "progress":
                    self._update_progress(job_id, *message[1:])
                elif message[0] == "result":
                    result_path = Path(message[1])
                elif message[0] == "error":
                    worker_error = f"{message[1]}: {message[2]}"

        process.start()
        try:
            self._register_worker_process(job_id, process)
            last_storage_check = 0.0
            while process.is_alive():
                drain_messages()
                self._check_cancelled(job_id)
                now = time.monotonic()
                if now - last_storage_check >= 0.25:
                    last_storage_check = now
                    with self._lock:
                        transient_limit = self._reservations.get(
                            job_id, self._settings.max_download_bytes
                        )
                    if self._has_oversized_file(
                        job_dir, self._settings.max_download_bytes
                    ):
                        raise StorageLimitError("任务中的单个文件超过大小限制")
                    if self._path_size(job_dir) > transient_limit:
                        raise StorageLimitError("任务输出超过单任务大小限制")
                    if self._storage_usage() > self._settings.max_total_storage_bytes:
                        raise StorageLimitError("下载缓存超过总容量限制")
                await asyncio.sleep(0.1)
            process.join(timeout=0.2)
            deadline = time.monotonic() + 1.0
            while result_path is None and worker_error is None:
                drain_messages()
                if time.monotonic() >= deadline:
                    break
                await asyncio.sleep(0.02)
            if worker_error:
                raise RuntimeError(worker_error)
            if process.exitcode not in {0, None}:
                raise RuntimeError(f"yt-dlp 工作进程异常退出（{process.exitcode}）")
            if result_path is None:
                raise RuntimeError("yt-dlp 工作进程没有返回下载结果")
            resolved_dir = job_dir.resolve()
            resolved_result = result_path.resolve()
            if not resolved_result.is_relative_to(resolved_dir):
                raise RuntimeError("yt-dlp 返回了任务目录之外的文件")
            if not resolved_result.is_file():
                raise RuntimeError("yt-dlp 下载结果不存在")
            if resolved_result.stat().st_size > self._settings.max_download_bytes:
                resolved_result.unlink(missing_ok=True)
                raise StorageLimitError("下载结果超过单任务大小限制")
            self._check_cancelled(job_id)
            return resolved_result
        finally:
            if process.is_alive():
                self._kill_worker_process(process)
            process.join(timeout=1.0)
            self._unregister_worker_process(job_id, process)
            try:
                result_queue.close()
                result_queue.cancel_join_thread()
            except (AttributeError, OSError, ValueError):
                pass

    def _update_progress(
        self,
        job_id: str,
        downloaded: int,
        total: int | None,
        speed: float | None,
        eta: int | None,
    ) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or job.state == JobState.CANCELLED:
                return
            job.downloaded_bytes = downloaded
            job.total_bytes = total
            job.speed_bytes_per_second = speed
            job.eta_seconds = eta
            if total:
                job.progress = min(0.99, downloaded / total)
            job.updated_at = time.time()

    def _set_progress(self, job_id: str, progress: float) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job and job.state != JobState.CANCELLED:
                job.progress = min(max(progress, 0), 0.99)
                job.updated_at = time.time()

    def _complete(self, job_id: str, path: Path) -> None:
        self._check_cancelled(job_id)
        if not path.is_file():
            raise RuntimeError("任务没有产生可下载文件")
        if path.stat().st_size > self._settings.max_download_bytes:
            path.unlink(missing_ok=True)
            raise StorageLimitError("下载结果超过单任务大小限制")
        if self._storage_usage() > self._settings.max_total_storage_bytes:
            path.unlink(missing_ok=True)
            raise StorageLimitError("下载缓存超过总容量限制")
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or job.state == JobState.CANCELLED:
                raise JobCancelledError("任务已取消")
            job.state = JobState.COMPLETED
            job.progress = 1
            job.filename = path.name
            job.download_url = f"/api/v1/jobs/{job_id}/file"
            job.updated_at = time.time()
            self._files[job_id] = path

    def _fail(self, job_id: str, message: str, error_code: str = "failed") -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or job.state in {JobState.CANCELLED, JobState.COMPLETED}:
                return
            job.state = JobState.FAILED
            job.error = message or "下载失败"
            job.error_code = error_code
            job.updated_at = time.time()

    def _cancel_event(self, job_id: str) -> threading.Event:
        with self._lock:
            return self._cancel_events.setdefault(job_id, threading.Event())

    def _check_cancelled(self, job_id: str) -> None:
        if self._cancel_event(job_id).is_set():
            raise JobCancelledError("任务已取消")

    def _register_process(self, job_id: str, process: subprocess.Popen[str]) -> None:
        with self._lock:
            self._processes[job_id] = process
        self._check_cancelled(job_id)

    def _register_worker_process(self, job_id: str, process: Any) -> None:
        with self._lock:
            self._worker_processes[job_id] = process
        self._check_cancelled(job_id)

    def _unregister_worker_process(self, job_id: str, process: Any) -> None:
        with self._lock:
            if self._worker_processes.get(job_id) is process:
                self._worker_processes.pop(job_id, None)

    @staticmethod
    def _kill_worker_process(process: Any) -> None:
        if not process.is_alive():
            return
        pid = getattr(process, "pid", None)
        if pid and os.name == "nt":
            try:
                # taskkill is a fixed Windows system command; no user input is executable.
                subprocess.run(  # nosec B603 B607
                    ["taskkill", "/PID", str(pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError):
                pass
        elif pid:
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                pass
        if process.is_alive():
            try:
                process.kill()
            except (OSError, ValueError):
                pass

    def _communicate_guarded(
        self,
        job_id: str,
        process: subprocess.Popen[str],
        *,
        timeout_message: str,
        watched_path: Path | None = None,
    ) -> tuple[str, str | None]:
        deadline = time.monotonic() + self._settings.job_timeout_seconds
        while True:
            if self._cancel_event(job_id).is_set():
                process.kill()
                process.communicate()
                raise JobCancelledError("任务已取消")
            if watched_path is not None and self._path_size(watched_path) > (
                self._settings.max_download_bytes
            ):
                process.kill()
                process.communicate()
                raise StorageLimitError("任务输出超过单任务大小限制")
            if self._storage_usage() > self._settings.max_total_storage_bytes:
                process.kill()
                process.communicate()
                raise StorageLimitError("下载缓存超过总容量限制")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                process.communicate()
                raise RuntimeError(timeout_message)
            try:
                output, error = process.communicate(timeout=min(1.0, remaining))
                if watched_path is not None and self._path_size(watched_path) > (
                    self._settings.max_download_bytes
                ):
                    raise StorageLimitError("任务输出超过单任务大小限制")
                if self._storage_usage() > self._settings.max_total_storage_bytes:
                    raise StorageLimitError("下载缓存超过总容量限制")
                return output or "", error
            except subprocess.TimeoutExpired:
                continue

    @staticmethod
    def _path_size(path: Path) -> int:
        try:
            if path.is_file():
                return path.stat().st_size
            total = 0
            for item in path.rglob("*"):
                try:
                    if item.is_file() and not item.is_symlink():
                        total += item.stat().st_size
                except (FileNotFoundError, OSError):
                    continue
            return total
        except (FileNotFoundError, OSError):
            return 0

    @staticmethod
    def _has_oversized_file(path: Path, limit: int) -> bool:
        try:
            for item in path.rglob("*"):
                try:
                    if (
                        item.is_file()
                        and not item.is_symlink()
                        and item.stat().st_size > limit
                    ):
                        return True
                except (FileNotFoundError, OSError):
                    continue
        except OSError:
            return False
        return False

    def _unregister_process(self, job_id: str, process: subprocess.Popen[str]) -> None:
        with self._lock:
            if self._processes.get(job_id) is process:
                self._processes.pop(job_id, None)

    def _terminate_process(self, job_id: str) -> None:
        with self._lock:
            process = self._processes.get(job_id)
            worker_process = self._worker_processes.get(job_id)
        if process and process.poll() is None:
            process.kill()
        if worker_process is not None and worker_process.is_alive():
            self._kill_worker_process(worker_process)

    def _clean_error(self, value: object) -> str:
        message = _ANSI_ESCAPE_RE.sub("", str(value))
        message = message.replace(str(self._settings.download_dir), "<download-dir>")
        message = re.sub(
            r"(https?://[^\s?]+)\?[^\s]+",
            r"\1?<redacted>",
            message,
            flags=re.IGNORECASE,
        )
        return " ".join(message.split())[:500]

    def _download_reservation(self, spec: DownloadSpec) -> int:
        needs_transient_copy = bool(
            spec.direct_url or spec.option.requires_merge or spec.preferred_codec
        )
        return self._settings.max_download_bytes * (2 if needs_transient_copy else 1)

    def _tool_reservation(
        self, source_path: Path, *, output_multiplier: int = 1
    ) -> int:
        reservation = self._settings.max_download_bytes * output_multiplier
        try:
            managed_source = source_path.resolve().is_relative_to(
                self._settings.download_dir.resolve()
            )
            if not managed_source:
                reservation += source_path.stat().st_size
        except OSError:
            pass
        return reservation

    def _reserve_capacity(
        self, job_id: str, reservation_bytes: int | None = None
    ) -> None:
        reservation = reservation_bytes or self._settings.max_download_bytes
        with self._capacity_lock:
            self._prune_job_count()
            with self._lock:
                active_ids = {
                    current_job_id
                    for current_job_id, job in self._jobs.items()
                    if job.state in {JobState.QUEUED, JobState.RUNNING}
                }
                pending_ids = active_ids | set(self._reservations)
                already_reserved = sum(self._reservations.values())
            if len(pending_ids) >= self._settings.max_pending_jobs:
                raise QueueFullError("任务队列已满，请稍后重试")
            required_reservation = already_reserved + reservation
            self._prune_storage(required_reservation)
            if (
                self._storage_usage() + required_reservation
                > self._settings.max_total_storage_bytes
            ):
                raise StorageLimitError("下载缓存没有足够的已预留容量")
            with self._lock:
                self._reservations[job_id] = reservation

    def _release_reservation(self, job_id: str) -> None:
        with self._lock:
            self._reservations.pop(job_id, None)

    def _prune_job_count(self) -> None:
        maximum = max(64, self._settings.max_pending_jobs * 4)
        with self._lock:
            overflow = len(self._jobs) - maximum + 1
            candidates = sorted(
                (
                    (job.updated_at, job_id)
                    for job_id, job in self._jobs.items()
                    if job.state
                    in {JobState.COMPLETED, JobState.FAILED, JobState.CANCELLED}
                )
            )
        for _, job_id in candidates[: max(0, overflow)]:
            self._remove_job(job_id)

    def _storage_usage(self) -> int:
        total = 0
        for path in self._settings.download_dir.rglob("*"):
            try:
                if path.is_file():
                    total += path.stat().st_size
            except OSError:
                continue
        return total

    def _prune_storage(self, reserved_bytes: int = 0) -> None:
        available_for_files = max(
            0, self._settings.max_total_storage_bytes - reserved_bytes
        )
        if self._storage_usage() <= available_for_files:
            return
        with self._lock:
            candidates = sorted(
                (
                    (job.updated_at, job_id)
                    for job_id, job in self._jobs.items()
                    if job.state
                    in {
                        JobState.COMPLETED,
                        JobState.FAILED,
                        JobState.CANCELLED,
                    }
                )
            )
        for _, job_id in candidates:
            self._remove_job(job_id)
            if self._storage_usage() <= min(
                available_for_files,
                self._settings.max_total_storage_bytes * 9 // 10,
            ):
                break

    def _prune(self) -> None:
        cutoff = time.time() - self._settings.job_ttl_seconds
        with self._lock:
            expired = [
                key
                for key, value in self._jobs.items()
                if value.updated_at < cutoff
                and value.state
                in {JobState.COMPLETED, JobState.FAILED, JobState.CANCELLED}
            ]
        for key in expired:
            self._remove_job(key)
        self._prune_orphans()

    def _remove_job(self, job_id: str) -> None:
        path = self._settings.download_dir / job_id
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        with self._lock:
            self._jobs.pop(job_id, None)
            self._files.pop(job_id, None)
            self._tool_specs.pop(job_id, None)
            self._cancel_events.pop(job_id, None)
            self._processes.pop(job_id, None)
            self._worker_processes.pop(job_id, None)
            self._reservations.pop(job_id, None)

    def _cleanup_partials(self, job_id: str) -> None:
        job_dir = self._settings.download_dir / job_id
        if not job_dir.is_dir():
            return
        for path in job_dir.rglob("*"):
            try:
                if path.is_file() and (
                    any(suffix.startswith(".part") for suffix in path.suffixes)
                    or path.suffix in {".aria2", ".ytdl", ".temp"}
                ):
                    path.unlink(missing_ok=True)
            except OSError:
                continue

    def _prune_orphans(self) -> None:
        cutoff = time.time() - self._settings.job_ttl_seconds
        with self._lock:
            known = set(self._jobs)
        for path in self._settings.download_dir.iterdir():
            try:
                if path.name == "_uploads" and path.is_dir():
                    for upload in path.iterdir():
                        if upload.is_file() and upload.stat().st_mtime < cutoff:
                            upload.unlink(missing_ok=True)
                    continue
                if (
                    path.is_dir()
                    and re.fullmatch(r"[0-9a-f]{32}", path.name)
                    and path.name not in known
                    and path.stat().st_mtime < cutoff
                ):
                    shutil.rmtree(path, ignore_errors=True)
            except OSError:
                continue
