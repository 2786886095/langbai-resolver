import asyncio
import queue
from contextlib import asynccontextmanager

import httpx
import pytest
from PIL import Image

from app.config import Settings
from app.models import AssetKind, DownloadJob, JobState, MediaOption
from app.services.extractor import DownloadSpec, ResolverService
from app.services.jobs import (
    JobCancelledError,
    JobManager,
    QueueFullError,
    StorageLimitError,
    ToolJobSpec,
    _run_ytdlp_worker,
)


def test_image_compression_job(tmp_path) -> None:
    async def scenario() -> None:
        source = tmp_path / "source.png"
        Image.new("RGB", (640, 360), (75, 110, 220)).save(source)
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("*",),
            ffmpeg_location=None,
            allow_fake_ip_dns=False,
        )
        resolver = ResolverService(settings)
        jobs = JobManager(settings, resolver)
        job = jobs.create_tool(
            source,
            operation="compress_image",
            output_format="webp",
            quality=70,
        )
        for _ in range(100):
            await asyncio.sleep(0.02)
            job = jobs.get(job.id)
            if job and job.state not in {JobState.QUEUED, JobState.RUNNING}:
                break
        assert job is not None
        assert job.state == JobState.COMPLETED
        output = jobs.file_for(job.id)
        assert output is not None
        assert output.suffix == ".webp"
        assert output.stat().st_size > 0

    asyncio.run(scenario())


@pytest.mark.parametrize(
    ("output_format", "expected_codec"),
    [
        ("mp4", "libx264"),
        ("mkv", "libx264"),
        ("webm", "libvpx-vp9"),
        ("avi", "mpeg4"),
        ("mp3", "libmp3lame"),
        ("flac", "flac"),
        ("opus", "libopus"),
        ("webp", "libwebp"),
        ("tiff", "tiff"),
    ],
)
def test_comprehensive_media_conversion_matrix(
    output_format: str,
    expected_codec: str,
) -> None:
    arguments = JobManager._media_conversion_arguments(
        output_format,
        crf=24,
        audio_bitrate="256k",
        quality=88,
    )
    assert expected_codec in arguments


def test_mkv_conversion_does_not_use_mov_muxer_flags() -> None:
    arguments = JobManager._media_conversion_arguments(
        "mkv",
        crf=24,
        audio_bitrate="256k",
        quality=88,
    )
    assert "-movflags" not in arguments
    assert "+faststart" not in arguments


def test_media_conversion_matrix_rejects_unknown_output() -> None:
    with pytest.raises(ValueError, match="DOCX"):
        JobManager._media_conversion_arguments(
            "docx",
            crf=24,
            audio_bitrate="256k",
            quality=88,
        )


def test_multi_source_transfer_normalizes_mirrors(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.jobs.validate_public_url", lambda value, _allow=False: value
    )

    async def scenario() -> None:
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("*",),
            ffmpeg_location=None,
            allow_fake_ip_dns=False,
        )
        jobs = JobManager(settings, ResolverService(settings))

        async def no_op(_: str) -> None:
            return None

        jobs._run_tool = no_op  # type: ignore[method-assign]
        job = jobs.create_transfer(
            [
                "https://cdn-a.example/file.bin",
                "https://cdn-b.example/file.bin",
                "https://cdn-a.example/file.bin",
            ]
        )
        await asyncio.sleep(0)
        spec = jobs._tool_specs[job.id]
        assert spec.sources == (
            "https://cdn-a.example/file.bin",
            "https://cdn-b.example/file.bin",
        )
        assert job.option_id == "multi-source"

    asyncio.run(scenario())


def test_cancel_is_terminal_and_queue_is_bounded(tmp_path) -> None:
    async def scenario() -> None:
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("http://localhost",),
            ffmpeg_location=None,
            allow_fake_ip_dns=False,
            max_pending_jobs=1,
        )
        jobs = JobManager(settings, ResolverService(settings))

        async def slow(_job_id: str) -> None:
            await asyncio.sleep(60)

        jobs._run_tool = slow  # type: ignore[method-assign]
        first = tmp_path / "first.png"
        second = tmp_path / "second.png"
        Image.new("RGB", (32, 32)).save(first)
        Image.new("RGB", (32, 32)).save(second)
        job = jobs.create_tool(first, "compress_image")
        with pytest.raises(QueueFullError):
            jobs.create_tool(second, "compress_image")
        cancelled = jobs.cancel(job.id)
        assert cancelled is not None
        assert cancelled.state == JobState.CANCELLED
        await asyncio.sleep(0)
        assert jobs.get(job.id).state == JobState.CANCELLED  # type: ignore[union-attr]

    asyncio.run(scenario())


