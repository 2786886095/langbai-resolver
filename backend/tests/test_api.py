import asyncio
import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app
from app.services.extractor import (
    ResolverService,
    SafeYoutubeDL,
    _clean_bilibili_cookie,
    _select_douyin_play_urls,
    browser_cookies_required,
    clean_ytdlp_error,
    extract_http_url,
    temporary_bilibili_cookie_file,
)


client = TestClient(
    app,
    base_url="http://127.0.0.1:8787",
    client=("127.0.0.1", 50000),
)
DOUYIN_SHARE_TEXT = (
    "3.05 复制打开抖音，看看【樱梨梨的作品】他们走不了了 "
    "# 瓦是大明星 # 瓦赛来了 # 暮... "
    "https://v.douyin.com/9AgsTehs2gM/ C@H.Vl :1pm 10/02 Agb:/"
)
KUAISHOU_SHARE_TEXT = (
    "https://v.kuaishou.com/Jn5E7UbF 一块肉做5个菜！"
    '"生活就是要吃好喝好没有烦恼 "牛肋条 "深夜放毒'
)


def test_health() -> None:
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert response.json()["instance_id"]


def test_instance_token_guards_every_api_route() -> None:
    old_token = settings.instance_token
    old_instance_id = settings.instance_id
    object.__setattr__(settings, "instance_token", "test-instance-secret")
    object.__setattr__(settings, "instance_id", "test-instance")
    try:
        denied = client.get("/api/v1/health")
        assert denied.status_code == 401
        assert denied.json()["error_code"] == "invalid_instance_token"

        allowed = client.get(
            "/api/v1/health",
            headers={"X-Langbai-Instance-Token": "test-instance-secret"},
        )
        assert allowed.status_code == 200
        payload = allowed.json()
        assert payload["instance_id"] == "test-instance"
        assert payload["authenticated"] is True
        assert "token_hash" not in payload
        assert "test-instance-secret" not in allowed.text

        preflight = client.options(
            "/api/v1/jobs/example",
            headers={
                "Origin": "http://localhost:8787",
                "Access-Control-Request-Method": "DELETE",
                "Access-Control-Request-Headers": "X-Langbai-Instance-Token",
            },
        )
        assert preflight.status_code == 200
        assert "DELETE" in preflight.headers["access-control-allow-methods"]
    finally:
        object.__setattr__(settings, "instance_token", old_token)
        object.__setattr__(settings, "instance_id", old_instance_id)


def test_empty_token_is_never_accepted_over_a_non_loopback_connection() -> None:
    old_token = settings.instance_token
    object.__setattr__(settings, "instance_token", None)
    try:
        remote_client = TestClient(
            app,
            base_url="http://192.0.2.10:8787",
            client=("127.0.0.1", 50000),
        )
        denied = remote_client.get("/api/v1/health")
        assert denied.status_code == 401
        assert denied.json()["error_code"] == "instance_token_required"
    finally:
        object.__setattr__(settings, "instance_token", old_token)


def test_empty_token_rejects_cross_site_simple_requests_on_loopback() -> None:
    old_token = settings.instance_token
    object.__setattr__(settings, "instance_token", None)
    try:
        denied = client.post(
            "/api/v1/tools/process",
            headers={"Origin": "https://evil.example"},
            content=b"cross-site multipart body",
        )
        assert denied.status_code == 403
        assert denied.json()["error_code"] == "cross_origin_request_denied"
    finally:
        object.__setattr__(settings, "instance_token", old_token)


def test_rejects_localhost() -> None:
    response = client.post("/api/v1/resolve", json={"url": "http://127.0.0.1/private"})
    assert response.status_code == 400


def test_extracts_url_from_complete_douyin_share_text() -> None:
    assert extract_http_url(DOUYIN_SHARE_TEXT) == ("https://v.douyin.com/9AgsTehs2gM/")


def test_extracts_url_from_complete_kuaishou_share_text() -> None:
    assert extract_http_url(KUAISHOU_SHARE_TEXT) == ("https://v.kuaishou.com/Jn5E7UbF")


def test_resolver_reuses_fresh_source_result(monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.extractor.validate_public_url",
        lambda value, _allow_fake_ip_dns: value,
    )
    resolver = ResolverService(settings)

    async def scenario() -> None:
        first = await resolver.resolve("https://media.example/video.mp4")
        second = await resolver.resolve("https://media.example/video.mp4")
        assert second is first
        assert second.media_id == first.media_id

    try:
        asyncio.run(scenario())
    finally:
        resolver.shutdown()


