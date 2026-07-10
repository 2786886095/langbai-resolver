from __future__ import annotations

import asyncio
import json
import re
import shutil
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

import httpx
import yt_dlp
from PIL import Image

from app.config import Settings
from app.models import DownloadJob, JobState
from app.services.extractor import DownloadSpec, ResolverService
from app.services.security import validate_public_url


def _safe_stem(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value).strip(" .")
    return cleaned[:120] or "media"


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
        settings.download_dir.mkdir(parents=True, exist_ok=True)

    def create(self, media_id: str, option_id: str) -> DownloadJob:
        self._prune()
        entry = self._resolver.get(media_id)
        if not entry:
            raise KeyError("解析结果已过期，请重新解析链接")
        if option_id not in entry.specs:
            raise KeyError("所选资源不存在")

        now = time.time()
        job = DownloadJob(
            id=uuid.uuid4().hex,
            media_id=media_id,
            option_id=option_id,
            state=JobState.QUEUED,
            created_at=now,
            updated_at=now,
        )
        self._jobs[job.id] = job
        asyncio.create_task(self._run(job.id))
        return job.model_copy(deep=True)

    def create_tool(
        self,
        source_path: Path,
        operation: str,
        output_format: str = "",
        quality: int = 78,
        display_name: str | None = None,
    ) -> DownloadJob:
        allowed = {"extract_audio", "compress_video", "compress_image", "metadata"}
        if operation not in allowed:
            raise ValueError("不支持的工具操作")
        now = time.time()
        job_id = uuid.uuid4().hex
        job_dir = self._settings.download_dir / job_id
        job_dir.mkdir(parents=True, exist_ok=True)
        display_stem = _safe_stem(Path(display_name or source_path.name).stem)
        target = job_dir / f"{display_stem}{source_path.suffix.lower()}"
        shutil.move(str(source_path), target)
        job = DownloadJob(
            id=job_id,
            media_id="local-tool",
            option_id=operation,
            state=JobState.QUEUED,
            created_at=now,
            updated_at=now,
        )
        self._jobs[job_id] = job
        self._tool_specs[job_id] = ToolJobSpec(
            operation=operation,
            input_path=target,
            output_format=output_format.lower(),
            quality=min(max(quality, 1), 100),
        )
        asyncio.create_task(self._run_tool(job_id))
        return job.model_copy(deep=True)

    def create_transfer(self, sources: str | list[str]) -> DownloadJob:
        candidates = [sources] if isinstance(sources, str) else sources
        normalized = tuple(
            dict.fromkeys(item.strip() for item in candidates if item.strip())
        )
        if not normalized:
            raise ValueError("请输入直链、Magnet 或种子链接")
        if len(normalized) > 8:
            raise ValueError("多线路下载最多支持 8 条镜像直链")
        if any(
            not item.startswith(("magnet:", "http://", "https://"))
            for item in normalized
        ):
            raise ValueError("只支持 Magnet 或公开的 http/https 链接")
        magnets = [item for item in normalized if item.startswith("magnet:")]
        if magnets and len(normalized) != 1:
            raise ValueError("Magnet 任务不能与其他下载线路混合")
        now = time.time()
        job_id = uuid.uuid4().hex
        job = DownloadJob(
            id=job_id,
            media_id="aria2-transfer",
            option_id="multi-source" if len(normalized) > 1 else "transfer",
            state=JobState.QUEUED,
            created_at=now,
            updated_at=now,
        )
        self._jobs[job_id] = job
        self._tool_specs[job_id] = ToolJobSpec(
            operation="transfer",
            source=normalized[0],
            sources=normalized,
        )
        asyncio.create_task(self._run_tool(job_id))
        return job.model_copy(deep=True)

    def create_torrent_file(self, source_path: Path) -> DownloadJob:
        if source_path.suffix.lower() != ".torrent":
            raise ValueError("请选择 .torrent 种子文件")
        now = time.time()
        job_id = uuid.uuid4().hex
        job_dir = self._settings.download_dir / job_id
        job_dir.mkdir(parents=True, exist_ok=True)
        target = job_dir / "task.torrent"
        shutil.move(str(source_path), target)
        job = DownloadJob(
            id=job_id,
            media_id="aria2-transfer",
            option_id="torrent-file",
            state=JobState.QUEUED,
            created_at=now,
            updated_at=now,
        )
        self._jobs[job_id] = job
        self._tool_specs[job_id] = ToolJobSpec(operation="transfer", input_path=target)
        asyncio.create_task(self._run_tool(job_id))
        return job.model_copy(deep=True)

    def get(self, job_id: str) -> DownloadJob | None:
        self._prune()
        job = self._jobs.get(job_id)
        return job.model_copy(deep=True) if job else None

    def file_for(self, job_id: str) -> Path | None:
        job = self._jobs.get(job_id)
        path = self._files.get(job_id)
        if not job or job.state != JobState.COMPLETED or not path or not path.is_file():
            return None
        return path

    async def _run(self, job_id: str) -> None:
        async with self._semaphore:
            job = self._jobs.get(job_id)
            if not job:
                return
            entry = self._resolver.get(job.media_id)
            if not entry or job.option_id not in entry.specs:
                self._fail(job_id, "解析结果已过期，请重新解析")
                return
            spec = entry.specs[job.option_id]
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
                    path = await asyncio.to_thread(
                        self._download_ytdlp,
                        job_id,
                        entry.media.source_url,
                        spec,
                        job_dir,
                    )
                job = self._jobs[job_id]
                job.state = JobState.COMPLETED
                job.progress = 1
                job.filename = path.name
                job.download_url = f"/api/v1/jobs/{job_id}/file"
                job.updated_at = time.time()
                self._files[job_id] = path
            except Exception as exc:  # Download errors vary by extractor.
                self._fail(job_id, str(exc)[:500])

    async def _run_tool(self, job_id: str) -> None:
        async with self._semaphore:
            job = self._jobs.get(job_id)
            spec = self._tool_specs.get(job_id)
            if not job or not spec:
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
                job = self._jobs[job_id]
                job.state = JobState.COMPLETED
                job.progress = 1
                job.filename = path.name
                job.download_url = f"/api/v1/jobs/{job_id}/file"
                job.updated_at = time.time()
                self._files[job_id] = path
            except Exception as exc:
                self._fail(job_id, str(exc)[:500])

    async def _download_direct(
        self, job_id: str, title: str, spec: DownloadSpec, job_dir: Path
    ) -> Path:
        assert spec.direct_url
        await asyncio.to_thread(
            validate_public_url,
            spec.direct_url,
            self._settings.allow_fake_ip_dns,
        )
        filename = f"{_safe_stem(title)}.{spec.option.extension}"
        path = job_dir / filename
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            )
        }
        async with httpx.AsyncClient(
            headers=headers, timeout=60, follow_redirects=True
        ) as client:
            total: int | None = None
            supports_ranges = False
            try:
                head = await client.head(spec.direct_url)
                if head.is_success:
                    total = int(head.headers.get("content-length", "0")) or None
                    supports_ranges = (
                        head.headers.get("accept-ranges", "").lower() == "bytes"
                    )
            except (httpx.HTTPError, ValueError):
                pass
            if total and total >= 8 * 1024 * 1024 and supports_ranges:
                await self._download_segmented(
                    client, [spec.direct_url], path, job_id, total, segments=8
                )
                return path
            async with client.stream("GET", spec.direct_url) as response:
                response.raise_for_status()
                total = (
                    total or int(response.headers.get("content-length", "0")) or None
                )
                downloaded = 0
                with path.open("wb") as output:
                    async for chunk in response.aiter_bytes(256 * 1024):
                        output.write(chunk)
                        downloaded += len(chunk)
                        self._update_progress(job_id, downloaded, total, None, None)
        return path

    async def _download_segmented(
        self,
        client: httpx.AsyncClient,
        urls: list[str],
        target: Path,
        job_id: str,
        total: int,
        segments: int,
    ) -> None:
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
                    async with client.stream(
                        "GET", url, headers={"Range": f"bytes={start}-{end}"}
                    ) as response:
                        if response.status_code != 206:
                            raise RuntimeError("服务器未按 Range 返回分段内容")
                        with part_paths[index].open("wb") as output:
                            async for chunk in response.aiter_bytes(256 * 1024):
                                output.write(chunk)
                                async with lock:
                                    downloaded[index] += len(chunk)
                                    self._update_progress(
                                        job_id, sum(downloaded), total, None, None
                                    )
                    if part_paths[index].stat().st_size != expected:
                        raise RuntimeError("下载分段大小与预期不一致")
                    return
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
            await asyncio.gather(*(fetch(index) for index in range(segments)))
            with target.open("wb") as output:
                for part in part_paths:
                    with part.open("rb") as source:
                        shutil.copyfileobj(source, output, length=1024 * 1024)
        finally:
            for part in part_paths:
                part.unlink(missing_ok=True)

    async def _download_mirrors(
        self, job_id: str, urls: list[str], job_dir: Path
    ) -> Path:
        for url in urls:
            await asyncio.to_thread(
                validate_public_url, url, self._settings.allow_fake_ip_dns
            )
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            )
        }
        async with httpx.AsyncClient(
            headers=headers, timeout=60, follow_redirects=True
        ) as client:

            async def probe(url: str) -> tuple[str, int | None, bool, float]:
                started = time.monotonic()
                try:
                    response = await client.head(url)
                    response.raise_for_status()
                    size = int(response.headers.get("content-length", "0")) or None
                    ranges = (
                        response.headers.get("accept-ranges", "").lower() == "bytes"
                    )
                    return url, size, ranges, time.monotonic() - started
                except (httpx.HTTPError, ValueError):
                    return url, None, False, float("inf")

            probes = await asyncio.gather(*(probe(url) for url in urls))
            available = sorted(probes, key=lambda item: item[3])
            responsive = [item for item in available if item[3] != float("inf")]
            selected = responsive[0][0] if responsive else urls[0]
            filename = Path(unquote(urlparse(selected).path)).name or "download.bin"
            raw_suffix = Path(filename).suffix
            suffix = raw_suffix if 1 < len(raw_suffix) <= 12 else ".bin"
            target = job_dir / f"{_safe_stem(Path(filename).stem)}{suffix}"

            range_probes = [item for item in responsive if item[1] and item[2]]
            if range_probes:
                size_groups: dict[int, list[str]] = {}
                for url, size, _, _ in range_probes:
                    assert size is not None
                    size_groups.setdefault(size, []).append(url)
                total, compatible = max(
                    size_groups.items(), key=lambda item: (len(item[1]), item[0])
                )
                if total >= 8 * 1024 * 1024:
                    segments = min(8, max(4, len(compatible) * 2))
                    await self._download_segmented(
                        client,
                        compatible,
                        target,
                        job_id,
                        total,
                        segments=segments,
                    )
                    return target

            async with client.stream("GET", selected) as response:
                response.raise_for_status()
                total = int(response.headers.get("content-length", "0")) or None
                downloaded = 0
                with target.open("wb") as output:
                    async for chunk in response.aiter_bytes(256 * 1024):
                        output.write(chunk)
                        downloaded += len(chunk)
                        self._update_progress(job_id, downloaded, total, None, None)
            return target

    def _process_tool(self, job_id: str, spec: ToolJobSpec, job_dir: Path) -> Path:
        if not spec.input_path or not spec.input_path.is_file():
            raise RuntimeError("上传文件不存在")
        source = spec.input_path
        stem = _safe_stem(source.stem)
        if spec.operation == "compress_image":
            extension = (
                spec.output_format
                if spec.output_format in {"jpg", "jpeg", "png", "webp"}
                else "webp"
            )
            target = job_dir / f"{stem}-compressed.{extension}"
            with Image.open(source) as image:
                image.thumbnail((3840, 3840), Image.Resampling.LANCZOS)
                if extension in {"jpg", "jpeg"} and image.mode not in {"RGB", "L"}:
                    image = image.convert("RGB")
                image.save(target, quality=spec.quality, optimize=True)
            self._jobs[job_id].progress = 0.99
            return target
        if spec.operation == "metadata":
            target = job_dir / f"{stem}-metadata.json"
            command = [
                self._ffprobe_binary(),
                "-v",
                "quiet",
                "-show_format",
                "-show_streams",
                "-of",
                "json",
                str(source),
            ]
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            parsed = json.loads(result.stdout)
            target.write_text(
                json.dumps(parsed, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            self._jobs[job_id].progress = 0.99
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
        duration = self._probe_duration(source)
        command = [
            self._ffmpeg_binary(),
            "-y",
            "-i",
            str(source),
            *output_args,
            "-progress",
            "pipe:1",
            "-nostats",
            str(target),
        ]
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        assert process.stdout
        tail: list[str] = []
        for line in process.stdout:
            line = line.strip()
            tail.append(line)
            tail = tail[-12:]
            if line.startswith("out_time_ms=") and duration:
                try:
                    current = int(line.split("=", 1)[1]) / 1_000_000
                    self._jobs[job_id].progress = min(0.99, current / duration)
                    self._jobs[job_id].updated_at = time.time()
                except ValueError:
                    pass
        if process.wait() != 0:
            raise RuntimeError("FFmpeg 处理失败：" + " | ".join(tail[-4:]))

    def _probe_duration(self, source: Path) -> float | None:
        result = subprocess.run(
            [
                self._ffprobe_binary(),
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
        )
        try:
            return float(result.stdout.strip())
        except ValueError:
            return None

    def _ffmpeg_binary(self) -> str:
        if self._settings.ffmpeg_location:
            location = self._settings.ffmpeg_location
            return str(location / "ffmpeg" if location.is_dir() else location)
        return shutil.which("ffmpeg") or "ffmpeg"

    def _ffprobe_binary(self) -> str:
        if self._settings.ffmpeg_location:
            location = self._settings.ffmpeg_location
            if location.is_dir():
                return str(location / "ffprobe")
            return str(location.with_name("ffprobe"))
        return shutil.which("ffprobe") or "ffprobe"

    def _run_transfer(self, job_id: str, source: str, job_dir: Path) -> Path:
        if source.startswith(("http://", "https://")):
            validate_public_url(source, self._settings.allow_fake_ip_dns)
        aria2 = shutil.which("aria2c")
        if not aria2:
            raise RuntimeError("服务器未安装 aria2，无法处理磁力或种子任务")
        command = [
            aria2,
            "--dir",
            str(job_dir),
            "--seed-time=0",
            "--file-allocation=none",
            "--auto-file-renaming=true",
            "--summary-interval=1",
            "--console-log-level=notice",
            source,
        ]
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        assert process.stdout
        tail: list[str] = []
        percent_pattern = re.compile(r"\((\d+)%\)")
        for line in process.stdout:
            line = line.strip()
            tail.append(line)
            tail = tail[-12:]
            match = percent_pattern.search(line)
            if match:
                self._jobs[job_id].progress = min(0.99, int(match.group(1)) / 100)
                self._jobs[job_id].updated_at = time.time()
        if process.wait() != 0:
            raise RuntimeError("aria2 下载失败：" + " | ".join(tail[-4:]))
        files = [
            path
            for path in job_dir.rglob("*")
            if path.is_file() and path.suffix not in {".aria2", ".torrent"}
        ]
        if not files:
            raise RuntimeError("下载完成但未找到文件")
        if len(files) == 1:
            return files[0]
        archive_base = job_dir.parent / f"{job_id}-files"
        archive_path = Path(shutil.make_archive(str(archive_base), "zip", job_dir))
        target = job_dir / "torrent-files.zip"
        shutil.move(str(archive_path), target)
        return target

    def _download_ytdlp(
        self,
        job_id: str,
        source_url: str,
        spec: DownloadSpec,
        job_dir: Path,
    ) -> Path:
        def progress_hook(data: dict[str, Any]) -> None:
            if data.get("status") == "downloading":
                total = data.get("total_bytes") or data.get("total_bytes_estimate")
                self._update_progress(
                    job_id,
                    int(data.get("downloaded_bytes") or 0),
                    int(total) if total else None,
                    float(data.get("speed")) if data.get("speed") else None,
                    int(data.get("eta")) if data.get("eta") is not None else None,
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
        if self._settings.ffmpeg_location:
            options["ffmpeg_location"] = str(self._settings.ffmpeg_location)

        with yt_dlp.YoutubeDL(options) as ydl:
            ydl.download([source_url])

        files = [
            path
            for path in job_dir.iterdir()
            if path.is_file() and path.suffix not in {".part", ".ytdl", ".temp"}
        ]
        if not files:
            raise RuntimeError("下载完成但未找到输出文件")
        return max(files, key=lambda path: path.stat().st_mtime)

    def _update_progress(
        self,
        job_id: str,
        downloaded: int,
        total: int | None,
        speed: float | None,
        eta: int | None,
    ) -> None:
        job = self._jobs.get(job_id)
        if not job:
            return
        job.downloaded_bytes = downloaded
        job.total_bytes = total
        job.speed_bytes_per_second = speed
        job.eta_seconds = eta
        if total:
            job.progress = min(0.99, downloaded / total)
        job.updated_at = time.time()

    def _fail(self, job_id: str, message: str) -> None:
        job = self._jobs.get(job_id)
        if not job:
            return
        job.state = JobState.FAILED
        job.error = message or "下载失败"
        job.updated_at = time.time()

    def _prune(self) -> None:
        cutoff = time.time() - self._settings.job_ttl_seconds
        expired = [
            key for key, value in self._jobs.items() if value.updated_at < cutoff
        ]
        for key in expired:
            path = self._settings.download_dir / key
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            self._jobs.pop(key, None)
            self._files.pop(key, None)
            self._tool_specs.pop(key, None)
