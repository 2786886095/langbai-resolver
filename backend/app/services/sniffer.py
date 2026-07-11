from __future__ import annotations

import html
import re
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

from app.config import Settings
from app.models import SniffResponse, SniffedResource
from app.services.security import (
    UnsafeUrlError,
    read_limited,
    stream_public_response,
    validate_public_url,
)


class SnifferService:
    _media_pattern = re.compile(
        r"https?:(?:\\?/){2}[^\s\"'<>]+?\.(?:m3u8|mpd|mp4|webm|mkv|mov|m4a|mp3|flac|wav|jpg|jpeg|png|webp)(?:\?[^\s\"'<>]*)?",
        re.IGNORECASE,
    )

    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def sniff(self, raw_url: str) -> SniffResponse:
        url = validate_public_url(raw_url, self._settings.allow_fake_ip_dns)
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            )
        }
        with httpx.Client(
            headers=headers, follow_redirects=False, timeout=25, trust_env=False
        ) as client:
            with stream_public_response(
                client,
                "GET",
                url,
                allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
                max_redirects=self._settings.max_redirects,
            ) as response:
                response.raise_for_status()
                page_url = str(response.url)
                encoding = response.encoding or "utf-8"
                page_text = read_limited(
                    response, self._settings.max_html_bytes
                ).decode(encoding, errors="replace")

        soup = BeautifulSoup(page_text, "html.parser")
        title = soup.title.string.strip() if soup.title and soup.title.string else None
        found: dict[str, SniffedResource] = {}

        def add(candidate: str, source: str) -> None:
            candidate = html.unescape(candidate).replace("\\/", "/")
            absolute = urljoin(page_url, candidate)
            if not absolute.startswith(("http://", "https://")):
                return
            try:
                validate_public_url(absolute, self._settings.allow_fake_ip_dns)
            except UnsafeUrlError:
                return
            clean_path = absolute.split("?", 1)[0]
            extension = (
                clean_path.rsplit(".", 1)[-1].lower() if "." in clean_path else None
            )
            kind = (
                "stream"
                if extension in {"m3u8", "mpd"}
                else (
                    "audio"
                    if extension in {"m4a", "mp3", "flac", "wav"}
                    else (
                        "image"
                        if extension in {"jpg", "jpeg", "png", "webp"}
                        else "video"
                    )
                )
            )
            found.setdefault(
                absolute,
                SniffedResource(
                    url=absolute,
                    kind=kind,
                    extension=extension,
                    source=source,
                ),
            )

        for tag in soup.find_all(["video", "audio", "source", "img"]):
            candidate = tag.get("src") or tag.get("data-src")
            if candidate:
                add(str(candidate), "html")
        for tag in soup.find_all("meta"):
            key = tag.get("property") or tag.get("name")
            if key in {
                "og:video",
                "og:video:url",
                "og:audio",
                "og:image",
                "twitter:player:stream",
                "twitter:image",
            } and tag.get("content"):
                add(str(tag["content"]), "metadata")
        for match in self._media_pattern.findall(page_text):
            add(match, "script")

        warnings: list[str] = []
        if not found:
            warnings.append(
                "静态页面中未发现媒体请求；动态加密播放器可能需要站点专用解析器。"
            )
        return SniffResponse(
            page_url=page_url,
            title=title,
            resources=list(found.values())[:100],
            warnings=warnings,
        )
