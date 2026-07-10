import asyncio

from PIL import Image

from app.config import Settings
from app.models import JobState
from app.services.extractor import ResolverService
from app.services.jobs import JobManager


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
            cookie_file=None,
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


def test_multi_source_transfer_normalizes_mirrors(tmp_path) -> None:
    async def scenario() -> None:
        settings = Settings(
            host="127.0.0.1",
            port=8787,
            download_dir=tmp_path / "downloads",
            cache_ttl_seconds=3600,
            job_ttl_seconds=3600,
            max_concurrent_jobs=1,
            cors_origins=("*",),
            cookie_file=None,
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
