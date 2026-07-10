from __future__ import annotations

import asyncio
import contextlib
import json
import os
import re
import tempfile
import time
import uuid
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin, urlparse

import httpx
import yt_dlp
from bs4 import BeautifulSoup

from app.config import Settings
from app.models import AssetKind, MediaInfo, MediaOption
from app.services.security import validate_public_url


_ANSI_ESCAPE_RE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
_BROWSER_COOKIE_MARKERS = (
    "fresh cookies",
    "cookies are needed",
    "cookies are required",
)
_DOUYIN_HOSTS = {
    "douyin.com",
    "www.douyin.com",
    "v.douyin.com",
    "iesdouyin.com",
    "www.iesdouyin.com",
}
_DOUYIN_MOBILE_USER_AGENT = (
    "Mozilla/5.0 (Linux; Android 13; Pixel 7) "
    "AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36"
)
_HTTP_URL_RE = re.compile(r'''https?://[^\s<>"']+''', re.IGNORECASE)
_TRAILING_SHARE_PUNCTUATION = ")]}>，。！？；：、"
_BILIBILI_HOSTS = {"bilibili.com", "b23.tv"}
_BILIBILI_COOKIE_NAMES = {
    "SESSDATA",
    "bili_jct",
    "DedeUserID",
    "DedeUserID__ckMd5",
    "sid",
    "bili_ticket",
    "bili_ticket_expires",
}


def clean_ytdlp_error(value: object) -> str:
    """Return a short, display-safe yt-dlp error without terminal escapes."""
    message = _ANSI_ESCAPE_RE.sub("", str(value))
    message = re.sub(r"^(?:\s*ERROR:\s*)+", "", message, flags=re.IGNORECASE)
    return " ".join(message.split()).strip()


def browser_cookies_required(value: object) -> bool:
    message = clean_ytdlp_error(value).lower()
    return any(marker in message for marker in _BROWSER_COOKIE_MARKERS)


def extract_http_url(value: str) -> str | None:
    match = _HTTP_URL_RE.search(value.strip())
    return match.group(0).rstrip(_TRAILING_SHARE_PUNCTUATION) if match else None


def _is_bilibili_url(value: str) -> bool:
    hostname = (urlparse(value).hostname or "").lower()
    return hostname in _BILIBILI_HOSTS or hostname.endswith(".bilibili.com")


def _clean_bilibili_cookie(value: str | None, url: str) -> str | None:
    if not value or not _is_bilibili_url(url) or "\r" in value or "\n" in value:
        return None
    pairs: list[str] = []
    for item in value.split(";"):
        name, separator, content = item.strip().partition("=")
        if separator and name in _BILIBILI_COOKIE_NAMES and content:
            pairs.append(f"{name}={content}")
    return (
        "; ".join(pairs)
        if any(item.startswith("SESSDATA=") for item in pairs)
        else None
    )


@contextlib.contextmanager
def temporary_bilibili_cookie_file(cookie_header: str | None):
    if not cookie_header:
        yield None
        return
    descriptor, path = tempfile.mkstemp(prefix="langbai-bilibili-", suffix=".txt")
    os.close(descriptor)
    try:
        expires = int(time.time()) + 30 * 24 * 60 * 60
        lines = ["# Netscape HTTP Cookie File"]
        for item in cookie_header.split(";"):
            name, separator, value = item.strip().partition("=")
            if separator and name in _BILIBILI_COOKIE_NAMES:
                lines.append(
                    f".bilibili.com\tTRUE\t/\tTRUE\t{expires}\t{name}\t{value}"
                )
        with open(path, "w", encoding="utf-8", newline="\n") as output:
            output.write("\n".join(lines) + "\n")
        yield path
    finally:
        with contextlib.suppress(OSError):
            os.unlink(path)


@dataclass(slots=True)
class DownloadSpec:
    option: MediaOption
    selector: str | None = None
    direct_url: str | None = None
    preferred_codec: str | None = None
    preferred_quality: str | None = None
    cookie_header: str | None = None


@dataclass(slots=True)
class ResolvedEntry:
    media: MediaInfo
    specs: dict[str, DownloadSpec]
    created_at: float