def test_bilibili_cookie_is_scoped_and_written_for_ytdlp() -> None:
    cleaned = _clean_bilibili_cookie(
        "SESSDATA=session%2Cvalue; bili_jct=csrf; evil=ignored\r\nInjected=yes",
        "https://www.bilibili.com/video/BV1xx411c7mD",
    )
    assert cleaned is None

    cleaned = _clean_bilibili_cookie(
        "SESSDATA=session%2Cvalue; bili_jct=csrf; evil=ignored",
        "https://www.bilibili.com/video/BV1xx411c7mD",
    )
    assert cleaned == "SESSDATA=session%2Cvalue; bili_jct=csrf"
    assert _clean_bilibili_cookie(cleaned, "https://example.com/video") is None
    with temporary_bilibili_cookie_file(cleaned) as cookie_file:
        assert cookie_file is not None
        contents = Path(cookie_file).read_text(encoding="utf-8")
        assert "# Netscape HTTP Cookie File" in contents
        assert "\tSESSDATA\tsession%2Cvalue" in contents
        assert "evil" not in contents
    assert not Path(cookie_file).exists()


def test_update_manifest_has_all_primary_clients() -> None:
    response = client.get("/api/v1/update")
    assert response.status_code == 200
    payload = response.json()
    assert payload["version"] == "1.1.2"
    assert {"windows", "android", "ios", "web"}.issubset(payload["platforms"])
    assert "size_bytes" in payload["platforms"]["windows"]
    assert "signing_certificate_sha256" in payload["platforms"]["windows"]


def test_rejects_declared_oversized_upload_before_multipart_parsing() -> None:
    old_limit = settings.max_upload_bytes
    object.__setattr__(settings, "max_upload_bytes", 1024)
    try:
        response = client.post(
            "/api/v1/tools/process",
            content=b"x" * (2 * 1024 * 1024),
        )
        assert response.status_code == 413
        assert response.json()["error_code"] == "upload_too_large"
    finally:
        object.__setattr__(settings, "max_upload_bytes", old_limit)


def test_cleans_douyin_terminal_error() -> None:
    raw = (
        "ERROR: \x1b[0;31mERROR:\x1b[0m [Douyin] 7658650507234212965: "
        "Fresh cookies (not necessarily logged in) are needed"
    )
    cleaned = clean_ytdlp_error(raw)
    assert "\x1b" not in cleaned
    assert cleaned.startswith("[Douyin]")
    assert browser_cookies_required(cleaned)
    assert browser_cookies_required(
        "[Ixigua] Cookies (not necessarily logged in) are needed"
    )
    assert browser_cookies_required(
        "[youtube] Sign in to confirm you’re not a bot. "
        "Use --cookies-from-browser or --cookies"
    )


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

    monkeypatch.setattr(
        ResolverService,
        "_fetch_douyin_page",
        lambda _service, request_url: (request_url, html),
    )
    entry = ResolverService(settings)._resolve_douyin_share(
        f"https://www.douyin.com/video/{video_id}"
    )
    assert entry.media.title == "无 Cookie 测试"
    assert entry.media.creator == "浪白"
    assert entry.media.duration_seconds == 18
    assert {option.kind.value for option in entry.media.options} == {"video", "image"}
    assert entry.media.options[0].resolution == "720p"
    assert entry.media.options[1].preview_url == "https://media.example/cover.webp"
    assert "不读取或上传你的登录 Cookie" in entry.media.warnings[0]


def test_douyin_playwm_is_normalized_to_public_clean_endpoint() -> None:
    clean, fallbacks = _select_douyin_play_urls(
        {
            "uri": "v0200fg10000exampletoken",
            "url_list": [
                "https://aweme.snssdk.com/aweme/v1/playwm/"
                "?video_id=v0200fg10000exampletoken&ratio=720p&line=0"
                "&logo_name=aweme"
            ],
        }
    )
    assert clean == (
        "https://aweme.snssdk.com/aweme/v1/play/"
        "?video_id=v0200fg10000exampletoken&ratio=720p&line=0"
    )
    assert len(fallbacks) == 1
    assert "/playwm/" in fallbacks[0]


def test_douyin_playwm_on_untrusted_host_is_not_rewritten() -> None:
    original = (
        "https://media.example/aweme/v1/playwm/"
        "?video_id=v0200fg10000exampletoken&ratio=720p"
    )
    selected, fallbacks = _select_douyin_play_urls({"url_list": [original]})
    assert selected == original
    assert fallbacks == ()


