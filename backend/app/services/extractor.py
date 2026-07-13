from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import os
import re
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from threading import RLock
from typing import Any
from urllib.parse import parse_qs, urlencode, urljoin, urlparse

import httpx
import yt_dlp
from bs4 import BeautifulSoup

from app.config import Settings
from app.models import AssetKind, MediaInfo, MediaOption
from app.services.security import (
    guarded_dns_resolution,
    read_limited,
    stream_public_response,
    validate_public_url,
)


_ANSI_ESCAPE_RE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
_BROWSER_COOKIE_MARKERS = (
    "fresh cookies",
    "cookies are needed",
    "cookies are required",
    "cookies (not necessarily logged in) are needed",
    "sign in to confirm you're not a bot",
    "sign in to confirm you’re not a bot",
    "use --cookies-from-browser or --cookies",
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
_DOUYIN_PLAY_HOSTS = {"aweme.snssdk.com"}
_DOUYIN_PLAYWM_PATH = "/aweme/v1/playwm/"
_DOUYIN_PLAY_PATH = "/aweme/v1/play/"
_DOUYIN_VIDEO_TOKEN_RE = re.compile(r"^[A-Za-z0-9._~-]{8,256}$")
_KUAISHOU_HOSTS = {
    "kuaishou.com",
    "chenzhongtech.com",
    "gifshow.com",
}
_KUAISHOU_MOBILE_USER_AGENT = (
    "Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Mobile Safari/537.36"
)
_HTTP_URL_RE = re.compile(r"""https?://[^\s<>"']+""", re.IGNORECASE)
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


class SafeYoutubeDL(yt_dlp.YoutubeDL):
    """Validate every extractor request and its final redirect target."""

    def __init__(
        self, *args: Any, allow_fake_ip_dns: bool = False, **kwargs: Any
    ) -> None:
        self._allow_fake_ip_dns = allow_fake_ip_dns
        super().__init__(*args, **kwargs)

    def urlopen(self, request: Any):  # yt-dlp owns the concrete request type.
        url = request if isinstance(request, str) else request.url
        validate_public_url(str(url), self._allow_fake_ip_dns)
        with guarded_dns_resolution(self._allow_fake_ip_dns):
            response = super().urlopen(request)
        final_url = getattr(response, "url", None)
        if final_url:
            validate_public_url(str(final_url), self._allow_fake_ip_dns)
        return response


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
    fallback_urls: tuple[str, ...] = ()
    preferred_codec: str | None = None
    preferred_quality: str | None = None
    cookie_header: str | None = None
    headers: dict[str, str] | None = None


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


def _select_douyin_play_urls(play_addr: object) -> tuple[str | None, tuple[str, ...]]:
    """Prefer Douyin's public clean endpoint and retain explicit compatibility URLs."""
    if not isinstance(play_addr, dict):
        return None, ()
    raw_urls = play_addr.get("url_list")
    if not isinstance(raw_urls, list):
        raw_urls = []
    urls = list(
        dict.fromkeys(
            str(value)
            for value in raw_urls
            if str(value).startswith(("http://", "https://"))
        )
    )
    if not urls:
        return None, ()

    watermark_urls: list[str] = []
    for candidate in urls:
        parsed = urlparse(candidate)
        if parsed.path.rstrip("/") != _DOUYIN_PLAYWM_PATH.rstrip("/"):
            return candidate, tuple(url for url in urls if url != candidate)
        watermark_urls.append(candidate)

    fallback_token = str(play_addr.get("uri") or "").strip()
    for candidate in watermark_urls:
        parsed = urlparse(candidate)
        if (
            parsed.scheme not in {"http", "https"}
            or (parsed.hostname or "").lower() not in _DOUYIN_PLAY_HOSTS
        ):
            continue
        query = parse_qs(parsed.query)
        video_token = str((query.get("video_id") or [fallback_token])[0]).strip()
        if not _DOUYIN_VIDEO_TOKEN_RE.fullmatch(video_token):
            continue
        ratio = str((query.get("ratio") or ["720p"])[0]).strip()
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,32}", ratio):
            ratio = "720p"
        clean_query = {"video_id": video_token, "ratio": ratio}
        line = str((query.get("line") or [""])[0]).strip()
        if re.fullmatch(r"\d{1,3}", line):
            clean_query["line"] = line
        clean_url = (
            f"https://aweme.snssdk.com{_DOUYIN_PLAY_PATH}?{urlencode(clean_query)}"
        )
        return clean_url, tuple(watermark_urls)
    return watermark_urls[0], tuple(watermark_urls[1:])


