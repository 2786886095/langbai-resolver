import socket

import httpx
import pytest

from app.services.security import (
    UnsafeUrlError,
    guarded_dns_resolution,
    stream_public_response,
    validate_public_url,
)


def _dns_result(address: str) -> list[tuple[object, ...]]:
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443))]


def test_allows_clash_fake_ip_only_when_enabled(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args: _dns_result("198.18.3.33"))

    with pytest.raises(UnsafeUrlError):
        validate_public_url("https://v.douyin.com/example")

    assert (
        validate_public_url("https://v.douyin.com/example", allow_fake_ip_dns=True)
        == "https://v.douyin.com/example"
    )


def test_never_allows_real_private_addresses(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        socket, "getaddrinfo", lambda *args: _dns_result("192.168.1.20")
    )

    with pytest.raises(UnsafeUrlError):
        validate_public_url("https://example.com/media", allow_fake_ip_dns=True)


def test_redirect_is_validated_before_following(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[str] = []

    def fake_dns(host: str, *_args):
        address = "127.0.0.1" if host == "internal.test" else "93.184.216.34"
        return _dns_result(address)

    monkeypatch.setattr(socket, "getaddrinfo", fake_dns)

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        return httpx.Response(302, headers={"location": "http://internal.test/secret"})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(UnsafeUrlError):
            with stream_public_response(client, "GET", "https://public.test/start"):
                pass
    assert calls == ["https://public.test/start"]


def test_guarded_dns_blocks_nested_private_resolution(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        "app.services.security._ORIGINAL_GETADDRINFO",
        lambda *_args, **_kwargs: _dns_result("10.0.0.5"),
    )
    with guarded_dns_resolution():
        with pytest.raises(socket.gaierror):
            socket.getaddrinfo("redirected.test", 443)


def test_https_redirect_downgrade_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        socket, "getaddrinfo", lambda *args: _dns_result("93.184.216.34")
    )
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        return httpx.Response(302, headers={"location": "http://public.test/media"})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(UnsafeUrlError, match="HTTPS"):
            with stream_public_response(
                client,
                "GET",
                "https://public.test/start",
                headers={"Authorization": "Bearer secret"},
            ):
                pass
    assert calls == ["https://public.test/start"]


def test_redirect_to_another_port_strips_credentials(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        socket, "getaddrinfo", lambda *args: _dns_result("93.184.216.34")
    )
    calls: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        if len(calls) == 1:
            return httpx.Response(
                302, headers={"location": "https://public.test:8443/media"}
            )
        return httpx.Response(200, content=b"ok")

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with stream_public_response(
            client,
            "GET",
            "https://public.test/start",
            headers={
                "Authorization": "Bearer secret",
                "Cookie": "session=secret",
                "Proxy-Authorization": "Basic secret",
                "User-Agent": "langbai-test",
            },
        ) as response:
            assert response.status_code == 200

    assert len(calls) == 2
    redirected = calls[1].headers
    assert "authorization" not in redirected
    assert "cookie" not in redirected
    assert "proxy-authorization" not in redirected
    assert redirected["user-agent"] == "langbai-test"