def test_douyin_image_post_only_returns_real_images(monkeypatch) -> None:
    video_id = "7658650507234212965"
    router_data = {
        "loaderData": {
            "note_(id)/page": {
                "videoInfoRes": {
                    "item_list": [
                        {
                            "aweme_id": video_id,
                            "desc": "纯图片作品",
                            "author": {"nickname": "浪白"},
                            "video": {},
                            "images": [
                                {"url_list": ["https://media.example/1.webp"]},
                                {"url_list": ["https://media.example/2.webp"]},
                            ],
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
    monkeypatch.setattr(
        ResolverService,
        "_fetch_douyin_page",
        lambda _service, request_url: (request_url, html),
    )
    entry = ResolverService(settings)._resolve_douyin_share(
        f"https://www.douyin.com/note/{video_id}"
    )
    assert {option.kind.value for option in entry.media.options} == {"image"}
    assert [option.preview_url for option in entry.media.options] == [
        "https://media.example/1.webp",
        "https://media.example/2.webp",
    ]


def test_kuaishou_share_parser_uses_embedded_public_media(monkeypatch) -> None:
    state = {
        "opaque-state-key": {
            "photo": {
                "photoId": "5222205432139870253",
                "photoType": "VIDEO",
                "caption": "一块肉做5个菜！",
                "userName": "魔鬼厨房",
                "duration": 210730,
                "width": 1280,
                "height": 720,
                "mainMvUrls": [{"url": "https://media.example/kuaishou-video.mp4"}],
                "coverUrls": [{"url": "https://media.example/kuaishou-cover.jpg"}],
            }
        }
    }
    html = (
        "<html><script>window.INIT_STATE = "
        + json.dumps(state, ensure_ascii=False)
        + ";</script></html>"
    )

    monkeypatch.setattr(
        ResolverService,
        "_fetch_kuaishou_page",
        lambda _service, _url: (
            "https://v.m.chenzhongtech.com/fw/long-video/example",
            html,
        ),
    )
    entry = ResolverService(settings)._resolve_kuaishou_share(
        "https://v.kuaishou.com/Jn5E7UbF"
    )
    assert entry.media.platform == "Kuaishou"
    assert entry.media.title == "一块肉做5个菜！"
    assert entry.media.creator == "魔鬼厨房"
    assert entry.media.duration_seconds == 210
    assert {option.kind.value for option in entry.media.options} == {"video", "image"}
    assert entry.media.options[0].resolution == "1280x720"
    assert entry.media.options[1].preview_url == (
        "https://media.example/kuaishou-cover.jpg"
    )
    assert "不读取或上传你的登录 Cookie" in entry.media.warnings[0]


def test_ytdlp_missing_codec_metadata_keeps_dimensioned_video(monkeypatch) -> None:
    info = {
        "id": "clip-1",
        "title": "公开视频片段",
        "webpage_url": "https://clips.example/watch/clip-1",
        "extractor_key": "ExampleClips",
        "ext": "mp4",
        "url": "https://media.example/clip.mp4",
        "formats": [
            {
                "format_id": "1080",
                "url": "https://media.example/clip.mp4",
                "ext": "mp4",
                "protocol": "https",
                "height": 1080,
                "vcodec": None,
                "acodec": None,
            }
        ],
    }
    monkeypatch.setattr(
        SafeYoutubeDL,
        "extract_info",
        lambda _ydl, _url, download=False: info,
    )

    entry = ResolverService(settings)._resolve_with_ytdlp(
        "https://clips.example/watch/clip-1"
    )
    options = {option.id: option for option in entry.media.options}

    assert options["video:1080"].kind.value == "video"
    assert options["video:1080"].resolution == "1080p"
    assert options["video:1080"].requires_merge is False
    assert "audio:best" not in options
    assert {"audio:mp3:320", "audio:m4a:256"}.issubset(options)


def test_ytdlp_unknown_video_codec_merges_explicit_audio_track(monkeypatch) -> None:
    info = {
        "id": "split-1",
        "title": "分离音视频",
        "webpage_url": "https://media.example/watch/split-1",
        "extractor_key": "ExampleSplit",
        "formats": [
            {
                "format_id": "video-1080",
                "url": "https://media.example/video.mp4",
                "ext": "mp4",
                "height": 1080,
                "vcodec": None,
                "acodec": None,
            },
            {
                "format_id": "audio-aac",
                "url": "https://media.example/audio.m4a",
                "ext": "m4a",
                "vcodec": "none",
                "acodec": "aac",
                "abr": 128,
            },
        ],
    }
    monkeypatch.setattr(
        SafeYoutubeDL,
        "extract_info",
        lambda _ydl, _url, download=False: info,
    )

    entry = ResolverService(settings)._resolve_with_ytdlp(
        "https://media.example/watch/split-1"
    )
    options = {option.id: option for option in entry.media.options}
    video = options["video:video-1080"]
    spec = entry.specs[video.id]

    assert video.requires_merge is True
    assert "bestaudio" in (spec.selector or "")
    assert "audio:best" in options
