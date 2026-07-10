from __future__ import annotations

import ipaddress
import socket
from urllib.parse import urlparse


class UnsafeUrlError(ValueError):
    pass


def validate_public_url(value: str, allow_fake_ip_dns: bool = False) -> str:
    """Reject local/private targets before handing a URL to an extractor."""
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
        addresses = {
            item[4][0]
            for item in socket.getaddrinfo(hostname, parsed.port or 443)
        }
    except socket.gaierror as exc:
        raise UnsafeUrlError("域名无法解析") from exc

    for address in addresses:
        ip = ipaddress.ip_address(address)
        if allow_fake_ip_dns and ip in ipaddress.ip_network("198.18.0.0/15"):
            continue
        if not ip.is_global:
            raise UnsafeUrlError("不允许访问内网或保留地址")

    return value