def _as_float(value: Any) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _format_has_video(item: dict[str, Any]) -> bool:
    """Treat missing codec metadata as unknown, not as an explicit audio-only flag."""
    codec = str(item.get("vcodec") or "").strip().lower()
    if codec == "none":
        return False
    if codec:
        return True
    if _as_int(item.get("width")) or _as_int(item.get("height")):
        return True
    video_extension = str(item.get("video_ext") or "").strip().lower()
    if video_extension and video_extension != "none":
        return True
    resolution = str(item.get("resolution") or "").strip().lower()
    return bool(resolution and resolution not in {"audio only", "unknown"})


def _format_audio_state(item: dict[str, Any]) -> bool | None:
    """Return explicit audio presence while preserving missing codec as unknown."""
    codec = str(item.get("acodec") or "").strip().lower()
    if codec == "none":
        return False
    if codec:
        return True
    return None


def _direct_headers(
    raw_headers: object,
    media_url: str,
    source_url: str,
    bilibili_cookie: str | None = None,
) -> dict[str, str] | None:
    if not isinstance(raw_headers, dict):
        raw_headers = {}
    target_host = (urlparse(media_url).hostname or "").lower()
    source_host = (urlparse(source_url).hostname or "").lower()
    allowed = {"user-agent", "accept", "accept-language", "referer", "origin"}
    result = {
        str(key): str(value)
        for key, value in raw_headers.items()
        if str(key).lower() in allowed
        and "\r" not in str(value)
        and "\n" not in str(value)
    }
    if target_host == source_host:
        for key, value in raw_headers.items():
            if (
                str(key).lower() == "authorization"
                and "\r" not in str(value)
                and "\n" not in str(value)
            ):
                result[str(key)] = str(value)
    if bilibili_cookie and (
        target_host == "bilibili.com" or target_host.endswith(".bilibili.com")
    ):
        result["Cookie"] = bilibili_cookie
    return result or None


