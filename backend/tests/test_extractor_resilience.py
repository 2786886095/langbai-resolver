from __future__ import annotations

from contextlib import contextmanager

import httpx

from app.config import Settings
from app.services.extractor import ResolverService, _direct_headers


def _settings(tmp_path) -> Settings:
    return Settings(
        host="127.0.0.1",
        port=8787,
        download_dir=tmp_path / "downloads",
        cache_ttl_seconds=3600,
        job_ttl_seconds=3600,
        max_concurrent_jobs=1,
        cors_origins=("http://localhost",),
        ffmpeg_location=None,
        allow_fake_ip_dns=False,
    )


def test_open_graph_falls_back_to_html_audio(monkeypatch, tmp_path) -> None:
    html = b"""
    <html><head><title>Audio page</title></head>
    <body><audio controls src="/media/song.flac"></audio></body></html>
    """

    @contextmanager
    def fake_stream(_client, _method, url, **_kwargs):
        yield httpx.Response(
            200,
            content=html,
            headers={"content-type": "text/html; charset=utf-8"},
            request=httpx.Request("GET", url),
        )

    monkeypatch.setattr("app.services.extractor.stream_public_response", fake_stream)
    monkeypatch.setattr(
        "app.services.extractor.validate_public_url", lambda value, _allow=False: value
    )
    entry = ResolverService(_settings(tmp_path))._resolve_open_graph(
        "https://public.example/page", "extractor unavailable"
    )
    assert len(entry.media.options) == 1
    assert entry.media.options[0].kind.value == "audio"
    assert entry.media.options[0].extension == "flac"
    assert entry.specs[entry.media.options[0].id].headers == {
        "Referer": "https://public.example/page"
    }


def test_video_formats_keep_distinct_codecs(monkeypatch, tmp_path) -> None:
    info = {
        "id": "sample",
        "title": "Codec sample",
        "webpage_url": "https://public.example/watch",
        "formats": [
            {
                "format_id": "avc",
                "vcodec": "avc1.640028",
                "acodec": "none",
                "height": 1080,
                "width": 1920,
                "fps": 30,
                "ext": "mp4",
                "tbr": 4000,
                "url": "https://cdn.example/avc.mp4",
            },
            {
                "format_id": "hevc",
                "vcodec": "hev1.1.6.L120",
                "acodec": "none",
                "height": 1080,
                "width": 1920,
                "fps": 30,
                "ext": "mp4",
                "tbr": 3500,
                "url": "https://cdn.example/hevc.mp4",
            },
            {
                "format_id": "audio",
                "vcodec": "none",
                "acodec": "mp4a.40.2",
                "ext": "m4a",
                "abr": 192,
                "url": "https://cdn.example/audio.m4a",
            },
        ],
    }

    class FakeYDL:
        def __init__(self, *_args, **_kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def extract_info(self, _url, download=False):
            assert download is False
            return info

    monkeypatch.setattr("app.services.extractor.SafeYoutubeDL", FakeYDL)
    entry = ResolverService(_settings(tmp_path))._resolve_with_ytdlp(
        "https://public.example/watch"
    )
    video_labels = [
        option.label for option in entry.media.options if option.kind.value == "video"
    ]
    assert len(video_labels) == 2
    assert any("AVC1" in label for label in video_labels)
    assert any("HEV1" in label for label in video_labels)
    best_audio = next(
        option for option in entry.media.options if option.id == "audio:best"
    )
    assert best_audio.extension == "m4a"
    assert "M4A" in best_audio.label


def test_sensitive_headers_are_scoped_to_original_host() -> None:
    headers = {
        "Authorization": "Bearer secret",
        "Cookie": "session=secret",
        "Referer": "https://source.example/watch",
    }
    cross_host = _direct_headers(
        headers,
        "https://cdn.example/video.mp4",
        "https://source.example/watch",
    )
    assert cross_host == {"Referer": "https://source.example/watch"}

    same_host = _direct_headers(
        headers,
        "https://source.example/video.mp4",
        "https://source.example/watch",
    )
    assert same_host and same_host["Authorization"] == "Bearer secret"
    assert "Cookie" not in same_host
