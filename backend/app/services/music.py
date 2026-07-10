from __future__ import annotations

import html
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import PurePosixPath
from threading import Lock
from urllib.parse import quote

import httpx

from app.models import MusicFile, MusicSearchResult


_USER_AGENT = "langbai-resolver/1.0.8 (https://github.com/2786886095/langbai-resolver)"


def _plain_text(value: object) -> str | None:
    if not value:
        return None
    text = re.sub(r"<[^>]+>", " ", str(value))
    text = re.sub(r"\s+", " ", html.unescape(text)).strip()
    return text or None


def _metadata_value(metadata: object, key: str) -> str | None:
    if not isinstance(metadata, dict):
        return None
    value = metadata.get(key)
    if isinstance(value, dict):
        return _plain_text(value.get("value"))
    return _plain_text(value)


class OpenMusicService:
    """Aggregates legal catalog metadata and artist-authorized downloads."""

    _archive_identifier_pattern = re.compile(r"^[A-Za-z0-9._-]{1,160}$")
    _numeric_identifier_pattern = re.compile(r"^[0-9]{1,20}$")
    _audius_identifier_pattern = re.compile(r"^[A-Za-z0-9_-]{1,80}$")

    def __init__(
        self,
        *,
        jamendo_client_id: str | None = None,
        audius_api_key: str | None = None,
    ) -> None:
        self._jamendo_client_id = jamendo_client_id
        self._audius_api_key = audius_api_key
        self._cache: dict[str, tuple[float, tuple[MusicSearchResult, ...]]] = {}
        self._cache_lock = Lock()

    def search(self, query: str, limit: int = 60) -> list[MusicSearchResult]:
        query = query.strip()
        if not query:
            return []
        limit = min(max(limit, 1), 80)
        cache_key = f"{query.casefold()}:{limit}"
        with self._cache_lock:
            cached = self._cache.get(cache_key)
            if cached and time.monotonic() - cached[0] < 300:
                return list(cached[1])
        per_source = min(max(limit // 3, 12), 24)
        providers = {
            "internet_archive": self._search_archive,
            "wikimedia_commons": self._search_commons,
            "audius": self._search_audius,
            "apple_music": self._search_itunes,
            "musicbrainz": self._search_musicbrainz,
        }
        if self._jamendo_client_id:
            providers["jamendo"] = self._search_jamendo

        buckets: dict[str, list[MusicSearchResult]] = {}
        with ThreadPoolExecutor(max_workers=len(providers)) as executor:
            futures = {
                executor.submit(search, query, per_source): name
                for name, search in providers.items()
            }
            for future in as_completed(futures):
                name = futures[future]
                try:
                    buckets[name] = future.result()
                except Exception:
                    buckets[name] = []

        order = [
            "internet_archive",
            "wikimedia_commons",
            "jamendo",
            "audius",
            "apple_music",
            "musicbrainz",
        ]
        merged: list[MusicSearchResult] = []
        positions = {name: 0 for name in order}
        seen: set[str] = set()
        while len(merged) < limit:
            added = False
            for name in order:
                items = buckets.get(name, [])
                position = positions[name]
                if position >= len(items):
                    continue
                result = items[position]
                positions[name] += 1
                added = True
                key = re.sub(
                    r"[^a-z0-9\u4e00-\u9fff]+",
                    "",
                    f"{result.title}{result.creator or ''}".lower(),
                )
                if key and key in seen:
                    continue
                if key:
                    seen.add(key)
                merged.append(result)
                if len(merged) >= limit:
                    break
            if not added:
                break
        with self._cache_lock:
            if len(self._cache) >= 64:
                oldest = min(self._cache, key=lambda key: self._cache[key][0])
                self._cache.pop(oldest, None)
            self._cache[cache_key] = (time.monotonic(), tuple(merged))
        return merged

    def files(self, identifier: str) -> list[MusicFile]:
        provider, separator, value = identifier.partition(":")
        if not separator:
            provider, value = "internet_archive", identifier
        routes = {
            "internet_archive": self._archive_files,
            "wikimedia_commons": self._commons_files,
            "audius": self._audius_files,
            "jamendo": self._jamendo_files,
        }
        handler = routes.get(provider)
        if not handler:
            return []
        return handler(value)

    def _search_archive(self, query: str, limit: int) -> list[MusicSearchResult]:
        term = re.sub(r'[()\[\]{}:\\"]+', " ", query).strip()
        params = {
            "q": f"mediatype:audio AND ({term})",
            "fl[]": ["identifier", "title", "creator", "year"],
            "rows": str(limit),
            "page": "1",
            "output": "json",
            "sort[]": "downloads desc",
        }
        with httpx.Client(timeout=25, headers={"User-Agent": _USER_AGENT}) as client:
            response = client.get(
                "https://archive.org/advancedsearch.php", params=params
            )
            response.raise_for_status()
        results: list[MusicSearchResult] = []
        for item in response.json().get("response", {}).get("docs", []):
            identifier = str(item.get("identifier") or "")
            if not self._archive_identifier_pattern.fullmatch(identifier):
                continue
            creator = item.get("creator")
            if isinstance(creator, list):
                creator = ", ".join(str(value) for value in creator[:3])
            results.append(
                MusicSearchResult(
                    identifier=f"internet_archive:{identifier}",
                    title=str(item.get("title") or identifier),
                    creator=str(creator) if creator else None,
                    year=str(item.get("year")) if item.get("year") else None,
                    item_url=f"https://archive.org/details/{quote(identifier)}",
                    source="internet_archive",
                    source_label="Internet Archive",
                    can_download=True,
                    license="开放授权 / 公共领域（以资源页为准）",
                )
            )
        return results

    def _search_musicbrainz(self, query: str, limit: int) -> list[MusicSearchResult]:
        params = {"query": query, "fmt": "json", "limit": str(limit), "dismax": "true"}
        with httpx.Client(timeout=25, headers={"User-Agent": _USER_AGENT}) as client:
            response = client.get(
                "https://musicbrainz.org/ws/2/recording/", params=params
            )
            response.raise_for_status()
        results: list[MusicSearchResult] = []
        for item in response.json().get("recordings", []):
            identifier = str(item.get("id") or "")
            if not identifier:
                continue
            credits = item.get("artist-credit") or []
            creator = "".join(
                f"{credit.get('name') or ''}{credit.get('joinphrase') or ''}"
                for credit in credits
                if isinstance(credit, dict)
            ).strip()
            first_release = str(item.get("first-release-date") or "")
            results.append(
                MusicSearchResult(
                    identifier=f"musicbrainz:{identifier}",
                    title=str(item.get("title") or identifier),
                    creator=creator or None,
                    year=first_release[:4] or None,
                    item_url=f"https://musicbrainz.org/recording/{identifier}",
                    source="musicbrainz",
                    source_label="MusicBrainz",
                    can_download=False,
                    duration_seconds=(int(item["length"]) // 1000)
                    if item.get("length")
                    else None,
                )
            )
        return results

    def _search_itunes(self, query: str, limit: int) -> list[MusicSearchResult]:
        params = {
            "term": query,
            "media": "music",
            "entity": "song",
            "country": "CN",
            "limit": str(limit),
            "lang": "zh_cn",
        }
        with httpx.Client(timeout=25, headers={"User-Agent": _USER_AGENT}) as client:
            response = client.get("https://itunes.apple.com/search", params=params)
            response.raise_for_status()
        results: list[MusicSearchResult] = []
        for item in response.json().get("results", []):
            identifier = str(item.get("trackId") or "")
            if not self._numeric_identifier_pattern.fullmatch(identifier):
                continue
            released = str(item.get("releaseDate") or "")
            artwork = str(item.get("artworkUrl100") or "").replace("100x100", "600x600")
            results.append(
                MusicSearchResult(
                    identifier=f"apple_music:{identifier}",
                    title=str(item.get("trackName") or identifier),
                    creator=str(item.get("artistName") or "") or None,
                    year=released[:4] or None,
                    item_url=str(
                        item.get("trackViewUrl")
                        or item.get("collectionViewUrl")
                        or "https://music.apple.com"
                    ),
                    source="apple_music",
                    source_label="Apple Music",
                    can_download=False,
                    artwork_url=artwork or None,
                    album=str(item.get("collectionName") or "") or None,
                    duration_seconds=(int(item["trackTimeMillis"]) // 1000)
                    if item.get("trackTimeMillis")
                    else None,
                )
            )
        return results

    def _audius_headers(self) -> dict[str, str]:
        headers = {"User-Agent": _USER_AGENT}
        if self._audius_api_key:
            headers["x-api-key"] = self._audius_api_key
        return headers

    def _search_audius(self, query: str, limit: int) -> list[MusicSearchResult]:
        with httpx.Client(timeout=25, headers=self._audius_headers()) as client:
            response = client.get(
                "https://api.audius.co/v1/tracks/search",
                params={"query": query, "limit": str(limit), "sort_method": "relevant"},
            )
            response.raise_for_status()
        results: list[MusicSearchResult] = []
        for item in response.json().get("data", []):
            identifier = str(item.get("id") or "")
            if not self._audius_identifier_pattern.fullmatch(identifier):
                continue
            if item.get("is_delete") or item.get("is_available") is False:
                continue
            user = item.get("user") if isinstance(item.get("user"), dict) else {}
            permalink = str(item.get("permalink") or "")
            preview = (
                item.get("preview") if isinstance(item.get("preview"), dict) else {}
            )
            download = (
                item.get("download") if isinstance(item.get("download"), dict) else {}
            )
            can_download = bool(item.get("is_downloadable") and download.get("url"))
            results.append(
                MusicSearchResult(
                    identifier=f"audius:{identifier}",
                    title=str(item.get("title") or identifier),
                    creator=str(user.get("name") or user.get("handle") or "") or None,
                    year=str(item.get("release_date") or "")[:4] or None,
                    item_url=f"https://audius.co{permalink}"
                    if permalink
                    else "https://audius.co",
                    source="audius",
                    source_label="Audius",
                    can_download=can_download,
                    preview_url=str(preview.get("url") or "") or None,
                    artwork_url=(item.get("artwork") or {}).get("480x480")
                    if isinstance(item.get("artwork"), dict)
                    else None,
                    album=(item.get("album_backlink") or {}).get("playlist_name")
                    if isinstance(item.get("album_backlink"), dict)
                    else None,
                    duration_seconds=int(item["duration"])
                    if item.get("duration")
                    else None,
                    license=str(item.get("license") or "") or None,
                )
            )
        return results

    def _search_commons(self, query: str, limit: int) -> list[MusicSearchResult]:
        params = {
            "action": "query",
            "format": "json",
            "generator": "search",
            "gsrsearch": f"{query} filetype:audio",
            "gsrnamespace": "6",
            "gsrlimit": str(limit),
            "prop": "imageinfo|info",
            "iiprop": "url|mime|size|extmetadata",
            "inprop": "url",
            "iiextmetadatalanguage": "zh",
        }
        with httpx.Client(timeout=25, headers={"User-Agent": _USER_AGENT}) as client:
            response = client.get(
                "https://commons.wikimedia.org/w/api.php", params=params
            )
            response.raise_for_status()
        results: list[MusicSearchResult] = []
        pages = response.json().get("query", {}).get("pages", {})
        for page in pages.values():
            info_items = page.get("imageinfo") or []
            if not info_items:
                continue
            info = info_items[0]
            mime = str(info.get("mime") or "")
            if not mime.startswith("audio/"):
                continue
            metadata = info.get("extmetadata")
            title = str(page.get("title") or "").removeprefix("File:")
            results.append(
                MusicSearchResult(
                    identifier=f"wikimedia_commons:{page.get('pageid')}",
                    title=_metadata_value(metadata, "ObjectName") or title,
                    creator=_metadata_value(metadata, "Artist")
                    or _metadata_value(metadata, "Credit"),
                    year=(_metadata_value(metadata, "DateTimeOriginal") or "")[:4]
                    or None,
                    item_url=str(
                        page.get("canonicalurl") or info.get("descriptionurl") or ""
                    ),
                    source="wikimedia_commons",
                    source_label="Wikimedia Commons",
                    can_download=True,
                    preview_url=str(info.get("url") or "") or None,
                    license=_metadata_value(metadata, "LicenseShortName")
                    or _metadata_value(metadata, "UsageTerms"),
                )
            )
        return results

    def _search_jamendo(self, query: str, limit: int) -> list[MusicSearchResult]:
        assert self._jamendo_client_id
        params = {
            "client_id": self._jamendo_client_id,
            "format": "json",
            "limit": str(limit),
            "search": query,
            "include": "musicinfo",
            "imagesize": "300",
            "audioformat": "mp32",
            "audiodlformat": "flac",
        }
        with httpx.Client(timeout=25, headers={"User-Agent": _USER_AGENT}) as client:
            response = client.get("https://api.jamendo.com/v3.0/tracks/", params=params)
            response.raise_for_status()
        results: list[MusicSearchResult] = []
        for item in response.json().get("results", []):
            identifier = str(item.get("id") or "")
            if not self._numeric_identifier_pattern.fullmatch(identifier):
                continue
            can_download = bool(
                item.get("audiodownload_allowed") and item.get("audiodownload")
            )
            results.append(
                MusicSearchResult(
                    identifier=f"jamendo:{identifier}",
                    title=str(item.get("name") or identifier),
                    creator=str(item.get("artist_name") or "") or None,
                    year=str(item.get("releasedate") or "")[:4] or None,
                    item_url=str(
                        item.get("shareurl")
                        or item.get("shorturl")
                        or "https://www.jamendo.com"
                    ),
                    source="jamendo",
                    source_label="Jamendo",
                    can_download=can_download,
                    preview_url=str(item.get("audio") or "") or None,
                    artwork_url=str(item.get("image") or item.get("album_image") or "")
                    or None,
                    album=str(item.get("album_name") or "") or None,
                    duration_seconds=int(item["duration"])
                    if item.get("duration")
                    else None,
                    license=str(item.get("license_ccurl") or "") or None,
                )
            )
        return results

    def _archive_files(self, identifier: str) -> list[MusicFile]:
        if not self._archive_identifier_pattern.fullmatch(identifier):
            raise ValueError("无效的 Internet Archive 音乐标识")
        with httpx.Client(timeout=25, headers={"User-Agent": _USER_AGENT}) as client:
            response = client.get(f"https://archive.org/metadata/{quote(identifier)}")
            response.raise_for_status()
        files: list[MusicFile] = []
        preferred = {"flac", "wave", "wav", "24bit flac", "vbr mp3", "mp3"}
        for item in response.json().get("files", []):
            name = str(item.get("name") or "")
            file_format = str(item.get("format") or "")
            suffix = name.rsplit(".", 1)[-1].lower() if "." in name else ""
            if (
                suffix not in {"flac", "wav", "mp3", "m4a", "ogg", "opus"}
                and file_format.lower() not in preferred
            ):
                continue
            try:
                size = int(item["size"]) if item.get("size") else None
            except (TypeError, ValueError):
                size = None
            files.append(
                MusicFile(
                    name=name,
                    format=file_format or suffix.upper(),
                    size=size,
                    download_url=f"https://archive.org/download/{quote(identifier)}/{quote(name)}",
                )
            )
        files.sort(
            key=lambda item: (
                item.format.lower() not in {"flac", "24bit flac", "wave", "wav"},
                item.name,
            )
        )
        return files[:80]

    def _commons_files(self, page_id: str) -> list[MusicFile]:
        if not self._numeric_identifier_pattern.fullmatch(page_id):
            raise ValueError("无效的 Wikimedia Commons 音乐标识")
        params = {
            "action": "query",
            "format": "json",
            "pageids": page_id,
            "prop": "imageinfo",
            "iiprop": "url|mime|size",
        }
        with httpx.Client(timeout=25, headers={"User-Agent": _USER_AGENT}) as client:
            response = client.get(
                "https://commons.wikimedia.org/w/api.php", params=params
            )
            response.raise_for_status()
        page = response.json().get("query", {}).get("pages", {}).get(page_id, {})
        info_items = page.get("imageinfo") or []
        if not info_items:
            return []
        info = info_items[0]
        url = str(info.get("url") or "")
        if not url:
            return []
        name = PurePosixPath(httpx.URL(url).path).name or f"commons-{page_id}.audio"
        return [
            MusicFile(
                name=name,
                format=str(info.get("mime") or "audio").split("/")[-1].upper(),
                size=int(info["size"]) if info.get("size") else None,
                download_url=url,
            )
        ]

    def _audius_files(self, identifier: str) -> list[MusicFile]:
        if not self._audius_identifier_pattern.fullmatch(identifier):
            raise ValueError("无效的 Audius 音乐标识")
        with httpx.Client(timeout=25, headers=self._audius_headers()) as client:
            response = client.get(f"https://api.audius.co/v1/tracks/{identifier}")
            response.raise_for_status()
        item = response.json().get("data") or {}
        download = (
            item.get("download") if isinstance(item.get("download"), dict) else {}
        )
        url = str(download.get("url") or "") if item.get("is_downloadable") else ""
        if not url:
            return []
        filename = str(
            item.get("orig_filename") or f"{item.get('title') or identifier}.mp3"
        )
        return [MusicFile(name=filename, format="原始音频", download_url=url)]

    def _jamendo_files(self, identifier: str) -> list[MusicFile]:
        if not self._jamendo_client_id:
            return []
        if not self._numeric_identifier_pattern.fullmatch(identifier):
            raise ValueError("无效的 Jamendo 音乐标识")
        params = {
            "client_id": self._jamendo_client_id,
            "format": "json",
            "id": identifier,
            "limit": "1",
            "audioformat": "flac",
            "audiodlformat": "flac",
        }
        with httpx.Client(timeout=25, headers={"User-Agent": _USER_AGENT}) as client:
            response = client.get("https://api.jamendo.com/v3.0/tracks/", params=params)
            response.raise_for_status()
        items = response.json().get("results", [])
        if not items:
            return []
        item = items[0]
        url = str(item.get("audiodownload") or "")
        if not item.get("audiodownload_allowed") or not url:
            return []
        name = f"{item.get('artist_name') or 'Jamendo'} - {item.get('name') or identifier}.flac"
        return [MusicFile(name=name, format="FLAC", download_url=url)]
