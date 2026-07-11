from pathlib import Path


BACKEND_ROOT = Path(__file__).resolve().parents[1]
PROJECT_ROOT = BACKEND_ROOT.parent


def test_ytdlp_ejs_and_javascript_runtime_are_packaged() -> None:
    requirements = (BACKEND_ROOT / "requirements.txt").read_text(encoding="utf-8")
    dockerfile = (BACKEND_ROOT / "Dockerfile").read_text(encoding="utf-8")
    lock = (BACKEND_ROOT / "requirements.lock").read_text(encoding="utf-8")
    assert "yt-dlp[default]==" in requirements
    assert "denoland/deno:bin-2.9.2" in dockerfile
    assert "COPY --from=deno /deno" in dockerfile
    assert "--require-hashes -r requirements.lock" in dockerfile
    assert "yt-dlp-ejs==" in lock


def test_default_compose_binding_is_loopback_only() -> None:
    compose = (PROJECT_ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    assert '"127.0.0.1:8787:8787"' in compose
    assert "MEDIA_HARBOR_MAX_PENDING_JOBS" in compose
    assert "MEDIA_HARBOR_INSTANCE_TOKEN" in compose
