import socket

import pytest

from app.services.security import UnsafeUrlError, validate_public_url


def _dns_result(address: str) -> list[tuple[object, ...]]:
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443))]


def test_allows_clash_fake_ip_only_when_enabled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args: _dns_result("198.18.3.33"))

    with pytest.raises(UnsafeUrlError):
        validate_public_url("https://v.douyin.com/example")

    assert (
        validate_public_url("https://v.douyin.com/example", allow_fake_ip_dns=True)
        == "https://v.douyin.com/example"
    )


def test_never_allows_real_private_addresses(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args: _dns_result("192.168.1.20"))

    with pytest.raises(UnsafeUrlError):
        validate_public_url("https://example.com/media", allow_fake_ip_dns=True)
