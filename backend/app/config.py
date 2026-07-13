from __future__ import annotations

import os
import ipaddress
import secrets
from dataclasses import dataclass
from pathlib import Path


def _optional_path(name: str) -> Path | None:
    value = os.getenv(name, "").strip()
    return Path(value).expanduser().resolve() if value else None


def _bounded_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError:
        value = default
    return min(max(value, minimum), maximum)


def _enabled(name: str, default: str = "false") -> bool:
    return os.getenv(name, default).lower() in {"1", "true", "yes", "on"}


def _is_loopback_host(value: str) -> bool:
    host = value.strip().strip("[]").lower()
    if host in {"localhost", "localhost.localdomain"}:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


@dataclass(frozen=True, slots=True)
class Settings:
    host: str
    port: int
    download_dir: Path
    cache_ttl_seconds: int
    job_ttl_seconds: int
    max_concurrent_jobs: int
    cors_origins: tuple[str, ...]
    ffmpeg_location: Path | None
    allow_fake_ip_dns: bool
    max_pending_jobs: int = 32
    max_download_bytes: int = 8 * 1024 * 1024 * 1024
    max_upload_bytes: int = 4 * 1024 * 1024 * 1024
    max_total_storage_bytes: int = 32 * 1024 * 1024 * 1024
    max_html_bytes: int = 8 * 1024 * 1024
    max_redirects: int = 5
    job_timeout_seconds: int = 3600
    allow_peer_to_peer: bool = False
    instance_token: str | None = None
    instance_id: str = ""
    jamendo_client_id: str | None = None
    audius_api_key: str | None = None
    update_version: str = "1.1.5"
    update_notes: str = (
        "解析缓存与预热、自适应图片预览、全屏缩放、全面媒体格式转换与安装包体积优化。"
    )
    update_windows_url: str = ""
    update_windows_sha256: str = ""
    update_windows_size_bytes: int | None = None
    update_windows_signing_certificate_sha256: str = ""
    update_android_url: str = ""
    update_ios_url: str = ""
    update_web_url: str = ""

    @classmethod
    def from_env(cls) -> "Settings":
        host = os.getenv("MEDIA_HARBOR_HOST", "127.0.0.1").strip()
        instance_token = os.getenv("MEDIA_HARBOR_INSTANCE_TOKEN", "").strip() or None
        if instance_token:
            try:
                token_bytes = instance_token.encode("ascii")
            except UnicodeEncodeError as exc:
                raise ValueError(
                    "MEDIA_HARBOR_INSTANCE_TOKEN 必须使用 ASCII 字符"
                ) from exc
            if len(token_bytes) < 32:
                raise ValueError("MEDIA_HARBOR_INSTANCE_TOKEN 必须至少包含 32 字节")
        if not _is_loopback_host(host) and not instance_token:
            raise ValueError("非回环地址监听必须配置 MEDIA_HARBOR_INSTANCE_TOKEN")
        origins = tuple(
            item.strip()
            for item in os.getenv(
                "MEDIA_HARBOR_CORS_ORIGINS",
                "http://127.0.0.1:8787,http://localhost:8787",
            ).split(",")
            if item.strip()
        )
        return cls(
            host=host,
            port=_bounded_int("MEDIA_HARBOR_PORT", 8787, 1, 65535),
            download_dir=Path(os.getenv("MEDIA_HARBOR_DOWNLOAD_DIR", "./downloads"))
            .expanduser()
            .resolve(),
            cache_ttl_seconds=_bounded_int(
                "MEDIA_HARBOR_CACHE_TTL_SECONDS", 3600, 60, 24 * 60 * 60
            ),
            job_ttl_seconds=_bounded_int(
                "MEDIA_HARBOR_JOB_TTL_SECONDS", 21600, 300, 7 * 24 * 60 * 60
            ),
            max_concurrent_jobs=_bounded_int(
                "MEDIA_HARBOR_MAX_CONCURRENT_JOBS", 2, 1, 32
            ),
            cors_origins=origins or ("http://127.0.0.1:8787", "http://localhost:8787"),
            ffmpeg_location=_optional_path("MEDIA_HARBOR_FFMPEG_LOCATION"),
            allow_fake_ip_dns=_enabled("MEDIA_HARBOR_ALLOW_FAKE_IP_DNS"),
            max_pending_jobs=_bounded_int("MEDIA_HARBOR_MAX_PENDING_JOBS", 32, 1, 512),
            max_download_bytes=_bounded_int(
                "MEDIA_HARBOR_MAX_DOWNLOAD_BYTES",
                8 * 1024 * 1024 * 1024,
                1024 * 1024,
                64 * 1024 * 1024 * 1024,
            ),
            max_upload_bytes=_bounded_int(
                "MEDIA_HARBOR_MAX_UPLOAD_BYTES",
                4 * 1024 * 1024 * 1024,
                1024 * 1024,
                32 * 1024 * 1024 * 1024,
            ),
            max_total_storage_bytes=_bounded_int(
                "MEDIA_HARBOR_MAX_TOTAL_STORAGE_BYTES",
                32 * 1024 * 1024 * 1024,
                64 * 1024 * 1024,
                512 * 1024 * 1024 * 1024,
            ),
            max_html_bytes=_bounded_int(
                "MEDIA_HARBOR_MAX_HTML_BYTES",
                8 * 1024 * 1024,
                64 * 1024,
                32 * 1024 * 1024,
            ),
            max_redirects=_bounded_int("MEDIA_HARBOR_MAX_REDIRECTS", 5, 0, 12),
            job_timeout_seconds=_bounded_int(
                "MEDIA_HARBOR_JOB_TIMEOUT_SECONDS", 3600, 30, 24 * 60 * 60
            ),
            allow_peer_to_peer=_enabled("MEDIA_HARBOR_ALLOW_PEER_TO_PEER"),
            instance_token=instance_token,
            instance_id=os.getenv("MEDIA_HARBOR_INSTANCE_ID", "").strip()
            or secrets.token_hex(8),
            jamendo_client_id=os.getenv("JAMENDO_CLIENT_ID", "").strip() or None,
            audius_api_key=os.getenv("AUDIUS_API_KEY", "").strip() or None,
            update_version=os.getenv("LANGBAI_UPDATE_VERSION", "1.1.5").strip(),
            update_notes=os.getenv(
                "LANGBAI_UPDATE_NOTES",
                "解析缓存与预热、自适应图片预览、全面媒体格式转换与安装包体积优化。",
            ).strip(),
            update_windows_url=os.getenv("LANGBAI_UPDATE_WINDOWS_URL", "").strip(),
            update_windows_sha256=os.getenv(
                "LANGBAI_UPDATE_WINDOWS_SHA256", ""
            ).strip(),
            update_windows_size_bytes=(
                _bounded_int(
                    "LANGBAI_UPDATE_WINDOWS_SIZE_BYTES",
                    0,
                    0,
                    64 * 1024 * 1024 * 1024,
                )
                or None
            ),
            update_windows_signing_certificate_sha256=os.getenv(
                "LANGBAI_UPDATE_WINDOWS_SIGNING_CERTIFICATE_SHA256", ""
            ).strip(),
            update_android_url=os.getenv("LANGBAI_UPDATE_ANDROID_URL", "").strip(),
            update_ios_url=os.getenv("LANGBAI_UPDATE_IOS_URL", "").strip(),
            update_web_url=os.getenv("LANGBAI_UPDATE_WEB_URL", "").strip(),
        )


settings = Settings.from_env()
