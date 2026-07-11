import asyncio
import queue
from contextlib import asynccontextmanager

import httpx
import pytest
from PIL import Image

from app.config import Settings
from app.models import AssetKind, JobState, MediaOption
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
    assert "外部 FFmpeg" in options["match_filter"](
        {"is_live": True}, incomplete=False
    )
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