def test_rejects_playlist_before_ffmpeg_can_fetch_nested_urls(tmp_path) -> None:
    settings = Settings(
        host="127.0.0.1",
        port=8787,
        download_dir=tmp_path / "downloads",
        cache_ttl_seconds=3600,
        job_ttl_seconds=3600,
        max_concurrent_jobs=1,
        cors_origins=("http://localhost",),
        ffmpeg_location=None,
        allow_fake_ip_dns=False,
    )
    jobs = JobManager(settings, ResolverService(settings))
    playlist = tmp_path / "input.bin"
    playlist.write_text("#EXTM3U\nhttp://127.0.0.1/secret.ts\n", encoding="utf-8")
    with pytest.raises(ValueError, match="播放列表"):
        jobs._process_tool(
            "missing-job",
            ToolJobSpec(operation="metadata", input_path=playlist),
            tmp_path,
        )


def test_peer_to_peer_is_disabled_by_default(tmp_path) -> None:
    settings = Settings(
        host="127.0.0.1",
        port=8787,
        download_dir=tmp_path / "downloads",
        cache_ttl_seconds=3600,
        job_ttl_seconds=3600,
        max_concurrent_jobs=1,
        cors_origins=("http://localhost",),
        ffmpeg_location=None,
        allow_fake_ip_dns=False,
    )
    jobs = JobManager(settings, ResolverService(settings))
    with pytest.raises(ValueError, match="默认关闭"):
        jobs.create_transfer("magnet:?xt=urn:btih:0123456789abcdef")


def test_pending_jobs_reserve_total_storage_before_any_bytes_are_written(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(
        "app.services.jobs.validate_public_url", lambda value, _allow=False: value
    )

    async def scenario() -> None:
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("http://localhost",),
            ffmpeg_location=None,
            allow_fake_ip_dns=False,
            max_pending_jobs=8,
            max_download_bytes=8,
            max_total_storage_bytes=32,
        )
        jobs = JobManager(settings, ResolverService(settings))

        async def stalled(_job_id: str) -> None:
            await asyncio.sleep(60)

        jobs._run_tool = stalled  # type: ignore[method-assign]
        first = jobs.create_transfer("https://one.example/file.bin")
        second = jobs.create_transfer("https://two.example/file.bin")
        with pytest.raises(StorageLimitError, match="预留容量"):
            jobs.create_transfer("https://three.example/file.bin")
        assert jobs._storage_usage() == 0
        assert sum(jobs._reservations.values()) == 32
        jobs.cancel(first.id)
        jobs.cancel(second.id)
        await asyncio.sleep(0)
        jobs.shutdown()

    asyncio.run(scenario())


def test_segmented_download_rejects_bytes_beyond_the_declared_range(
    tmp_path, monkeypatch
) -> None:
    @asynccontextmanager
    async def oversized_range(_client, method, url, **_kwargs):
        yield httpx.Response(
            206,
            headers={"content-range": "bytes 0-3/4"},
            content=b"12345",
            request=httpx.Request(method, url),
        )

    monkeypatch.setattr(
        "app.services.jobs.stream_public_response_async", oversized_range
    )

    async def scenario() -> None:
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("http://localhost",),
            ffmpeg_location=None,
            allow_fake_ip_dns=False,
            max_download_bytes=4,
        )
        jobs = JobManager(settings, ResolverService(settings))
        target = settings.download_dir / "result.bin"
        async with httpx.AsyncClient() as client:
            with pytest.raises(RuntimeError) as captured:
                await jobs._download_segmented(
                    client,
                    ["https://range.example/file.bin"],
                    target,
                    "range-job",
                    total=4,
                    segments=1,
                )
        chain: list[str] = []
        error: BaseException | None = captured.value
        while error is not None:
            chain.append(str(error))
            error = error.__cause__
        assert any("超出范围" in message for message in chain)
        assert not target.exists()
        jobs.shutdown()

    asyncio.run(scenario())