def _human_bytes(value: int | None) -> str | None:
    if not value:
        return None
    size = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return None


def _as_int(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _as_float(value: Any) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


class ResolverService:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._cache: dict[str, ResolvedEntry] = {}

    async def resolve(
        self, raw_url: str, bilibili_cookie: str | None = None
    ) -> MediaInfo:
        candidate = extract_http_url(raw_url)
        if not candidate:
            raise ValueError("未在粘贴内容中找到 http 或 https 链接")
        url = await asyncio.to_thread(
            validate_public_url, candidate, self._settings.allow_fake_ip_dns
        )
        cookie_header = _clean_bilibili_cookie(bilibili_cookie, url)
        self._prune()
        direct_entry = self._resolve_direct_url(url)
        if direct_entry:
            self._cache[direct_entry.media.media_id] = direct_entry
            return direct_entry.media
        if self._is_douyin_url(url):
            try:
                entry = await asyncio.to_thread(self._resolve_douyin_share, url)
            except (httpx.HTTPError, KeyError, TypeError, ValueError) as error:
                raise yt_dlp.utils.DownloadError(
                    "抖音匿名分享页暂时没有返回可下载资源，请更新解析器或稍后重试"
                ) from error
            self._cache[entry.media.media_id] = entry
            return entry.media
        try:
            entry = await asyncio.to_thread(
                self._resolve_with_ytdlp, url, cookie_header
            )
        except yt_dlp.utils.DownloadError as error:
            if browser_cookies_required(error):
                raise yt_dlp.utils.DownloadError(
                    "该平台当前没有可用的匿名公开解析入口；langbai解析不会读取 Cookie"
                ) from error
            entry = await asyncio.to_thread(self._resolve_open_graph, url, str(error))
        self._cache[entry.media.media_id] = entry
        return entry.media

    @staticmethod
    def _is_douyin_url(url: str) -> bool:
        hostname = (urlparse(url).hostname or "").lower()
        return hostname in _DOUYIN_HOSTS or hostname.endswith(".douyin.com")

    @staticmethod
    def _douyin_video_id(value: str) -> str | None:
        match = re.search(r"/(?:video|note)/(\d{10,})", value)
        if match:
            return match.group(1)
        parsed = urlparse(value)
        for key in ("modal_id", "aweme_id", "item_id"):
            match = re.search(rf"(?:^|[?&]){key}=(\d{{10,}})", parsed.query)
            if match:
                return match.group(1)
        return None

    def _resolve_douyin_share(self, url: str) -> ResolvedEntry:
        video_id = self._douyin_video_id(url)
        if not video_id:
            current = url
            for _ in range(5):
                validate_public_url(current, self._settings.allow_fake_ip_dns)
                response = httpx.get(
                    current,
                    headers={"User-Agent": _DOUYIN_MOBILE_USER_AGENT},
                    timeout=20,
                    follow_redirects=False,
                )
                location = response.headers.get("location")
                if location and response.is_redirect:
                    current = urljoin(current, location)
                    hostname = (urlparse(current).hostname or "").lower()
                    if hostname not in _DOUYIN_HOSTS and not hostname.endswith(
                        ".douyin.com"
                    ):
                        raise ValueError("抖音短链接跳转到了未知站点")
                    video_id = self._douyin_video_id(current)
                    if video_id:
                        break
                    continue
                response.raise_for_status()
                video_id = self._douyin_video_id(str(response.url))
                if not video_id:
                    match = re.search(r"(?:video|note)[/\\\"]+(\d{10,})", response.text)
                    video_id = match.group(1) if match else None
                break
        if not video_id:
            raise ValueError("无法从抖音链接识别作品 ID")

        share_url = f"https://www.iesdouyin.com/share/video/{video_id}/"
        response = httpx.get(
            share_url,
            headers={"User-Agent": _DOUYIN_MOBILE_USER_AGENT},
            timeout=20,
            follow_redirects=False,
        )
        response.raise_for_status()
        soup = BeautifulSoup(response.text, "html.parser")
        router_script = next(
            (
                script
                for script in soup.find_all("script")
                if (script.string or script.get_text())
                .lstrip()
                .startswith("window._ROUTER_DATA =")
            ),
            None,
        )
        if not router_script:
            raise ValueError("匿名分享页没有内嵌作品数据")
        script_text = (router_script.string or router_script.get_text()).strip()
        router_data = json.loads(script_text.split("=", 1)[1].strip().rstrip(";"))
        loader_data = router_data.get("loaderData") or {}
        page_data = next(
            (
                value
                for value in loader_data.values()
                if isinstance(value, dict)
                and isinstance(value.get("videoInfoRes"), dict)
            ),
            None,
        )
        item_list = ((page_data or {}).get("videoInfoRes") or {}).get("item_list") or []
        item = next(
            (
                value
                for value in item_list
                if isinstance(value, dict) and str(value.get("aweme_id")) == video_id
            ),
            item_list[0] if item_list else None,
        )
        if not isinstance(item, dict):
            raise ValueError("匿名分享页没有返回作品详情")

        media_id = uuid.uuid4().hex
        specs: dict[str, DownloadSpec] = {}
        video = item.get("video") if isinstance(item.get("video"), dict) else {}
        play_urls = (video.get("play_addr") or {}).get("url_list") or []
        play_url = next(
            (str(value) for value in play_urls if str(value).startswith("http")), None
        )
        width = _as_int(video.get("width"))
        height = _as_int(video.get("height"))
        if play_url:
            ratio_match = re.search(r"(?:[?&])ratio=([^&]+)", play_url)
            resolution = (
                ratio_match.group(1)
                if ratio_match
                else f"{width}x{height}"
                if width and height
                else None
            )
            option = MediaOption(
                id="video:douyin-share",
                kind=AssetKind.VIDEO,
                label="抖音公开视频 · MP4",
                extension="mp4",
                resolution=resolution,
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=play_url)

        image_sources: list[tuple[str, str]] = []
        cover_urls = (video.get("cover") or {}).get("url_list") or []
        cover_url = next(
            (str(value) for value in cover_urls if str(value).startswith("http")), None
        )
        if cover_url:
            image_sources.append(("cover", cover_url))
        for index, image in enumerate(item.get("images") or [], start=1):
            if not isinstance(image, dict):
                continue
            urls = image.get("url_list") or image.get("download_url_list") or []
            image_url = next(
                (str(value) for value in urls if str(value).startswith("http")), None
            )
            if image_url:
                image_sources.append((str(index), image_url))
        for label, image_url in image_sources[:20]:
            extension = urlparse(image_url).path.rsplit(".", 1)[-1].lower()
            if extension not in {"jpg", "jpeg", "png", "webp", "avif"}:
                extension = "jpg"
            option = MediaOption(
                id=f"image:{label}",
                kind=AssetKind.IMAGE,
                label="最高质量封面" if label == "cover" else f"图片 {label}",
                extension=extension,
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=image_url)
        if not specs:
            raise ValueError("匿名分享页没有返回视频或图片地址")

        author = item.get("author") if isinstance(item.get("author"), dict) else {}
        title = str(item.get("desc") or "").strip() or f"抖音作品 {video_id}"
        media = MediaInfo(
            media_id=media_id,
            source_url=url,
            title=title,
            creator=str(author.get("nickname") or "").strip() or None,
            platform="Douyin",
            duration_seconds=(_as_int(video.get("duration")) or 0) // 1000 or None,
            thumbnail_url=cover_url,
            options=[spec.option for spec in specs.values()],
            warnings=["已通过抖音匿名分享页直接解析，全程不读取或发送 Cookie。"],
        )
        return ResolvedEntry(media=media, specs=specs, created_at=time.time())

    def _resolve_direct_url(self, url: str) -> ResolvedEntry | None:
        path = urlparse(url).path
        extension = path.rsplit(".", 1)[-1].lower() if "." in path else ""
        image_extensions = {"jpg", "jpeg", "png", "webp", "avif", "gif"}
        video_extensions = {"mp4", "webm", "mov", "m4v", "mkv", "avi"}
        audio_extensions = {"mp3", "m4a", "aac", "ogg", "opus", "wav", "flac"}
        if extension in image_extensions:
            kind = AssetKind.IMAGE
            label = f"原始图片 · {extension.upper()}"
        elif extension in video_extensions:
            kind = AssetKind.VIDEO
            label = f"原始视频 · {extension.upper()}"
        elif extension in audio_extensions:
            kind = AssetKind.AUDIO
            label = f"原始音频 · {extension.upper()}"
        else:
            return None

        media_id = uuid.uuid4().hex
        option = MediaOption(
            id=f"{kind.value}:direct",
            kind=kind,
            label=label,
            extension=extension,
        )
        title = path.rsplit("/", 1)[-1].rsplit(".", 1)[0] or "直接媒体"
        spec = DownloadSpec(option=option, direct_url=url)
        media = MediaInfo(
            media_id=media_id,
            source_url=url,
            title=title,
            platform=urlparse(url).hostname or "直接链接",
            thumbnail_url=url if kind == AssetKind.IMAGE else None,
            options=[option],
        )
        return ResolvedEntry(
            media=media,
            specs={option.id: spec},
            created_at=time.time(),
        )

    def get(self, media_id: str) -> ResolvedEntry | None:
        self._prune()
        return self._cache.get(media_id)

    def _base_ytdlp_options(self, cookie_file: str | None = None) -> dict[str, Any]:
        options: dict[str, Any] = {
            "quiet": True,
            "no_warnings": True,
            "noplaylist": True,
            "skip_download": True,
            "socket_timeout": 20,
            "retries": 2,
            "extractor_retries": 2,
            "http_headers": {
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
                )
            },
        }
        if cookie_file:
            options["cookiefile"] = cookie_file
        return options

    def _resolve_with_ytdlp(
        self, url: str, cookie_header: str | None = None
    ) -> ResolvedEntry:
        with temporary_bilibili_cookie_file(cookie_header) as cookie_file:
            with yt_dlp.YoutubeDL(self._base_ytdlp_options(cookie_file)) as ydl:
                raw_info = ydl.extract_info(url, download=False)

        if not raw_info:
            raise yt_dlp.utils.DownloadError("解析器未返回媒体信息")

        warnings: list[str] = []
        info = raw_info
        entries = raw_info.get("entries") if isinstance(raw_info, dict) else None
        collection_entries = [item for item in entries or [] if item]
        if entries:
            first = next((item for item in collection_entries if item), None)
            if not first:
                raise yt_dlp.utils.DownloadError("合集内没有可解析项目")
            info = first
            warnings.append("检测到合集链接，当前任务只处理第一项。")

        formats = list(info.get("formats") or [])
        if not formats and not info.get("url"):
            raise yt_dlp.utils.DownloadError("没有找到可下载的视频或音频格式")

        media_id = uuid.uuid4().hex
        specs: dict[str, DownloadSpec] = {}
        video_candidates: dict[tuple[Any, ...], dict[str, Any]] = {}

        for item in formats:
            if not item.get("format_id") or item.get("vcodec") in {None, "none"}:
                continue
            height = _as_int(item.get("height"))
            width = _as_int(item.get("width"))
            fps = _as_float(item.get("fps"))
            extension = str(item.get("ext") or "mp4").lower()
            has_audio = item.get("acodec") not in {None, "none"}
            dynamic_range = str(item.get("dynamic_range") or "SDR")
            key = (height, width, round(fps or 0), extension, has_audio, dynamic_range)
            score = (
                _as_int(item.get("filesize") or item.get("filesize_approx")) or 0,
                _as_float(item.get("tbr")) or 0,
            )
            current = video_candidates.get(key)
            current_score = (
                (
                    _as_int(current.get("filesize") or current.get("filesize_approx"))
                    or 0,
                    _as_float(current.get("tbr")) or 0,
                )
                if current
                else (-1, -1)
            )
            if score >= current_score:
                video_candidates[key] = item

        sorted_videos = sorted(
            video_candidates.values(),
            key=lambda item: (
                _as_int(item.get("height")) or 0,
                _as_float(item.get("fps")) or 0,
                _as_float(item.get("tbr")) or 0,
            ),
            reverse=True,
        )[:30]

        for item in sorted_videos:
            format_id = str(item["format_id"])
            height = _as_int(item.get("height"))
            width = _as_int(item.get("width"))
            fps = _as_float(item.get("fps"))
            extension = str(item.get("ext") or "mp4").lower()
            has_audio = item.get("acodec") not in {None, "none"}
            size = _as_int(item.get("filesize") or item.get("filesize_approx"))
            resolution = (
                f"{width}×{height}"
                if width and height
                else f"{height}p"
                if height
                else None
            )
            label_parts = [
                f"{height}p" if height else str(item.get("format_note") or "视频")
            ]
            if fps and fps > 30:
                label_parts.append(f"{fps:g}fps")
            if str(item.get("dynamic_range") or "SDR") != "SDR":
                label_parts.append(str(item["dynamic_range"]))
            label_parts.append(extension.upper())
            label_parts.append("音画合一" if has_audio else "自动合并音频")
            option = MediaOption(
                id=f"video:{format_id}",
                kind=AssetKind.VIDEO,
                label=" · ".join(label_parts),
                extension=extension,
                resolution=resolution,
                fps=fps,
                filesize=size,
                filesize_label=_human_bytes(size),
                requires_merge=not has_audio,
            )
            if has_audio:
                selector = format_id
            elif extension in {"mp4", "m4v", "mov"}:
                selector = f"{format_id}+bestaudio[ext=m4a]/{format_id}+bestaudio/best"
            else:
                selector = f"{format_id}+bestaudio/best"
            specs[option.id] = DownloadSpec(option=option, selector=selector)

        direct_url = info.get("url") if not formats else None
        direct_extension = str(info.get("ext") or "").lower()
        image_extensions = {"jpg", "jpeg", "png", "webp", "avif", "gif"}
        if direct_url and direct_extension in image_extensions:
            option = MediaOption(
                id="image:source",
                kind=AssetKind.IMAGE,
                label=f"原始图片 · {direct_extension.upper()}",
                extension=direct_extension,
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=str(direct_url))
        elif direct_url and not sorted_videos:
            extension = direct_extension or "mp4"
            option = MediaOption(
                id="video:direct",
                kind=AssetKind.VIDEO,
                label=f"网页原始视频 · {extension.upper()}",
                extension=extension,
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=str(direct_url))

        for index, item in enumerate(collection_entries, start=1):
            item_url = item.get("url")
            item_extension = str(item.get("ext") or "").lower()
            if not item_url or item_extension not in image_extensions:
                continue
            option_id = f"image:collection:{index}"
            if option_id in specs:
                continue
            option = MediaOption(
                id=option_id,
                kind=AssetKind.IMAGE,
                label=f"图集图片 {index} · {item_extension.upper()}",
                extension=item_extension,
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=str(item_url))

        has_audio = any(
            item.get("acodec") not in {None, "none"} for item in formats
        ) or (
            bool(direct_url)
            and direct_extension not in image_extensions
            and info.get("acodec") != "none"
        )
        if has_audio:
            audio_presets = (
                ("audio:best", "最佳原始音频", "m4a", None, None),
                ("audio:mp3:320", "MP3 · 320 kbps", "mp3", "mp3", "320"),
                ("audio:mp3:192", "MP3 · 192 kbps", "mp3", "mp3", "192"),
                ("audio:m4a:256", "M4A · 256 kbps", "m4a", "m4a", "256"),
            )
            for option_id, label, extension, codec, quality in audio_presets:
                bitrate = _as_int(quality)
                option = MediaOption(
                    id=option_id,
                    kind=AssetKind.AUDIO,
                    label=label,
                    extension=extension,
                    bitrate_kbps=bitrate,
                )
                specs[option.id] = DownloadSpec(
                    option=option,
                    selector="bestaudio/best",
                    preferred_codec=codec,
                    preferred_quality=quality,
                )

        thumbnail = info.get("thumbnail")
        if not thumbnail:
            thumbnail_items = [
                item for item in info.get("thumbnails") or [] if item.get("url")
            ]
            if thumbnail_items:
                thumbnail = thumbnail_items[-1]["url"]
        if thumbnail:
            extension = str(thumbnail).split("?", 1)[0].rsplit(".", 1)[-1].lower()
            if extension not in {"jpg", "jpeg", "png", "webp", "avif"}:
                extension = "jpg"
            cover = MediaOption(
                id="image:cover",
                kind=AssetKind.IMAGE,
                label=f"最高质量封面 · {extension.upper()}",
                extension=extension,
            )
            specs[cover.id] = DownloadSpec(option=cover, direct_url=str(thumbnail))

        if not specs:
            raise yt_dlp.utils.DownloadError("没有找到可下载资源")

        if cookie_header:
            for spec in specs.values():
                spec.cookie_header = cookie_header
            warnings.insert(0, "已使用本机B站登录会话请求账号可见的最高画质。")

        media = MediaInfo(
            media_id=media_id,
            source_url=str(info.get("webpage_url") or url),
            title=str(info.get("title") or "未命名媒体"),
            creator=info.get("uploader") or info.get("creator") or info.get("channel"),
            platform=str(
                info.get("extractor_key") or info.get("extractor") or "通用解析"
            ),
            duration_seconds=_as_int(info.get("duration")),
            thumbnail_url=str(thumbnail) if thumbnail else None,
            options=[spec.option for spec in specs.values()],
            warnings=warnings,
        )
        return ResolvedEntry(media=media, specs=specs, created_at=time.time())

    def _resolve_open_graph(self, url: str, extractor_error: str) -> ResolvedEntry:
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            )
        }
        with httpx.Client(headers=headers, timeout=20, follow_redirects=True) as client:
            response = client.get(url)
            response.raise_for_status()
        soup = BeautifulSoup(response.text, "html.parser")

        def meta_value(*keys: str) -> str | None:
            for key in keys:
                tag = soup.find("meta", attrs={"property": key}) or soup.find(
                    "meta", attrs={"name": key}
                )
                if tag and tag.get("content"):
                    return str(tag["content"])
            return None

        title = meta_value("og:title", "twitter:title")
        if not title and soup.title and soup.title.string:
            title = soup.title.string.strip()
        platform = meta_value("og:site_name") or response.url.host or "通用网页"
        image_urls: list[str] = []
        for tag in soup.find_all("meta"):
            key = tag.get("property") or tag.get("name")
            if key in {"og:image", "og:image:url", "twitter:image"} and tag.get(
                "content"
            ):
                candidate = urljoin(str(response.url), str(tag["content"]))
                if candidate not in image_urls:
                    image_urls.append(candidate)
        video_url = meta_value("og:video", "og:video:url", "twitter:player:stream")
        if video_url:
            video_url = urljoin(str(response.url), video_url)

        media_id = uuid.uuid4().hex
        specs: dict[str, DownloadSpec] = {}
        if video_url:
            extension = video_url.split("?", 1)[0].rsplit(".", 1)[-1].lower()
            if extension not in {"mp4", "webm", "mov", "m4v"}:
                extension = "mp4"
            option = MediaOption(
                id="video:direct",
                kind=AssetKind.VIDEO,
                label=f"网页原始视频 · {extension.upper()}",
                extension=extension,
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=video_url)
        for index, image_url in enumerate(image_urls[:20], start=1):
            extension = image_url.split("?", 1)[0].rsplit(".", 1)[-1].lower()
            if extension not in {"jpg", "jpeg", "png", "webp", "avif"}:
                extension = "jpg"
            option = MediaOption(
                id=f"image:{index}",
                kind=AssetKind.IMAGE,
                label=f"图片 {index} · {extension.upper()}",
                extension=extension,
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=image_url)

        if not specs:
            message = clean_ytdlp_error(extractor_error)
            raise yt_dlp.utils.DownloadError(
                f"该页面暂未发现公开媒体资源：{message[:240]}"
            )

        media = MediaInfo(
            media_id=media_id,
            source_url=str(response.url),
            title=title or "未命名网页媒体",
            platform=platform,
            thumbnail_url=image_urls[0] if image_urls else None,
            options=[spec.option for spec in specs.values()],
            warnings=["站点专用解析器不可用，已使用通用网页媒体解析。"],
        )
        return ResolvedEntry(media=media, specs=specs, created_at=time.time())

    def _prune(self) -> None:
        cutoff = time.time() - self._settings.cache_ttl_seconds
        expired = [
            key for key, value in self._cache.items() if value.created_at < cutoff
        ]
        for key in expired:
            self._cache.pop(key, None)
