from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _optional_path(name: str) -> Path | None:
    value = os.getenv(name, "").strip()
    return Path(value).expanduser().resolve() if value else None


@dataclass(frozen=True, slots=True)
class Settings:
    host: str
    port: int
    download_dir: Path
    cache_ttl_seconds: int
    job_ttl_seconds: int
    max_concurrent_jobs: int
    cors_origins: tuple[str, ...]
    cookie_file: Path | None
    ffmpeg_location: Path | None
    allow_fake_ip_dns: bool
    update_version: str = "1.0.2"
    update_notes: str = "Windows 内置解析服务，修复工具输入串值和图标缓存"
    update_windows_url: str = ""
    update_windows_sha256: str = ""
    update_android_url: str = ""
    update_ios_url: str = ""
    update_web_url: str = ""

    @classmethod
    def from_env(cls) -> "Settings":
        origins = tuple(
            item.strip()
            for item in os.getenv("MEDIA_HARBOR_CORS_ORIGINS", "*").split(",")
            if item.strip()
        )
        return cls(
            host=os.getenv("MEDIA_HARBOR_HOST", "0.0.0.0"),
            port=int(os.getenv("MEDIA_HARBOR_PORT", "8787")),
            download_dir=Path(
                os.getenv("MEDIA_HARBOR_DOWNLOAD_DIR", "./downloads")
            ).expanduser().resolve(),
            cache_ttl_seconds=max(
                60, int(os.getenv("MEDIA_HARBOR_CACHE_TTL_SECONDS", "3600"))
            ),
            job_ttl_seconds=max(
                300, int(os.getenv("MEDIA_HARBOR_JOB_TTL_SECONDS", "21600"))
            ),
            max_concurrent_jobs=max(
                1, int(os.getenv("MEDIA_HARBOR_MAX_CONCURRENT_JOBS", "2"))
            ),
            cors_origins=origins or ("*",),
            cookie_file=_optional_path("MEDIA_HARBOR_COOKIE_FILE"),
            ffmpeg_location=_optional_path("MEDIA_HARBOR_FFMPEG_LOCATION"),
            allow_fake_ip_dns=os.getenv(
                "MEDIA_HARBOR_ALLOW_FAKE_IP_DNS", "false"
            ).lower()
            in {"1", "true", "yes", "on"},
            update_version=os.getenv("LANGBAI_UPDATE_VERSION", "1.0.2").strip(),
            update_notes=os.getenv(
                "LANGBAI_UPDATE_NOTES", "Windows 内置解析服务，修复工具输入串值和图标缓存"
            ).strip(),
            update_windows_url=os.getenv("LANGBAI_UPDATE_WINDOWS_URL", "").strip(),
            update_windows_sha256=os.getenv(
                "LANGBAI_UPDATE_WINDOWS_SHA256", ""
            ).strip(),
            update_android_url=os.getenv("LANGBAI_UPDATE_ANDROID_URL", "").strip(),
            update_ios_url=os.getenv("LANGBAI_UPDATE_IOS_URL", "").strip(),
            update_web_url=os.getenv("LANGBAI_UPDATE_WEB_URL", "").strip(),
        )


settings = Settings.from_env()
