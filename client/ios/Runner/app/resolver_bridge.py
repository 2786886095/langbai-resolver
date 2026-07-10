from __future__ import annotations

import json
import re
import shutil
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

import yt_dlp


_CACHE: dict[str, dict[str, Any]] = {}
_IMAGE_EXTENSIONS = {"jpg", "jpeg", "png", "webp", "avif", "gif"}
_AUDIO_EXTENSIONS = {"mp3", "m4a", "aac", "ogg", "opus", "wav", "flac"}
_USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
    "AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
)


def _text(value: object) -> str | None:
    if value is None:
        return None
    result = str(value).strip()
    return result or None


def _integer(value: object) -> int | None:
    try:
        result = int(float(value))
        return result if result > 0 else None
    except (TypeError, ValueError):
        return None


def _number(value: object) -> float | None:
    try:
        result = float(value)
        return result if result > 0 else None
    except (TypeError, ValueError):
        return None


def _human_bytes(value: int | None) -> str | None:
    if not value:
        return None
    size = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{int(size)} B" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return None


def _option(
    option_id: str,
    kind: str,
    label: str,
    extension: str,
    *,
    resolution: str | None = None,
    bitrate: int | None = None,
    fps: float | None = None,
    filesize: int | None = None,
) -> dict[str, object]:
    return {
        "id": option_id,
        "kind": kind,
        "label": label,
        "extension": extension,
        "resolution": resolution,
        "bitrate_kbps": bitrate,
        "fps": fps,
        "filesize": filesize,
        "filesize_label": _human_bytes(filesize),
        "requires_merge": False,
    }


def _base_options() -> dict[str, Any]:
    return {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "skip_download": True,
        "socket_timeout": 25,
        "retries": 2,
        "extractor_retries": 2,
        "http_headers": {"User-Agent": _USER_AGENT},
        "extractor_args": {
            "youtube": {"player_client": ["ios", "android_vr", "web_safari"]}
        },
    }


def _is_douyin_url(value: str) -> bool:
    host = (urllib.parse.urlparse(value).hostname or "").lower()
    return (
        host == "douyin.com"
        or host.endswith(".douyin.com")
        or host == "iesdouyin.com"
        or host.endswith(".iesdouyin.com")
    )


def _douyin_video_id(value: str) -> str | None:
    match = re.search(r"/(?:video|note)/(\d{10,})", value)
    if match:
        return match.group(1)
    query = urllib.parse.parse_qs(urllib.parse.urlparse(value).query)
    for key in ("modal_id", "aweme_id", "item_id"):
        candidate = _text((query.get(key) or [None])[0])
        if candidate and re.fullmatch(r"\d{10,}", candidate):
            return candidate
    return None


def _first_http_url(value: object) -> str | None:
    if not isinstance(value, list):
        return None
    return next(
        (str(item) for item in value if str(item).startswith(("http://", "https://"))),
        None,
    )


