from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, Field


class AssetKind(str, Enum):
    VIDEO = "video"
    AUDIO = "audio"
    IMAGE = "image"


class ResolveRequest(BaseModel):
    url: str = Field(min_length=8, max_length=4096)
    bilibili_cookie: str | None = Field(default=None, max_length=8192)


class MediaOption(BaseModel):
    id: str
    kind: AssetKind
    label: str
    extension: str
    resolution: str | None = None
    bitrate_kbps: int | None = None
    fps: float | None = None
    filesize: int | None = None
    filesize_label: str | None = None
    preview_url: str | None = None
    requires_merge: bool = False


class MediaInfo(BaseModel):
    media_id: str
    source_url: str
    title: str
    creator: str | None = None
    platform: str
    duration_seconds: int | None = None
    thumbnail_url: str | None = None
    options: list[MediaOption]
    warnings: list[str] = Field(default_factory=list)


class CreateJobRequest(BaseModel):
    media_id: str = Field(min_length=8, max_length=128)
    option_id: str = Field(min_length=3, max_length=256)


class JobState(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


class DownloadJob(BaseModel):
    id: str
    media_id: str
    option_id: str
    state: JobState
    progress: float = Field(default=0, ge=0, le=1)
    downloaded_bytes: int | None = None
    total_bytes: int | None = None
    speed_bytes_per_second: float | None = None
    eta_seconds: int | None = None
    filename: str | None = None
    error: str | None = None
    error_code: str | None = None
    created_at: float
    updated_at: float
    download_url: str | None = None


class HealthResponse(BaseModel):
    status: str
    extractor: str
    ffmpeg_available: bool
    instance_id: str
    authenticated: bool = False


class SniffRequest(BaseModel):
    url: str = Field(min_length=8, max_length=4096)


class SniffedResource(BaseModel):
    url: str
    kind: str
    extension: str | None = None
    source: str


class SniffResponse(BaseModel):
    page_url: str
    title: str | None = None
    resources: list[SniffedResource]
    warnings: list[str] = Field(default_factory=list)


class TransferRequest(BaseModel):
    source: str | None = Field(default=None, min_length=8, max_length=8192)
    sources: list[str] = Field(default_factory=list, max_length=8)


class MusicSearchResult(BaseModel):
    identifier: str
    title: str
    creator: str | None = None
    year: str | None = None
    item_url: str
    source: str = "internet_archive"
    source_label: str = "Internet Archive"
    can_download: bool = False
    preview_url: str | None = None
    artwork_url: str | None = None
    album: str | None = None
    duration_seconds: int | None = None
    license: str | None = None


class MusicFile(BaseModel):
    name: str
    format: str
    size: int | None = None
    bitrate: int | None = None
    sample_rate: int | None = None
    download_url: str


class MusicSourceStatus(BaseModel):
    source: str
    source_label: str
    available: bool
    result_count: int = 0
    detail: str | None = None
    checked_at: float


class UpdatePlatformRelease(BaseModel):
    url: str = ""
    sha256: str = ""
    size_bytes: int | None = None
    signing_certificate_sha256: str = ""


class UpdateManifest(BaseModel):
    version: str
    notes: str = ""
    published_at: str = ""
    platforms: dict[str, UpdatePlatformRelease]
