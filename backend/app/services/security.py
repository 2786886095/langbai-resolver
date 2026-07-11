from __future__ import annotations

import asyncio
import ipaddress
import socket
import threading
from contextlib import asynccontextmanager, contextmanager
from dataclasses import dataclass
from typing import Any, AsyncIterator, Callable, Iterator
from urllib.parse import urljoin, urlparse

import httpx


_ORIGINAL_GETADDRINFO = socket.getaddrinfo
_DNS_GUARD_LOCK = threading.RLock()
_DNS_GUARD_ACTIVE = 0
_DNS_GUARD_ALLOW_FAKE = 0


def _guarded_getaddrinfo(*args: Any, **kwargs: Any):
    answers = _ORIGINAL_GETADDRINFO(*args, **kwargs)
    with _DNS_GUARD_LOCK:
        enabled = _DNS_GUARD_ACTIVE > 0
        allow_fake = _DNS_GUARD_ALLOW_FAKE > 0
    if not enabled:
        return answers
    for answer in answers:
        address = ipaddress.ip_address(answer[4][0])
        if not _is_allowed_address(address, allow_fake):
            raise socket.gaierror("blocked non-public address during guarded request")
    return answers


if not getattr(socket.getaddrinfo, "_langbai_guard", False):
    setattr(_guarded_getaddrinfo, "_langbai_guard", True)
    socket.getaddrinfo = _guarded_getaddrinfo


@contextmanager
def guarded_dns_resolution(allow_fake_ip_dns: bool = False) -> Iterator[None]:
    """Apply public-address DNS filtering while a network operation is active."""
    global _DNS_GUARD_ACTIVE, _DNS_GUARD_ALLOW_FAKE
    with _DNS_GUARD_LOCK:
        _DNS_GUARD_ACTIVE += 1
        if allow_fake_ip_dns:
            _DNS_GUARD_ALLOW_FAKE += 1
    try:
        yield
    finally:
        with _DNS_GUARD_LOCK:
            _DNS_GUARD_ACTIVE -= 1
            if allow_fake_ip_dns:
                _DNS_GUARD_ALLOW_FAKE -= 1


class UnsafeUrlError(ValueError):
    """Raised when a URL could reach a local, reserved, or otherwise unsafe host."""


class ResponseTooLargeError(ValueError):
    """Raised before or while reading a response larger than the configured limit."""


@dataclass(frozen=True, slots=True)
class ValidatedTarget:
    url: str
    hostname: str
    addresses: frozenset[ipaddress.IPv4Address | ipaddress.IPv6Address]


def _is_allowed_address(
    address: ipaddress.IPv4Address | ipaddress.IPv6Address,
    allow_fake_ip_dns: bool,
) -> bool:
    if (
        allow_fake_ip_dns
        and isinstance(address, ipaddress.IPv4Address)
        and address in ipaddress.ip_network("198.18.0.0/15")
    ):
        return True
    return address.is_global


def resolve_public_target(
    value: str, allow_fake_ip_dns: bool = False
) -> ValidatedTarget:
    """Resolve a HTTP(S) URL and reject every non-public address returned by DNS."""
    value = value.strip()
    if len(value) > 4096:
        raise UnsafeUrlError("链接过长")

    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"}:
        raise UnsafeUrlError("只支持 http 或 https 链接")
    if not parsed.hostname:
        raise UnsafeUrlError("链接缺少有效域名")
    if parsed.username or parsed.password:
        raise UnsafeUrlError("链接不能包含用户名或密码")

    hostname = parsed.hostname.rstrip(".").lower()
    if hostname in {"localhost", "localhost.localdomain"} or hostname.endswith(
        ".localhost"
    ):
        raise UnsafeUrlError("不允许访问本机地址")

    try:
        answers = socket.getaddrinfo(
            hostname,
            parsed.port or (443 if parsed.scheme == "https" else 80),
            0,
            socket.SOCK_STREAM,
        )
    except socket.gaierror as exc:
        raise UnsafeUrlError("域名无法解析") from exc

    addresses: set[ipaddress.IPv4Address | ipaddress.IPv6Address] = set()
    for answer in answers:
        try:
            address = ipaddress.ip_address(answer[4][0])
        except ValueError as exc:
            raise UnsafeUrlError("域名返回了无效地址") from exc
        if not _is_allowed_address(address, allow_fake_ip_dns):
            raise UnsafeUrlError("不允许访问内网或保留地址")
        addresses.add(address)
    if not addresses:
        raise UnsafeUrlError("域名没有可用的公开地址")
    return ValidatedTarget(value, hostname, frozenset(addresses))


def validate_public_url(value: str, allow_fake_ip_dns: bool = False) -> str:
    """Compatibility wrapper returning the normalized, validated URL."""
    return resolve_public_target(value, allow_fake_ip_dns).url


def _response_peer(
    response: httpx.Response,
) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    stream = response.extensions.get("network_stream")
    if stream is None or not hasattr(stream, "get_extra_info"):
        return None
    for key in ("server_addr", "peername"):
        try:
            value = stream.get_extra_info(key)
        except (OSError, RuntimeError):
            continue
        if isinstance(value, tuple) and value:
            value = value[0]
        if not value:
            continue
        try:
            return ipaddress.ip_address(str(value).split("%", 1)[0])
        except ValueError:
            continue
    return None