def _resolve_douyin_share(url: str) -> dict[str, Any]:
    video_id = _douyin_video_id(url)
    if not video_id:
        request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
        with urllib.request.urlopen(request, timeout=20) as response:
            final_url = response.geturl()
            html = response.read().decode("utf-8", "replace")
        if not _is_douyin_url(final_url):
            raise RuntimeError("抖音短链接跳转到了未知站点")
        video_id = _douyin_video_id(final_url)
        if not video_id:
            match = re.search(r"(?:video|note)[/\\\"]+(\d{10,})", html)
            video_id = match.group(1) if match else None
    if not video_id:
        raise RuntimeError("无法从抖音链接识别作品 ID")

    share_url = f"https://www.iesdouyin.com/share/video/{video_id}/"
    request = urllib.request.Request(share_url, headers={"User-Agent": _USER_AGENT})
    with urllib.request.urlopen(request, timeout=25) as response:
        html = response.read().decode("utf-8", "replace")
    marker = "window._ROUTER_DATA ="
    marker_index = html.find(marker)
    json_start = html.find("{", marker_index + len(marker))
    script_end = html.find("</script>", json_start)
    if marker_index < 0 or json_start < 0 or script_end <= json_start:
        raise RuntimeError("匿名分享页没有内嵌作品数据")
    router_data = json.loads(html[json_start:script_end].strip().removesuffix(";"))
    loader_data = router_data.get("loaderData") or {}
    page_data = next(
        (
            value
            for value in loader_data.values()
            if isinstance(value, dict) and isinstance(value.get("videoInfoRes"), dict)
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
        raise RuntimeError("匿名分享页没有返回作品详情")

    specs: dict[str, dict[str, Any]] = {}
    options: list[dict[str, object]] = []
    video = item.get("video") if isinstance(item.get("video"), dict) else {}
    play_url = _first_http_url((video.get("play_addr") or {}).get("url_list"))
    width = _integer(video.get("width"))
    height = _integer(video.get("height"))
    if play_url:
        resolution = (
            urllib.parse.parse_qs(urllib.parse.urlparse(play_url).query)
            .get("ratio", [None])[0]
        ) or (f"{width}×{height}" if width and height else None)
        specs["video:douyin-share"] = {
            "kind": "video",
            "direct_url": play_url,
            "extension": "mp4",
        }
        options.append(
            _option(
                "video:douyin-share",
                "video",
                "抖音公开视频 · MP4",
                "mp4",
                resolution=resolution,
            )
        )

    cover_url = _first_http_url((video.get("cover") or {}).get("url_list"))
    image_sources: list[tuple[str, str]] = []
    if cover_url:
        image_sources.append(("cover", cover_url))
    for index, image in enumerate(item.get("images") or [], start=1):
        if not isinstance(image, dict):
            continue
        image_url = _first_http_url(
            image.get("url_list") or image.get("download_url_list")
        )
        if image_url:
            image_sources.append((str(index), image_url))
    for label, image_url in image_sources[:20]:
        extension = (
            Path(urllib.parse.urlparse(image_url).path).suffix.lstrip(".").lower()
        )
        if extension not in _IMAGE_EXTENSIONS:
            extension = "jpg"
        option_id = f"image:{label}"
        specs[option_id] = {
            "kind": "image",
            "direct_url": image_url,
            "extension": extension,
        }
        options.append(
            _option(
                option_id,
                "image",
                "最高质量封面" if label == "cover" else f"图片 {label}",
                extension,
            )
        )
    if not options:
        raise RuntimeError("匿名分享页没有返回视频或图片地址")

    media_id = uuid.uuid4().hex
    title = _text(item.get("desc")) or f"抖音作品 {video_id}"
    author = item.get("author") if isinstance(item.get("author"), dict) else {}
    _CACHE[media_id] = {"source_url": url, "title": title, "specs": specs}
    if len(_CACHE) > 80:
        _CACHE.pop(next(iter(_CACHE)))
    duration_ms = _integer(video.get("duration"))
    return {
        "media_id": media_id,
        "source_url": url,
        "title": title,
        "creator": _text(author.get("nickname")),
        "platform": "Douyin",
        "duration_seconds": duration_ms // 1000 if duration_ms else None,
        "thumbnail_url": cover_url,
        "options": options,
        "warnings": ["已通过抖音匿名分享页直接解析，全程不读取或发送 Cookie。"],
    }


def resolve(argument: str) -> str:
    request = json.loads(argument)
    url = str(request.get("url") or "").strip()
    if not url.startswith(("http://", "https://")):
        raise ValueError("请输入完整的 http 或 https 链接")
    if _is_douyin_url(url):
        return json.dumps(_resolve_douyin_share(url), ensure_ascii=False)

    with yt_dlp.YoutubeDL(_base_options()) as ydl:
        raw = ydl.extract_info(url, download=False)
    if not raw:
        raise RuntimeError("本地解析器没有返回媒体信息")

    root = raw
    entries = [item for item in (raw.get("entries") or []) if isinstance(item, dict)]
    if not raw.get("formats"):
        root = next((item for item in entries if item.get("formats")), raw)

    specs: dict[str, dict[str, Any]] = {}
    options: list[dict[str, object]] = []
    formats = [item for item in (root.get("formats") or []) if isinstance(item, dict)]

    video_items = []
    for item in formats:
        format_id = _text(item.get("format_id"))
        video_codec = _text(item.get("vcodec"))
        audio_codec = _text(item.get("acodec"))
        if not format_id or not video_codec or video_codec == "none":
            continue
        if not audio_codec or audio_codec == "none":
            continue
        video_items.append(item)

    seen_video: set[tuple[object, ...]] = set()
    video_items.sort(
        key=lambda item: (
            _integer(item.get("height")) or 0,
            _number(item.get("fps")) or 0,
            _number(item.get("tbr")) or 0,
        ),
        reverse=True,
    )
    for item in video_items:
        format_id = str(item["format_id"])
        height = _integer(item.get("height"))
        width = _integer(item.get("width"))
        fps = _number(item.get("fps"))
        extension = str(item.get("ext") or "mp4").lower()
        key = (width, height, round(fps or 0), extension)
        if key in seen_video or len(seen_video) >= 24:
            continue
        seen_video.add(key)
        option_id = f"video:{format_id}"
        label = " · ".join(
            value
            for value in (
                f"{height}p" if height else _text(item.get("format_note")) or "视频",
                f"{int(fps)}fps" if fps and fps > 30 else None,
                extension.upper(),
                "iOS 兼容音画",
            )
            if value
        )
        filesize = _integer(item.get("filesize") or item.get("filesize_approx"))
        specs[option_id] = {"selector": format_id, "kind": "video"}
        options.append(
            _option(
                option_id,
                "video",
                label,
                extension,
                resolution=f"{width}×{height}" if width and height else None,
                fps=fps,
                filesize=filesize,
            )
        )

    audio_items = []
    for item in formats:
        format_id = _text(item.get("format_id"))
        audio_codec = _text(item.get("acodec"))
        video_codec = _text(item.get("vcodec"))
        if not format_id or not audio_codec or audio_codec == "none":
            continue
        if video_codec not in {None, "none"}:
            continue
        audio_items.append(item)
    audio_items.sort(key=lambda item: _number(item.get("abr")) or 0, reverse=True)
    seen_audio: set[tuple[str, int]] = set()
    for item in audio_items:
        format_id = str(item["format_id"])
        extension = str(item.get("ext") or "m4a").lower()
        bitrate = int(_number(item.get("abr")) or 0)
        key = (extension, round(bitrate / 32) * 32)
        if key in seen_audio or len(seen_audio) >= 8:
            continue
        seen_audio.add(key)
        option_id = f"audio:{format_id}"
        specs[option_id] = {"selector": format_id, "kind": "audio"}
        options.append(
            _option(
                option_id,
                "audio",
                f"{extension.upper()} · {bitrate or '原始'} kbps",
                extension,
                bitrate=bitrate or None,
                filesize=_integer(item.get("filesize") or item.get("filesize_approx")),
            )
        )

    image_index = 0
    for item in entries:
        direct_url = _text(item.get("url"))
        extension = str(item.get("ext") or "").lower()
        if not direct_url or extension not in _IMAGE_EXTENSIONS:
            continue
        image_index += 1
        option_id = f"image:entry:{image_index}"
        specs[option_id] = {
            "kind": "image",
            "direct_url": direct_url,
            "headers": item.get("http_headers") or {},
        }
        options.append(
            _option(
                option_id,
                "image",
                f"图集图片 {image_index} · {extension.upper()}",
                extension,
            )
        )
        if image_index >= 40:
            break

    thumbnail = _text(root.get("thumbnail") or raw.get("thumbnail"))
    if thumbnail:
        extension = (
            Path(urllib.parse.urlparse(thumbnail).path).suffix.lstrip(".").lower()
        )
        if extension not in _IMAGE_EXTENSIONS:
            extension = "jpg"
        specs["image:cover"] = {
            "kind": "image",
            "direct_url": thumbnail,
            "headers": root.get("http_headers") or {},
        }
        options.append(
            _option(
                "image:cover",
                "image",
                f"最高质量封面 · {extension.upper()}",
                extension,
            )
        )

    direct_url = _text(root.get("url"))
    direct_extension = str(root.get("ext") or "").lower()
    if not options and direct_url:
        kind = (
            "image"
            if direct_extension in _IMAGE_EXTENSIONS
            else "audio"
            if direct_extension in _AUDIO_EXTENSIONS
            else "video"
        )
        extension = direct_extension or "mp4"
        option_id = f"{kind}:direct"
        specs[option_id] = {
            "kind": kind,
            "direct_url": direct_url,
            "headers": root.get("http_headers") or {},
        }
        options.append(
            _option(option_id, kind, f"原始媒体 · {extension.upper()}", extension)
        )

    if not options:
        raise RuntimeError("该页面暂未发现 iOS 可直接保存的公开媒体格式")

    media_id = uuid.uuid4().hex
    source_url = str(root.get("webpage_url") or raw.get("webpage_url") or url)
    title = str(root.get("title") or raw.get("title") or "未命名媒体")
    _CACHE[media_id] = {
        "source_url": source_url,
        "title": title,
        "specs": specs,
    }
    if len(_CACHE) > 80:
        _CACHE.pop(next(iter(_CACHE)))

    return json.dumps(
        {
            "media_id": media_id,
            "source_url": source_url,
            "title": title,
            "creator": root.get("uploader")
            or root.get("creator")
            or root.get("channel"),
            "platform": root.get("extractor_key")
            or root.get("extractor")
            or "iOS 本地解析",
            "duration_seconds": _integer(root.get("duration")),
            "thumbnail_url": thumbnail,
            "options": options,
            "warnings": [
                "由 iPhone 本机解析；当前版本仅显示无需 FFmpeg 合并的 iOS 兼容格式。"
            ],
        },
        ensure_ascii=False,
    )


def download(argument: str) -> str:
    request = json.loads(argument)
    media_id = str(request.get("media_id") or "")
    option_id = str(request.get("option_id") or "")
    output_dir = Path(str(request.get("output_dir") or "")).expanduser()
    media = _CACHE.get(media_id)
    if not media:
        raise RuntimeError("解析结果已过期，请重新解析链接")
    spec = media["specs"].get(option_id)
    if not spec:
        raise RuntimeError("所选格式不存在，请重新解析")

    output_dir.mkdir(parents=True, exist_ok=True)
    before = {path.resolve() for path in output_dir.iterdir() if path.is_file()}
    direct_url = spec.get("direct_url")
    if direct_url:
        parsed_extension = Path(urllib.parse.urlparse(direct_url).path).suffix
        extension = _text(spec.get("extension"))
        suffix = (
            f".{extension.lstrip('.')}" if extension else parsed_extension or ".bin"
        )
        filename = _safe_filename(str(media["title"])) + suffix
        target = _unique_path(output_dir / filename)
        headers = {"User-Agent": _USER_AGENT, **(spec.get("headers") or {})}
        with (
            urllib.request.urlopen(
                urllib.request.Request(direct_url, headers=headers), timeout=45
            ) as source,
            target.open("wb") as destination,
        ):
            shutil.copyfileobj(source, destination, length=256 * 1024)
        result_path = target
    else:
        options = _base_options()
        options.update(
            {
                "skip_download": False,
                "format": spec["selector"],
                "outtmpl": str(output_dir / "%(title).160B [%(id)s].%(ext)s"),
                "continuedl": True,
                "overwrites": False,
            }
        )
        with yt_dlp.YoutubeDL(options) as ydl:
            ydl.download([media["source_url"]])
        created = [
            path
            for path in output_dir.iterdir()
            if path.is_file()
            and path.resolve() not in before
            and path.suffix not in {".part", ".ytdl"}
        ]
        if not created:
            raise RuntimeError("下载完成但没有找到输出文件")
        result_path = max(created, key=lambda path: path.stat().st_mtime)

    return json.dumps(
        {
            "filename": result_path.name,
            "path": str(result_path),
            "message": f"已保存到“文件”App/langbai解析/{result_path.name}",
        },
        ensure_ascii=False,
    )


def version(_: str) -> str:
    return json.dumps({"version": yt_dlp.version.__version__})


def _safe_filename(value: str) -> str:
    result = re.sub(r"[\\/:*?\"<>|\r\n]+", "_", value).strip()[:160]
    return result or "langbai-media"


def _unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(2, 10_000):
        candidate = path.with_name(f"{path.stem} ({index}){path.suffix}")
        if not candidate.exists():
            return candidate
    return path.with_name(f"{path.stem}-{uuid.uuid4().hex[:8]}{path.suffix}")
