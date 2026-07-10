import importlib

from fastapi.testclient import TestClient

from app.main import app
from app.services.extractor import (
    BrowserCookiesRequiredError,
    browser_cookies_required,
    clean_ytdlp_error,
)


client = TestClient(app)


def test_health() -> None:
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_rejects_localhost() -> None:
    response = client.post(
        "/api/v1/resolve", json={"url": "http://127.0.0.1/private"}
    )
    assert response.status_code == 400


def test_update_manifest_has_all_primary_clients() -> None:
    response = client.get("/api/v1/update")
    assert response.status_code == 200
    payload = response.json()
    assert payload["version"] == "1.0.4"
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


def test_cookie_requirement_returns_actionable_code(monkeypatch) -> None:
    main_module = importlib.import_module("app.main")

    async def requires_cookies(*_args, **_kwargs):
        raise BrowserCookiesRequiredError("抖音需要浏览器 Cookie")

    monkeypatch.setattr(main_module.resolver, "resolve", requires_cookies)
    response = client.post(
        "/api/v1/resolve",
        json={"url": "https://www.douyin.com/video/7658650507234212965"},
    )
    assert response.status_code == 428
    assert response.json()["detail"] == {
        "code": "browser_cookies_required",
        "message": "抖音需要浏览器 Cookie",
    }
