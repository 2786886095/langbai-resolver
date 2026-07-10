from __future__ import annotations

import re
from urllib.parse import quote

import httpx

from app.models import MusicFile, MusicSearchResult


class OpenMusicService:
    """Searches public-domain and openly licensed audio on Internet Archive."""

    _identifier_pattern = re.compile(r"^[A-Za-z0-9._-]{1,160}$")

    def search(self, query: str, limit: int = 12) -> list[MusicSearchResult]:
        query = query.strip()
        if not query:
            return []
        search_query = f'mediatype:audio AND (title:"{query}" OR creator:"{query}")'
        params = {
            "q": search_query,
            "fl[]": ["identifier", "title", "creator", "year"],
            "rows": str(min(max(limit, 1), 30)),
            "page": "1",
            "output": "json",
            "sort[]": "downloads desc",
        }
        with httpx.Client(timeout=25) as client:
            response = client.get("https://archive.org/advancedsearch.php", params=params)
            response.raise_for_status()
        docs = response.json().get("response", {}).get("docs", [])
        results: list[MusicSearchResult] = []
        for item in docs:
            identifier = str(item.get("identifier") or "")
            if not self._identifier_pattern.fullmatch(identifier):
                continue
            creator = item.get("creator")
            if isinstance(creator, list):
                creator = ", ".join(str(value) for value in creator[:3])
            results.append(
                MusicSearchResult(
                    identifier=identifier,
                    title=str(item.get("title") or identifier),
                    creator=str(creator) if creator else None,
                    year=str(item.get("year")) if item.get("year") else None,
                    item_url=f"https://archive.org/details/{quote(identifier)}",
                )
            )
        return results

    def files(self, identifier: str) -> list[MusicFile]:
        if not self._identifier_pattern.fullmatch(identifier):
            raise ValueError("无效的音乐资源标识")
        with httpx.Client(timeout=25) as client:
            response = client.get(f"https://archive.org/metadata/{quote(identifier)}")
            response.raise_for_status()
        files: list[MusicFile] = []
        preferred = {"flac", "wave", "wav", "24bit flac", "vbr mp3", "mp3"}
        for item in response.json().get("files", []):
            name = str(item.get("name") or "")
            file_format = str(item.get("format") or "")
            suffix = name.rsplit(".", 1)[-1].lower() if "." in name else ""
            if suffix not in {"flac", "wav", "mp3", "m4a", "ogg", "opus"} and file_format.lower() not in preferred:
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
        files.sort(key=lambda item: (item.format.lower() not in {"flac", "24bit flac", "wave", "wav"}, item.name))
        return files[:80]