class ResolverService:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._cache: dict[str, ResolvedEntry] = {}
        self._source_cache: dict[str, str] = {}
        self._cache_lock = RLock()
        self._executor = ThreadPoolExecutor(
            max_workers=max(2, settings.max_concurrent_jobs * 2),
            thread_name_prefix="langbai-resolver",
        )

    async def _blocking(self, function, *args):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._executor, lambda: function(*args))

    def shutdown(self) -> None:
        self._executor.shutdown(wait=False, cancel_futures=True)

    async def resolve(
        self, raw_url: str, bilibili_cookie: str | None = None
    ) -> MediaInfo:
        candidate = extract_http_url(raw_url)
        if not candidate:
            raise ValueError("未在粘贴内容中找到 http 或 https 链接")
        url = await self._blocking(
            validate_public_url, candidate, self._settings.allow_fake_ip_dns
        )
        cookie_header = _clean_bilibili_cookie(bilibili_cookie, url)
        self._prune()
        source_cache_key = self._source_cache_key(url, cookie_header)
        cached_entry = self._get_by_source(source_cache_key)
        if cached_entry:
            return cached_entry.media
        direct_entry = self._resolve_direct_url(url)
        if direct_entry:
            self._store(direct_entry, source_cache_key)
            return direct_entry.media
        fallback_warnings: list[str] = []
        if self._is_kuaishou_url(url):
            try:
                entry = await self._blocking(self._resolve_kuaishou_share, url)
            except (
                httpx.HTTPError,
                json.JSONDecodeError,
                KeyError,
                TypeError,
                ValueError,
            ):
                fallback_warnings.append("快手专用解析器暂不可用，已尝试通用解析。")
            else:
                self._store(entry, source_cache_key)
                return entry.media
        if self._is_douyin_url(url):
            try:
                entry = await self._blocking(self._resolve_douyin_share, url)
            except (httpx.HTTPError, KeyError, TypeError, ValueError):
                fallback_warnings.append("抖音专用解析器暂不可用，已尝试通用解析。")
            else:
                self._store(entry, source_cache_key)
                return entry.media
        try:
            entry = await self._blocking(self._resolve_with_ytdlp, url, cookie_header)
        except yt_dlp.utils.DownloadError as error:
            try:
                entry = await self._blocking(self._resolve_open_graph, url, str(error))
            except yt_dlp.utils.DownloadError:
                if browser_cookies_required(error):
                    raise yt_dlp.utils.DownloadError(
                        "该平台当前没有可用的匿名公开解析入口；langbai解析不会读取登录 Cookie"
                    ) from error
                raise
        entry.media.warnings[:0] = fallback_warnings
        self._store(entry, source_cache_key)
        return entry.media

    @staticmethod
    def _source_cache_key(url: str, cookie_header: str | None) -> str:
        cookie_scope = (
            hashlib.sha256(cookie_header.encode("utf-8")).hexdigest()
            if cookie_header
            else "anonymous"
        )
        return f"{url}\n{cookie_scope}"

    @staticmethod
    def _is_douyin_url(url: str) -> bool:
        hostname = (urlparse(url).hostname or "").lower()
        return hostname in _DOUYIN_HOSTS or hostname.endswith(".douyin.com")

    @staticmethod
    def _is_kuaishou_url(url: str) -> bool:
        hostname = (urlparse(url).hostname or "").lower()
        return any(
            hostname == domain or hostname.endswith(f".{domain}")
            for domain in _KUAISHOU_HOSTS
        )

    @staticmethod
    def _first_kuaishou_url(value: object) -> str | None:
        if not isinstance(value, list):
            return None
        for item in value:
            candidate = item.get("url") if isinstance(item, dict) else item
            if str(candidate).startswith(("http://", "https://")):
                return str(candidate)
        return None

    def _fetch_kuaishou_page(self, url: str) -> tuple[str, str]:
        def validate_kuaishou_redirect(candidate: str) -> None:
            if not self._is_kuaishou_url(candidate):
                raise ValueError("快手短链接跳转到了未知站点")

        with httpx.Client(
            headers={
                "User-Agent": _KUAISHOU_MOBILE_USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9",
                "Referer": "https://v.kuaishou.com/",
            },
            timeout=25,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            with stream_public_response(
                client,
                "GET",
                url,
                allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
                max_redirects=min(8, self._settings.max_redirects),
                redirect_validator=validate_kuaishou_redirect,
            ) as response:
                response.raise_for_status()
                encoding = response.encoding or "utf-8"
                body = read_limited(response, self._settings.max_html_bytes)
                return str(response.url), body.decode(encoding, errors="replace")

    def _resolve_kuaishou_share(self, url: str) -> ResolvedEntry:
        _, html = self._fetch_kuaishou_page(url)

        soup = BeautifulSoup(html, "html.parser")
        state_script = next(
            (
                script
                for script in soup.find_all("script")
                if (script.string or script.get_text())
                .lstrip()
                .startswith("window.INIT_STATE =")
            ),
            None,
        )
        if not state_script:
            raise ValueError("快手匿名分享页没有内嵌作品数据")
        script_text = (state_script.string or state_script.get_text()).strip()
        state = json.loads(script_text.split("=", 1)[1].strip().rstrip(";"))
        photo = next(
            (
                value.get("photo")
                for value in state.values()
                if isinstance(value, dict) and isinstance(value.get("photo"), dict)
            ),
            None,
        )
        if not isinstance(photo, dict):
            raise ValueError("快手匿名分享页没有返回作品详情")

        media_id = uuid.uuid4().hex
        specs: dict[str, DownloadSpec] = {}
        options: list[MediaOption] = []
        width = _as_int(photo.get("width"))
        height = _as_int(photo.get("height"))
        play_url = self._first_kuaishou_url(photo.get("mainMvUrls"))
        if play_url:
            option = MediaOption(
                id="video:kuaishou-share",
                kind=AssetKind.VIDEO,
                label="快手公开视频 · MP4",
                extension="mp4",
                resolution=(f"{width}x{height}" if width and height else None),
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=play_url)
            options.append(option)

        image_sources: list[tuple[str, str]] = []
        cover_url = self._first_kuaishou_url(photo.get("coverUrls"))
        if cover_url:
            image_sources.append(("cover", cover_url))
        for key in ("imageUrls", "images"):
            values = photo.get(key)
            if not isinstance(values, list):
                continue
            for item in values:
                image_url = self._first_kuaishou_url(
                    item.get("urls") if isinstance(item, dict) else [item]
                )
                if not image_url and isinstance(item, dict):
                    image_url = self._first_kuaishou_url([item])
                if image_url:
                    image_sources.append((str(len(image_sources) + 1), image_url))
        seen_images: set[str] = set()
        for label, image_url in image_sources:
            if image_url in seen_images or len(seen_images) >= 40:
                continue
            seen_images.add(image_url)
            extension = urlparse(image_url).path.rsplit(".", 1)[-1].lower()
            if extension not in {"jpg", "jpeg", "png", "webp", "avif"}:
                extension = "jpg"
            option = MediaOption(
                id=f"image:{label}",
                kind=AssetKind.IMAGE,
                label="最高质量封面" if label == "cover" else f"图片 {label}",
                extension=extension,
                preview_url=image_url,
            )
            specs[option.id] = DownloadSpec(option=option, direct_url=image_url)
            options.append(option)
        if not options:
            raise ValueError("快手匿名分享页没有返回视频或图片地址")

        photo_id = str(photo.get("photoId") or "").strip()
        title = str(photo.get("caption") or "").strip() or (
            f"快手作品 {photo_id}" if photo_id else "快手作品"
        )
        duration_ms = _as_int(photo.get("duration")) or _as_int(
            (photo.get("ext_params") or {}).get("sound")
            if isinstance(photo.get("ext_params"), dict)
            else None
        )
        media = MediaInfo(
            media_id=media_id,
            source_url=url,
            title=title,
            creator=str(photo.get("userName") or "").strip() or None,
            platform="Kuaishou",
            duration_seconds=(duration_ms // 1000 if duration_ms else None),
            thumbnail_url=cover_url,
            options=options,
            warnings=[
                "不读取或上传你的登录 Cookie；匿名分享页可能使用站点临时 Cookie。"
            ],
        )
        return ResolvedEntry(media=media, specs=specs, created_at=time.time())

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

    @staticmethod
    def _douyin_content_kind(value: str) -> str:
        return "note" if re.search(r"/note/\d{10,}", value) else "video"

    def _fetch_douyin_page(self, url: str) -> tuple[str, str]:
        def validate_douyin_redirect(candidate: str) -> None:
            hostname = (urlparse(candidate).hostname or "").lower()
            if hostname not in _DOUYIN_HOSTS and not hostname.endswith(".douyin.com"):
                raise ValueError("抖音短链接跳转到了未知站点")

        with httpx.Client(
            headers={"User-Agent": _DOUYIN_MOBILE_USER_AGENT},
            timeout=20,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            with stream_public_response(
                client,
                "GET",
                url,
                allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
                max_redirects=self._settings.max_redirects,
                redirect_validator=validate_douyin_redirect,
            ) as response:
                response.raise_for_status()
                encoding = response.encoding or "utf-8"
                body = read_limited(response, self._settings.max_html_bytes)
                return str(response.url), body.decode(encoding, errors="replace")

    def _resolve_douyin_share(self, url: str) -> ResolvedEntry:
        video_id = self._douyin_video_id(url)
        content_kind = self._douyin_content_kind(url)
        if not video_id:
            final_url, landing_html = self._fetch_douyin_page(url)
            video_id = self._douyin_video_id(final_url)
            content_kind = self._douyin_content_kind(final_url)
            if not video_id:
                match = re.search(r"(?:video|note)[/\\\"]+(\d{10,})", landing_html)
                video_id = match.group(1) if match else None
                if match:
                    content_kind = "note" if "note" in match.group(0) else "video"
        if not video_id:
            raise ValueError("无法从抖音链接识别作品 ID")

        share_url = f"https://www.iesdouyin.com/share/{content_kind}/{video_id}/"
        _, share_html = self._fetch_douyin_page(share_url)
        soup = BeautifulSoup(share_html, "html.parser")
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
        play_url, fallback_play_urls = _select_douyin_play_urls(video.get("play_addr"))
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
                label=(
                    "抖音公开视频 · 无平台水印优先（失败时使用原站兼容源）"
                    if fallback_play_urls
                    else "抖音公开视频 · MP4"
                ),
                extension="mp4",
                resolution=resolution,
            )
            specs[option.id] = DownloadSpec(
                option=option,
                direct_url=play_url,
                fallback_urls=fallback_play_urls,
            )

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
                preview_url=image_url,
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
            warnings=[
                "不读取或上传你的登录 Cookie；匿名分享页可能使用站点临时 Cookie。"
            ],
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
            preview_url=url if kind == AssetKind.IMAGE else None,
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
        with self._cache_lock:
            return self._cache.get(media_id)

    def _get_by_source(self, source_cache_key: str) -> ResolvedEntry | None:
        with self._cache_lock:
            media_id = self._source_cache.get(source_cache_key)
            if not media_id:
                return None
            entry = self._cache.get(media_id)
            if entry is None:
                self._source_cache.pop(source_cache_key, None)
            return entry

    def _store(self, entry: ResolvedEntry, source_cache_key: str | None = None) -> None:
        with self._cache_lock:
            if len(self._cache) >= 128:
                oldest = min(self._cache, key=lambda key: self._cache[key].created_at)
                self._cache.pop(oldest, None)
                self._source_cache = {
                    key: value
                    for key, value in self._source_cache.items()
                    if value != oldest
                }
            self._cache[entry.media.media_id] = entry
            if source_cache_key:
                self._source_cache[source_cache_key] = entry.media.media_id

    def _base_ytdlp_options(self, cookie_file: str | None = None) -> dict[str, Any]:
        options: dict[str, Any] = {
            "quiet": True,
            "no_warnings": True,
            "noplaylist": True,
            "skip_download": True,
            "socket_timeout": 20,
            "retries": 1,
            "extractor_retries": 1,
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
            with SafeYoutubeDL(
                self._base_ytdlp_options(cookie_file),
                allow_fake_ip_dns=self._settings.allow_fake_ip_dns,
            ) as ydl:
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
        audio_formats = [
            item
            for item in formats
            if _format_audio_state(item) is True and not _format_has_video(item)
        ]
        has_separate_audio = bool(audio_formats)

        def format_has_audio(item: dict[str, Any]) -> bool:
            state = _format_audio_state(item)
            if state is not None:
                return state
            # Some extractors omit both codec fields for a muxed public MP4/HLS.
            # If they also expose a dedicated audio-only stream, keep unknown
            # video formats mergeable instead of silently producing no audio.
            return _format_has_video(item) and not has_separate_audio

        for item in formats:
            if not item.get("format_id") or not _format_has_video(item):
                continue
            height = _as_int(item.get("height"))
            width = _as_int(item.get("width"))
            fps = _as_float(item.get("fps"))
            extension = str(item.get("ext") or "mp4").lower()
            video_codec = str(item.get("vcodec") or "unknown").lower()
            has_audio = format_has_audio(item)
            dynamic_range = str(item.get("dynamic_range") or "SDR")
            key = (
                height,
                width,
                round(fps or 0),
                extension,
                video_codec,
                has_audio,
                dynamic_range,
            )
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
            video_codec = str(item.get("vcodec") or "unknown").split(".", 1)[0].upper()
            has_audio = format_has_audio(item)
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
            label_parts.append(video_codec)
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
            specs[option.id] = DownloadSpec(
                option=option,
                selector=selector,
                headers=_direct_headers(
                    item.get("http_headers") or info.get("http_headers"),
                    str(item.get("url") or url),
                    url,
                    cookie_header,
                ),
            )

        direct_url = info.get("url") if not formats else None
        direct_extension = str(info.get("ext") or "").lower()
        image_extensions = {"jpg", "jpeg", "png", "webp", "avif", "gif"}
        if direct_url and direct_extension in image_extensions:
            option = MediaOption(
                id="image:source",
                kind=AssetKind.IMAGE,
                label=f"原始图片 · {direct_extension.upper()}",
                extension=direct_extension,
                preview_url=str(direct_url),
            )
            specs[option.id] = DownloadSpec(
                option=option,
                direct_url=str(direct_url),
                headers=_direct_headers(
                    info.get("http_headers"), str(direct_url), url, cookie_header
                ),
            )
        elif direct_url and not sorted_videos:
            extension = direct_extension or "mp4"
            option = MediaOption(
                id="video:direct",
                kind=AssetKind.VIDEO,
                label=f"网页原始视频 · {extension.upper()}",
                extension=extension,
            )
            specs[option.id] = DownloadSpec(
                option=option,
                direct_url=str(direct_url),
                headers=_direct_headers(
                    info.get("http_headers"), str(direct_url), url, cookie_header
                ),
            )

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
                preview_url=str(item_url),
            )
            specs[option.id] = DownloadSpec(
                option=option,
                direct_url=str(item_url),
                headers=_direct_headers(
                    item.get("http_headers") or info.get("http_headers"),
                    str(item_url),
                    url,
                    cookie_header,
                ),
            )

        has_audio = (
            bool(audio_formats)
            or any(format_has_audio(item) for item in formats)
            or (
                bool(direct_url)
                and direct_extension not in image_extensions
                and str(info.get("acodec") or "").lower() != "none"
            )
        )
        if has_audio:
            best_audio_format = max(
                audio_formats,
                key=lambda item: (
                    _as_float(item.get("abr")) or 0,
                    _as_float(item.get("tbr")) or 0,
                ),
                default=info,
            )
            best_audio_extension = str(best_audio_format.get("ext") or "m4a").lower()
            audio_presets = []
            if audio_formats:
                audio_presets.append(
                    (
                        "audio:best",
                        f"最佳原始音频 · {best_audio_extension.upper()}",
                        best_audio_extension,
                        None,
                        None,
                    )
                )
            audio_presets.extend(
                (
                    ("audio:mp3:320", "MP3 · 320 kbps", "mp3", "mp3", "320"),
                    ("audio:mp3:192", "MP3 · 192 kbps", "mp3", "mp3", "192"),
                    ("audio:m4a:256", "M4A · 256 kbps", "m4a", "m4a", "256"),
                )
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
                    headers=_direct_headers(
                        best_audio_format.get("http_headers")
                        or info.get("http_headers"),
                        str(best_audio_format.get("url") or url),
                        url,
                        cookie_header,
                    ),
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
                preview_url=str(thumbnail),
            )
            specs[cover.id] = DownloadSpec(
                option=cover,
                direct_url=str(thumbnail),
                headers=_direct_headers(
                    info.get("http_headers"), str(thumbnail), url, cookie_header
                ),
            )

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
        with httpx.Client(
            headers=headers,
            timeout=20,
            follow_redirects=False,
            trust_env=False,
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
        platform = (
            meta_value("og:site_name") or urlparse(page_url).hostname or "通用网页"
        )
        image_urls: list[str] = []
        for tag in soup.find_all("meta"):
            key = tag.get("property") or tag.get("name")
            if key in {"og:image", "og:image:url", "twitter:image"} and tag.get(
                "content"
            ):
                candidate = urljoin(page_url, str(tag["content"]))
                if candidate not in image_urls:
                    image_urls.append(candidate)
        video_url = meta_value("og:video", "og:video:url", "twitter:player:stream")
        if video_url:
            video_url = urljoin(page_url, video_url)
        audio_url = meta_value("og:audio", "og:audio:url")
        if audio_url:
            audio_url = urljoin(page_url, audio_url)
        video_urls = [video_url] if video_url else []
        audio_urls = [audio_url] if audio_url else []
        for tag in soup.find_all(["video", "audio", "source"]):
            candidate = tag.get("src") or tag.get("data-src")
            if not candidate:
                continue
            absolute = urljoin(page_url, str(candidate))
            mime = str(tag.get("type") or "").lower()
            extension = urlparse(absolute).path.rsplit(".", 1)[-1].lower()
            if (
                tag.name == "audio"
                or mime.startswith("audio/")
                or extension in {"mp3", "m4a", "aac", "ogg", "opus", "wav", "flac"}
            ):
                if absolute not in audio_urls:
                    audio_urls.append(absolute)
            elif absolute not in video_urls:
                video_urls.append(absolute)

        media_id = uuid.uuid4().hex
        specs: dict[str, DownloadSpec] = {}
        for index, video_url in enumerate(video_urls[:20], start=1):
            try:
                validate_public_url(video_url, self._settings.allow_fake_ip_dns)
            except ValueError:
                continue
            extension = video_url.split("?", 1)[0].rsplit(".", 1)[-1].lower()
            if extension not in {"mp4", "webm", "mov", "m4v"}:
                extension = "mp4"
            option = MediaOption(
                id=f"video:direct:{index}",
                kind=AssetKind.VIDEO,
                label=f"网页原始视频 · {extension.upper()}",
                extension=extension,
            )
            specs[option.id] = DownloadSpec(
                option=option,
                direct_url=video_url,
                headers={"Referer": page_url},
            )
        for index, audio_url in enumerate(audio_urls[:20], start=1):
            try:
                validate_public_url(audio_url, self._settings.allow_fake_ip_dns)
            except ValueError:
                continue
            extension = audio_url.split("?", 1)[0].rsplit(".", 1)[-1].lower()
            if extension not in {"mp3", "m4a", "aac", "ogg", "opus", "wav", "flac"}:
                extension = "m4a"
            option = MediaOption(
                id=f"audio:direct:{index}",
                kind=AssetKind.AUDIO,
                label=f"网页原始音频 · {extension.upper()}",
                extension=extension,
            )
            specs[option.id] = DownloadSpec(
                option=option,
                direct_url=audio_url,
                headers={"Referer": page_url},
            )
        for index, image_url in enumerate(image_urls[:20], start=1):
            try:
                validate_public_url(image_url, self._settings.allow_fake_ip_dns)
            except ValueError:
                continue
            extension = image_url.split("?", 1)[0].rsplit(".", 1)[-1].lower()
            if extension not in {"jpg", "jpeg", "png", "webp", "avif"}:
                extension = "jpg"
            option = MediaOption(
                id=f"image:{index}",
                kind=AssetKind.IMAGE,
                label=f"图片 {index} · {extension.upper()}",
                extension=extension,
                preview_url=image_url,
            )
            specs[option.id] = DownloadSpec(
                option=option,
                direct_url=image_url,
                headers={"Referer": page_url},
            )

        if not specs:
            message = clean_ytdlp_error(extractor_error)
            raise yt_dlp.utils.DownloadError(
                f"该页面暂未发现公开媒体资源：{message[:240]}"
            )

        media = MediaInfo(
            media_id=media_id,
            source_url=page_url,
            title=title or "未命名网页媒体",
            platform=platform,
            thumbnail_url=next(
                (
                    spec.direct_url
                    for spec in specs.values()
                    if spec.option.kind == AssetKind.IMAGE and spec.direct_url
                ),
                None,
            ),
            options=[spec.option for spec in specs.values()],
            warnings=["站点专用解析器不可用，已使用通用网页媒体解析。"],
        )
        return ResolvedEntry(media=media, specs=specs, created_at=time.time())

    def _prune(self) -> None:
        cutoff = time.time() - self._settings.cache_ttl_seconds
        with self._cache_lock:
            expired = [
                key for key, value in self._cache.items() if value.created_at < cutoff
            ]
            for key in expired:
                self._cache.pop(key, None)
            if expired:
                expired_ids = set(expired)
                self._source_cache = {
                    key: value
                    for key, value in self._source_cache.items()
                    if value not in expired_ids
                }