def test_direct_download_falls_back_to_sequential_get_when_ranges_are_broken(
    tmp_path, monkeypatch
) -> None:
    calls: list[str] = []

    @asynccontextmanager
    async def fake_stream(_client, method, url, **_kwargs):
        calls.append(method)
        if method == "HEAD":
            yield httpx.Response(
                200,
                headers={
                    "content-length": str(8 * 1024 * 1024),
                    "accept-ranges": "bytes",
                },
                request=httpx.Request(method, url),
            )
        else:
            yield httpx.Response(
                200,
                headers={"content-length": "8"},
                content=b"fallback",
                request=httpx.Request(method, url),
            )

    monkeypatch.setattr("app.services.jobs.stream_public_response_async", fake_stream)

    async def scenario() -> None:
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("http://localhost",),
            ffmpeg_location=None,
            allow_fake_ip_dns=False,
        )
        jobs = JobManager(settings, ResolverService(settings))

        async def broken_ranges(*_args, **_kwargs) -> None:
            raise RuntimeError("range unsupported")

        monkeypatch.setattr(jobs, "_download_segmented", broken_ranges)
        option = MediaOption(
            id="video:direct",
            kind=AssetKind.VIDEO,
            label="Direct",
            extension="bin",
        )
        spec = DownloadSpec(
            option=option,
            direct_url="https://download.example/file.bin",
        )
        job_dir = settings.download_dir / "fallback-job"
        job_dir.mkdir(parents=True)
        result = await jobs._download_direct("fallback-job", "sample", spec, job_dir)
        assert result.read_bytes() == b"fallback"
        assert calls == ["HEAD", "GET"]
        jobs.shutdown()

    asyncio.run(scenario())


def test_direct_download_uses_explicit_compatibility_url(tmp_path, monkeypatch) -> None:
    calls: list[tuple[str, str]] = []

    @asynccontextmanager
    async def fake_stream(_client, method, url, **_kwargs):
        calls.append((method, url))
        if "clean.example" in url:
            if method == "HEAD":
                yield httpx.Response(
                    200,
                    headers={"content-length": "32"},
                    request=httpx.Request(method, url),
                )
            else:
                yield httpx.Response(
                    200,
                    headers={"content-type": "text/html; charset=utf-8"},
                    content=b"<html>temporary risk control</html>",
                    request=httpx.Request(method, url),
                )
        elif "empty.example" in url:
            yield httpx.Response(
                200,
                content=b"",
                request=httpx.Request(method, url),
            )
        elif method == "HEAD":
            yield httpx.Response(
                200,
                headers={"content-length": "8"},
                request=httpx.Request(method, url),
            )
        else:
            yield httpx.Response(
                200,
                headers={"content-length": "8"},
                content=b"fallback",
                request=httpx.Request(method, url),
            )

    monkeypatch.setattr("app.services.jobs.stream_public_response_async", fake_stream)

    async def scenario() -> None:
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("http://localhost",),
            ffmpeg_location=None,
            allow_fake_ip_dns=False,
        )
        jobs = JobManager(settings, ResolverService(settings))
        option = MediaOption(
            id="video:douyin-share",
            kind=AssetKind.VIDEO,
            label="Clean first",
            extension="mp4",
        )
        spec = DownloadSpec(
            option=option,
            direct_url="https://clean.example/video.mp4",
            fallback_urls=(
                "https://empty.example/video.mp4",
                "https://watermark.example/video.mp4",
            ),
        )
        job_dir = settings.download_dir / "compatibility-job"
        job_dir.mkdir(parents=True)
        result = await jobs._download_direct(
            "compatibility-job", "sample", spec, job_dir
        )
        assert result.read_bytes() == b"fallback"
        assert calls == [
            ("HEAD", "https://clean.example/video.mp4"),
            ("GET", "https://clean.example/video.mp4"),
            ("HEAD", "https://empty.example/video.mp4"),
            ("GET", "https://empty.example/video.mp4"),
            ("HEAD", "https://watermark.example/video.mp4"),
            ("GET", "https://watermark.example/video.mp4"),
        ]
        jobs.shutdown()

    asyncio.run(scenario())


