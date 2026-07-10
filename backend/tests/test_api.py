import json

import httpx
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app
from app.services.extractor import (
    ResolverService,
    browser_cookies_required,
    clean_ytdlp_error,
    extract_http_url,
)


client = TestClient(app)
DOUYIN_SHARE_TEXT = (
    "3.05 复制打开抖音，看看【樱梨梨的作品】他们走不了了 "
    "# 瓦是大明星 # 瓦赛来了 # 暮... "
    "https://v.douyin.com/9AgsTehs2gM/ C@H.Vl :1pm 10/02 Agb:/"
)


def test_health() -> None:
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_rejects_localhost() -> None:
    response = client.post("/api/v1/resolve", json={"url": "http://127.0.0.1/private"})
    assert response.status_code == 400


def test_extracts_url_from_complete_douyin_share_text() -> None:
    assert extract_http_url(DOUYIN_SHARE_TEXT) == (
        "https://v.douyin.com/9AgsTehs2gM/"
    )


def test_update_manifest_has_all_primary_clients() -> None:
    response = client.get("/api/v1/update")
    assert response.status_code == 200
    payload = response.json()
    assert payload["version"] == "1.0.6"
    assert {"windows", "android", "ios", "web"}.issubset(payload["platforms"])


def test_cleans_douyin_terminal_error() -> None:
    raw = (
        "ERROR: \x1b[0;31mERROR:\x1b[0m [Douyin] 7658650507234212965: "
        "Fresh cookies (not necessarily logged in) are needed"
    )
    cleaned = clean_ytdlp_error(raw)
    assert "\x1b" not in cleaned
    assert cleaned.startswith("[Douyin]")
    assert browser_cookies_required(cleaned)


def test_douyin_share_parser_does_not_send_cookies(monkeypatch) -> None:
    video_id = "7658650507234212965"
    router_data = {
        "loaderData": {
            "video_(id)/page": {
                "videoInfoRes": {
                    "item_list": [
                        {
                            "aweme_id": video_id,
                            "desc": "无 Cookie 测试",
                            "author": {"nickname": "浪白"},
                            "video": {
                                "width": 1080,
                                "height": 1920,
                                "duration": 18000,
                                "play_addr": {
                                    "url_list": [
                                        "https://media.example/video.mp4?ratio=720p"
                                    ]
                                },
                                "cover": {
                                    "url_list": ["https://media.example/cover.webp"]
                                },
                            },
                        }
                    ]
                }
            }
        }
    }
    html = (
        "<html><script>window._ROUTER_DATA = "
        + json.dumps(router_data)
        + ";</script></html>"
    )

    def fake_get(url, *, headers, **_kwargs):
        assert "cookie" not in {key.lower() for key in headers}
        return httpx.Response(
            200,
            text=html,
            request=httpx.Request("GET", url),
        )

    monkeypatch.setattr("app.services.extractor.httpx.get", fake_get)
    entry = ResolverService(settings)._resolve_douyin_share(
        f"https://www.douyin.com/video/{video_id}"
    )
    assert entry.media.title == "无 Cookie 测试"
    assert entry.media.creator == "浪白"
    assert entry.media.duration_seconds == 18
    assert {option.kind.value for option in entry.media.options} == {"video", "image"}
    assert entry.media.options[0].resolution == "720p"
    assert "不读取或发送 Cookie" in entry.media.warnings[0]