def validate_response_peer(
    response: httpx.Response,
    target: ValidatedTarget,
    allow_fake_ip_dns: bool = False,
) -> None:
    """Check the connected peer when the HTTP transport exposes it.

    httpx's production transports expose ``network_stream``. Mock transports do
    not, so unit tests can still provide deterministic responses.
    """
    peer = _response_peer(response)
    if peer is None:
        return
    fake_network = ipaddress.ip_network("198.18.0.0/15")
    if allow_fake_ip_dns and any(
        isinstance(address, ipaddress.IPv4Address) and address in fake_network
        for address in target.addresses
    ):
        # Clash-style fake-IP mode intentionally connects through a local proxy;
        # DNS pinning is delegated to that explicitly enabled local environment.
        return
    if not _is_allowed_address(peer, allow_fake_ip_dns):
        raise UnsafeUrlError("连接被重绑定到内网或保留地址")


def _redirect_target(response: httpx.Response, current: str) -> str | None:
    if response.status_code not in {301, 302, 303, 307, 308}:
        return None
    location = response.headers.get("location")
    return urljoin(current, location) if location else None


def _redirect_headers(
    headers: dict[str, str] | None, old: str, new: str
) -> dict[str, str] | None:
    old_url = urlparse(old)
    new_url = urlparse(new)
    if old_url.scheme.lower() == "https" and new_url.scheme.lower() != "https":
        raise UnsafeUrlError("禁止从 HTTPS 重定向到不安全的 HTTP 地址")
    if not headers:
        return headers

    def origin(parsed) -> tuple[str, str | None, int | None]:
        scheme = parsed.scheme.lower()
        default_port = 443 if scheme == "https" else 80 if scheme == "http" else None
        return scheme, parsed.hostname.lower() if parsed.hostname else None, parsed.port or default_port

    if origin(old_url) == origin(new_url):
        return headers
    # Never forward credentials to another scheme, host, or port.
    blocked = {"authorization", "cookie", "proxy-authorization"}
    return {key: value for key, value in headers.items() if key.lower() not in blocked}


@contextmanager
def stream_public_response(
    client: httpx.Client,
    method: str,
    url: str,
    *,
    allow_fake_ip_dns: bool = False,
    max_redirects: int = 5,
    headers: dict[str, str] | None = None,
    redirect_validator: Callable[[str], None] | None = None,
    **kwargs: Any,
) -> Iterator[httpx.Response]:
    current = url
    current_headers = headers
    response: httpx.Response | None = None
    try:
        for redirect_count in range(max_redirects + 1):
            target = resolve_public_target(current, allow_fake_ip_dns)
            request = client.build_request(
                method, current, headers=current_headers, **kwargs
            )
            with guarded_dns_resolution(allow_fake_ip_dns):
                response = client.send(request, stream=True, follow_redirects=False)
            validate_response_peer(response, target, allow_fake_ip_dns)
            next_url = _redirect_target(response, current)
            if not next_url:
                yield response
                return
            response.close()
            response = None
            if redirect_count >= max_redirects:
                raise UnsafeUrlError("重定向次数过多")
            if redirect_validator:
                redirect_validator(next_url)
            current_headers = _redirect_headers(current_headers, current, next_url)
            current = next_url
        raise UnsafeUrlError("重定向次数过多")
    finally:
        if response is not None:
            response.close()


@asynccontextmanager
async def stream_public_response_async(
    client: httpx.AsyncClient,
    method: str,
    url: str,
    *,
    allow_fake_ip_dns: bool = False,
    max_redirects: int = 5,
    headers: dict[str, str] | None = None,
    redirect_validator: Callable[[str], None] | None = None,
    **kwargs: Any,
) -> AsyncIterator[httpx.Response]:
    current = url
    current_headers = headers
    response: httpx.Response | None = None
    try:
        for redirect_count in range(max_redirects + 1):
            target = await asyncio.to_thread(
                resolve_public_target, current, allow_fake_ip_dns
            )
            request = client.build_request(
                method, current, headers=current_headers, **kwargs
            )
            with guarded_dns_resolution(allow_fake_ip_dns):
                response = await client.send(
                    request, stream=True, follow_redirects=False
                )
            validate_response_peer(response, target, allow_fake_ip_dns)
            next_url = _redirect_target(response, current)
            if not next_url:
                yield response
                return
            await response.aclose()
            response = None
            if redirect_count >= max_redirects:
                raise UnsafeUrlError("重定向次数过多")
            if redirect_validator:
                redirect_validator(next_url)
            current_headers = _redirect_headers(current_headers, current, next_url)
            current = next_url
        raise UnsafeUrlError("重定向次数过多")
    finally:
        if response is not None:
            await response.aclose()


def read_limited(response: httpx.Response, max_bytes: int) -> bytes:
    declared = response.headers.get("content-length")
    if declared:
        try:
            if int(declared) > max_bytes:
                raise ResponseTooLargeError("远程响应超过大小限制")
        except ValueError:
            pass
    chunks: list[bytes] = []
    size = 0
    for chunk in response.iter_bytes(64 * 1024):
        size += len(chunk)
        if size > max_bytes:
            raise ResponseTooLargeError("远程响应超过大小限制")
        chunks.append(chunk)
    return b"".join(chunks)


async def read_limited_async(response: httpx.Response, max_bytes: int) -> bytes:
    declared = response.headers.get("content-length")
    if declared:
        try:
            if int(declared) > max_bytes:
                raise ResponseTooLargeError("远程响应超过大小限制")
        except ValueError:
            pass
    chunks: list[bytes] = []
    size = 0
    async for chunk in response.aiter_bytes(64 * 1024):
        size += len(chunk)
        if size > max_bytes:
            raise ResponseTooLargeError("远程响应超过大小限制")
        chunks.append(chunk)
    return b"".join(chunks)