def test_direct_progress_calculates_speed_and_eta(tmp_path, monkeypatch) -> None:
    settings = Settings(
        host="127.0.0.1",
        port=8787,
        download_dir=tmp_path / "downloads",
        cache_ttl_seconds=3600,
        job_ttl_seconds=3600,
        max_concurrent_jobs=1,
        cors_origins=("http://localhost",),
        ffmpeg_location=None,
        allow_fake_ip_dns=False,
    )
    jobs = JobManager(settings, ResolverService(settings))
    now = 1000.0
    jobs._jobs["speed-job"] = DownloadJob(
        id="speed-job",
        media_id="media-speed",
        option_id="video:test",
        state=JobState.RUNNING,
        created_at=now,
        updated_at=now,
    )
    samples = iter((10.0, 12.0, 13.0, 15.0))
    monkeypatch.setattr("app.services.jobs.time.monotonic", lambda: next(samples))

    jobs._update_progress("speed-job", 0, 10_240, None, None)
    jobs._update_progress("speed-job", 2_048, 10_240, None, None)
    job = jobs.get("speed-job")

    assert job is not None
    assert job.speed_bytes_per_second == pytest.approx(1_024)
    assert job.eta_seconds == 8
    assert job.progress == pytest.approx(0.2)

    jobs._update_progress("speed-job", 0, 10_240, None, None)
    restarted = jobs.get("speed-job")
    assert restarted is not None
    assert restarted.speed_bytes_per_second is None
    assert restarted.eta_seconds is None

    jobs._update_progress("speed-job", 1_024, 10_240, None, None)
    resumed = jobs.get("speed-job")
    assert resumed is not None
    assert resumed.speed_bytes_per_second == pytest.approx(512)
    assert resumed.eta_seconds == 18
    jobs.shutdown()


def test_ytdlp_worker_forces_native_hls_and_rejects_live_streams(
    tmp_path, monkeypatch
) -> None:
    captured: dict[str, object] = {}

    class FakeYDL:
        def __init__(self, options, **kwargs):
            captured["options"] = options
            captured["kwargs"] = kwargs

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def download(self, _urls):
            (tmp_path / "job" / "result.mp4").write_bytes(b"video")

    monkeypatch.setattr("app.services.jobs.SafeYoutubeDL", FakeYDL)
    if hasattr(__import__("os"), "setsid"):
        monkeypatch.setattr("app.services.jobs.os.setsid", lambda: None)
    settings = Settings(
        host="127.0.0.1",
        port=8787,
        download_dir=tmp_path / "downloads",
        cache_ttl_seconds=3600,
        job_ttl_seconds=3600,
        max_concurrent_jobs=1,
        cors_origins=("http://localhost",),
        ffmpeg_location=None,
        allow_fake_ip_dns=False,
    )
    option = MediaOption(
        id="video:hls",
        kind=AssetKind.VIDEO,
        label="HLS",
        extension="mp4",
    )
    messages: queue.Queue = queue.Queue()
    _run_ytdlp_worker(
        "https://media.example/live.m3u8",
        DownloadSpec(option=option, selector="best"),
        tmp_path / "job",
        settings,
        messages,
    )
    options = captured["options"]
    assert isinstance(options, dict)
    assert options["hls_prefer_native"] is True
    assert options["external_downloader"]["m3u8"] == "native"
    assert "外部 FFmpeg" in options["match_filter"]({"is_live": True}, incomplete=False)
    assert "外部下载器" in options["match_filter"](
        {"protocol": "rtmp"}, incomplete=False
    )
    assert messages.get_nowait()[0] == "result"


def test_cancelling_isolated_ytdlp_kills_its_worker_process(
    tmp_path, monkeypatch
) -> None:
    class FakeQueue:
        def get_nowait(self):
            raise queue.Empty

        def close(self):
            pass

        def cancel_join_thread(self):
            pass

    class FakeProcess:
        pid = None
        exitcode = None

        def __init__(self):
            self.alive = False
            self.killed = False

        def start(self):
            self.alive = True

        def is_alive(self):
            return self.alive

        def kill(self):
            self.killed = True
            self.alive = False
            self.exitcode = -9

        def join(self, timeout=None):
            del timeout

    class FakeContext:
        def __init__(self):
            self.process = FakeProcess()

        def Queue(self):
            return FakeQueue()

        def Process(self, **_kwargs):
            return self.process

    async def scenario() -> None:
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("http://localhost",),
            ffmpeg_location=None,
            allow_fake_ip_dns=False,
        )
        jobs = JobManager(settings, ResolverService(settings))
        context = FakeContext()
        monkeypatch.setattr(jobs, "_multiprocessing_context", lambda: context)
        jobs._cancel_event("cancel-worker").set()
        option = MediaOption(
            id="video:test",
            kind=AssetKind.VIDEO,
            label="test",
            extension="mp4",
        )
        with pytest.raises(JobCancelledError):
            await jobs._download_ytdlp_isolated(
                "cancel-worker",
                "https://media.example/video",
                DownloadSpec(option=option, selector="best"),
                tmp_path / "worker-job",
            )
        assert context.process.killed is True
        assert "cancel-worker" not in jobs._worker_processes
        jobs.shutdown()

    asyncio.run(scenario())
