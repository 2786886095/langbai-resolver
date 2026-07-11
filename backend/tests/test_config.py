from __future__ import annotations

import pytest

from app.config import Settings


def test_non_loopback_listener_requires_a_strong_instance_token(monkeypatch) -> None:
    monkeypatch.setenv("MEDIA_HARBOR_HOST", "0.0.0.0")
    monkeypatch.delenv("MEDIA_HARBOR_INSTANCE_TOKEN", raising=False)
    with pytest.raises(ValueError, match="必须配置"):
        Settings.from_env()

    monkeypatch.setenv("MEDIA_HARBOR_INSTANCE_TOKEN", "too-short")
    with pytest.raises(ValueError, match="至少包含 32 字节"):
        Settings.from_env()

    token = "a" * 32
    monkeypatch.setenv("MEDIA_HARBOR_INSTANCE_TOKEN", token)
    configured = Settings.from_env()
    assert configured.host == "0.0.0.0"
    assert configured.instance_token == token


def test_loopback_listener_can_use_process_local_auth(monkeypatch) -> None:
    monkeypatch.setenv("MEDIA_HARBOR_HOST", "127.0.0.1")
    monkeypatch.delenv("MEDIA_HARBOR_INSTANCE_TOKEN", raising=False)
    assert Settings.from_env().instance_token is None


def test_instance_token_must_be_ascii(monkeypatch) -> None:
    monkeypatch.setenv("MEDIA_HARBOR_HOST", "127.0.0.1")
    monkeypatch.setenv("MEDIA_HARBOR_INSTANCE_TOKEN", "密钥" * 16)
    with pytest.raises(ValueError, match="ASCII"):
        Settings.from_env()
