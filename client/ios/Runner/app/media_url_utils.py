from __future__ import annotations

import re


_DOUYIN_WATERMARK_PATH = re.compile(r"/aweme/v1/playwm(?=/|\?|$)")


def normalize_douyin_play_url(value: str) -> str:
    """Return the public play endpoint while preserving the signed query."""
    return _DOUYIN_WATERMARK_PATH.sub("/aweme/v1/play", value, count=1)


def should_expose_douyin_video(play_url: str | None, image_count: int) -> bool:
    """A Douyin note can contain a placeholder play_addr; never show it as a video."""
    return bool(play_url) and image_count == 0


def is_obvious_text_media_error(
    content_type: str | None, first_chunk: bytes
) -> bool:
    """Reject successful HTTP responses that are actually text error payloads."""
    media_type = (content_type or "").partition(";")[0].strip().lower()
    textual = (
        media_type.startswith("text/")
        or media_type == "application/json"
        or media_type.endswith("+json")
        or media_type == "application/xml"
        or media_type.endswith("+xml")
        or media_type
        in {"application/vnd.apple.mpegurl", "application/x-mpegurl"}
    )
    if textual:
        return True
    if not first_chunk:
        return False
    prefix = first_chunk[:8192].decode("utf-8", "replace").lstrip("\ufeff \t\r\n").lower()
    return prefix.startswith(
        ("<!doctype html", "<html", "<?xml", "{", "[", "#extm3u")
    )
