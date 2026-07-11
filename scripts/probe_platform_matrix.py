#!/usr/bin/env python3
"""Run a manual, metadata-only platform probe against langbai's resolver.

This script intentionally calls only ``POST /api/v1/resolve``. It never calls
the download API, supplies account cookies, reads browser profiles, or attempts
to bypass DRM, authentication, age gates, or geographic restrictions.

The probe is deliberately not an all-sites CI gate: public posts disappear and
platform behaviour varies by date, IP region, account state, and yt-dlp version.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.request import Request, urlopen


YT_DLP_TAG = "2026.07.04"
YT_DLP_SOURCE_ROOT = (
    f"https://github.com/yt-dlp/yt-dlp/blob/{YT_DLP_TAG}/yt_dlp/extractor"
)
CORE_PLATFORM_SLUGS = frozenset(
    {
        "douyin",
        "kuaishou",
        "bilibili",
        "youtube",
        "tiktok",
        "instagram",
        "twitter",
        "facebook",
        "vimeo",
        "ixigua",
        "xiaohongshu",
        "weibo",
    }
)


@dataclass(frozen=True, slots=True)
class Sample:
    slug: str
    platform: str
    url: str
    source_label: str
    source_url: str
    expected_kinds: tuple[str, ...] = ("video",)


# With the exception of Kuaishou, these are yt-dlp extractor test URLs. The
# Kuaishou extractor is application-specific, so its sample is a recent public
# national-media post cited by a publicly available China News Service entry.
SAMPLES: tuple[Sample, ...] = (
    Sample(
        "douyin",
        "抖音",
        "https://www.douyin.com/video/6961737553342991651",
        f"yt-dlp {YT_DLP_TAG} DouyinIE test",
        f"{YT_DLP_SOURCE_ROOT}/tiktok.py",
    ),
    Sample(
        "kuaishou",
        "快手",
        "https://v.kuaishou.com/JogJVR8p",
        "中国新闻网公开参评材料中的媒体链接",
        "https://www.chinanews.com.cn/fileftp/2026/05/2026-05-13/"
        "U1106P4T47D56160F29949DT20260513085427.pdf?browser=yes",
    ),
    Sample(
        "bilibili",
        "B站",
        "https://www.bilibili.com/video/BV13x41117TL",
        f"yt-dlp {YT_DLP_TAG} BiliBiliIE test",
        f"{YT_DLP_SOURCE_ROOT}/bilibili.py",
    ),
    Sample(
        "youtube",
        "YouTube",
        "https://www.youtube.com/watch?v=YE7VzlLtp-4",
        f"yt-dlp {YT_DLP_TAG} YoutubeIE test",
        f"{YT_DLP_SOURCE_ROOT}/youtube/_video.py",
    ),
    Sample(
        "tiktok",
        "TikTok",
        "https://www.tiktok.com/@barudakhb_/video/6984138651336838402",
        f"yt-dlp {YT_DLP_TAG} TikTokIE test",
        f"{YT_DLP_SOURCE_ROOT}/tiktok.py",
    ),
    Sample(
        "instagram",
        "Instagram",
        "https://instagram.com/p/aye83DjauH/",
        f"yt-dlp {YT_DLP_TAG} InstagramIE test",
        f"{YT_DLP_SOURCE_ROOT}/instagram.py",
    ),
    Sample(
        "twitter",
        "X / Twitter",
        "https://x.com/TopHeroes_/status/2001950365332455490",
        f"yt-dlp {YT_DLP_TAG} TwitterIE test",
        f"{YT_DLP_SOURCE_ROOT}/twitter.py",
    ),
    Sample(
        "facebook",
        "Facebook",
        "https://www.facebook.com/WatchESLOne/videos/359649331226507/",
        f"yt-dlp {YT_DLP_TAG} FacebookIE test",
        f"{YT_DLP_SOURCE_ROOT}/facebook.py",
    ),
    Sample(
        "vimeo",
        "Vimeo",
        "https://vimeo.com/54469442",
        f"yt-dlp {YT_DLP_TAG} VimeoIE test",
        f"{YT_DLP_SOURCE_ROOT}/vimeo.py",
    ),
    Sample(
        "ixigua",
        "西瓜视频",
        "https://www.ixigua.com/6996881461559165471",
        f"yt-dlp {YT_DLP_TAG} IxiguaIE test",
        f"{YT_DLP_SOURCE_ROOT}/ixigua.py",
    ),
    Sample(
        "xiaohongshu",
        "小红书",
        "https://www.xiaohongshu.com/explore/6411cf99000000001300b6d9",
        f"yt-dlp {YT_DLP_TAG} XiaoHongShuIE test",
        f"{YT_DLP_SOURCE_ROOT}/xiaohongshu.py",
    ),
    Sample(
        "weibo",
        "微博",
        "https://weibo.com/7827771738/N4xlMvjhI",
        f"yt-dlp {YT_DLP_TAG} WeiboIE test",
        f"{YT_DLP_SOURCE_ROOT}/weibo.py",
    ),
    Sample(
        "youku",
        "优酷",
        "https://v.youku.com/v_show/id_XNjA1NzA2Njgw.html",
        f"yt-dlp {YT_DLP_TAG} YoukuIE test",
        f"{YT_DLP_SOURCE_ROOT}/youku.py",
    ),
    Sample(
        "acfun",
        "AcFun",
        "https://www.acfun.cn/v/ac35457073",
        f"yt-dlp {YT_DLP_TAG} AcFunVideoIE test",
        f"{YT_DLP_SOURCE_ROOT}/acfun.py",
    ),
    Sample(
        "dailymotion",
        "Dailymotion",
        "https://www.dailymotion.com/video/x5kesuj",
        f"yt-dlp {YT_DLP_TAG} DailymotionIE test",
        f"{YT_DLP_SOURCE_ROOT}/dailymotion.py",
    ),
    Sample(
        "twitch",
        "Twitch Clips",
        "https://clips.twitch.tv/FaintLightGullWholeWheat",
        f"yt-dlp {YT_DLP_TAG} TwitchClipsIE test",
        f"{YT_DLP_SOURCE_ROOT}/twitch.py",
    ),
    Sample(
        "reddit",
        "Reddit",
        "https://www.reddit.com/r/videos/comments/6rrwyj/that_small_heart_attack/",
        f"yt-dlp {YT_DLP_TAG} RedditIE test",
        f"{YT_DLP_SOURCE_ROOT}/reddit.py",
    ),
)


STATUS_LABELS = {
    "success": "成功",
    "partial": "仅部分元数据",
    "login_required": "需要登录",
    "geo_restricted": "地区限制",
    "access_restricted": "IP/访问限制",
    "not_public": "站点/内容未公开",
    "unsupported": "当前不支持",
    "runtime_missing": "缺少运行依赖",
    "timeout": "超时",
    "failed": "失败",
}

LOGIN_MARKERS = (
    "login required",
    "log in",
    "sign in",
    "sign-in",
    "authentication required",
    "account is required",
    "confirm you're not a bot",
    "confirm you’re not a bot",
    "use --cookies",
    "cookies are needed",
    "cookies required",
    "cookie is needed",
    "需要登录",
    "请先登录",
    "登录 cookie",
    "登录凭证",
)
GEO_MARKERS = (
    "geo-restricted",
    "geo restricted",
    "not available in your country",
    "not available in your region",
    "not available from your location",
    "blocked in your country",
    "country restriction",
    "region restriction",
    "地区限制",
    "当前地区",
    "所在地区",
)
ACCESS_MARKERS = (
    "ip address is blocked",
    "ip has been blocked",
    "access denied",
    "request blocked",
    "访问被拒绝",
    "ip 被封禁",
    "ip已被封禁",
)
NOT_PUBLIC_MARKERS = (
    "private video",
    "private account",
    "this account is private",
    "has been removed",
    "no longer available",
    "video unavailable",
    "content isn't available",
    "content is not available",
    "does not exist",
    "page not found",
    "http error 404",
    "status code 404",
    "作品不存在",
    "内容不存在",
    "视频不存在",
    "已删除",
    "私密",
    "未公开",
    "页面不见了",
)
UNSUPPORTED_MARKERS = (
    "unsupported url",
    "no suitable extractor",
    "is not a valid url",
    "不支持的链接",
    "暂不支持",
)
RUNTIME_MISSING_MARKERS = (
    "none of these impersonate targets are available",
    "installing the required dependencies",
    "required dependency is not installed",
    "missing optional dependency",
    "缺少运行依赖",
)


def _redact(text: object, limit: int = 500) -> str:
    value = str(text or "").replace("\r", " ").replace("\n", " ").strip()
    value = re.sub(r"(https?://[^\s?]+)\?[^\s]+", r"\1?<redacted>", value)
    value = re.sub(
        r"(?i)\b(cookie|authorization|token|session|sessdata)\s*[=:]\s*[^\s,;]+",
        r"\1=<redacted>",
        value,
    )
    value = re.sub(r"\s+", " ", value)
    return value[:limit]


def classify_failure(message: str, *, timed_out: bool = False) -> str:
    if timed_out:
        return "timeout"
    lowered = message.casefold()
    if any(marker in lowered for marker in LOGIN_MARKERS):
        return "login_required"
    if any(marker in lowered for marker in GEO_MARKERS):
        return "geo_restricted"
    if any(marker in lowered for marker in ACCESS_MARKERS):
        return "access_restricted"
    if any(marker in lowered for marker in NOT_PUBLIC_MARKERS):
        return "not_public"
    if any(marker in lowered for marker in UNSUPPORTED_MARKERS):
        return "unsupported"
    if any(marker in lowered for marker in RUNTIME_MISSING_MARKERS):
        return "runtime_missing"
    return "failed"


def _request_json(
    url: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    timeout: float,
) -> tuple[int, dict[str, Any]]:
    body = None
    headers = {
        "Accept": "application/json",
        "User-Agent": "langbai-platform-matrix/1.1.0 (metadata-only; no cookies)",
    }
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = Request(url, data=body, headers=headers, method=method)
    try:
        with urlopen(request, timeout=timeout) as response:
            status = response.status
            raw = response.read(2 * 1024 * 1024)
    except HTTPError as error:
        status = error.code
        raw = error.read(2 * 1024 * 1024)
    decoded = raw.decode("utf-8", errors="replace")
    try:
        parsed = json.loads(decoded)
    except json.JSONDecodeError:
        parsed = {"detail": _redact(decoded or f"HTTP {status}")}
    if not isinstance(parsed, dict):
        parsed = {"detail": _redact(parsed)}
    return status, parsed


def _probe_one(base_url: str, sample: Sample, timeout: float) -> dict[str, Any]:
    started = time.monotonic()
    record: dict[str, Any] = {
        **asdict(sample),
        "source": {"label": sample.source_label, "url": sample.source_url},
    }
    record.pop("source_label", None)
    record.pop("source_url", None)
    try:
        status_code, payload = _request_json(
            urljoin(base_url.rstrip("/") + "/", "api/v1/resolve"),
            method="POST",
            payload={"url": sample.url},
            timeout=timeout,
        )
        record["http_status"] = status_code
        if status_code != 200:
            detail = _redact(payload.get("detail") or f"HTTP {status_code}")
            status = classify_failure(detail)
            record.update(
                status=status,
                status_zh=STATUS_LABELS[status],
                summary=detail,
            )
            return record

        options = payload.get("options")
        if not isinstance(options, list):
            options = []
        valid_options = [option for option in options if isinstance(option, dict)]
        kinds = sorted(
            {
                str(option.get("kind"))
                for option in valid_options
                if option.get("kind") in {"video", "audio", "image"}
            }
        )
        expected = set(sample.expected_kinds)
        found = set(kinds)
        warnings = payload.get("warnings")
        if not isinstance(warnings, list):
            warnings = []
        status = "success" if expected.issubset(found) else "partial"
        page_detail = ""
        if status == "partial":
            page_detail = " ".join(
                (
                    str(payload.get("title") or ""),
                    *(str(item) for item in warnings),
                )
            )
            classified = classify_failure(page_detail)
            if classified != "failed":
                status = classified
        result = {
            "reported_platform": _redact(payload.get("platform"), 80),
            "title": _redact(payload.get("title"), 160),
            "option_count": len(valid_options),
            "kinds": kinds,
            "extensions": sorted(
                {
                    str(option.get("extension"))
                    for option in valid_options
                    if option.get("extension")
                }
            ),
            "resolutions": sorted(
                {
                    str(option.get("resolution"))
                    for option in valid_options
                    if option.get("resolution")
                }
            )[:12],
            "has_thumbnail": bool(payload.get("thumbnail_url")),
            "warnings": [_redact(item, 300) for item in warnings[:5]],
        }
        if status == "success":
            summary = f"返回 {len(valid_options)} 个候选项：{', '.join(kinds)}"
        elif status == "partial":
            summary = (
                f"接口返回元数据，但缺少期望类型：{', '.join(sample.expected_kinds)}"
            )
        else:
            summary = _redact(page_detail)
        record.update(
            status=status,
            status_zh=STATUS_LABELS[status],
            summary=summary,
            result=result,
        )
        return record
    except (TimeoutError, socket.timeout) as error:
        detail = _redact(error) or f"超过 {timeout:g} 秒"
        status = classify_failure(detail, timed_out=True)
        record.update(
            status=status,
            status_zh=STATUS_LABELS[status],
            summary=detail,
            http_status=None,
        )
        return record
    except (URLError, OSError, ValueError) as error:
        detail = _redact(getattr(error, "reason", error))
        status = classify_failure(detail)
        record.update(
            status=status,
            status_zh=STATUS_LABELS[status],
            summary=detail,
            http_status=None,
        )
        return record
    finally:
        record["elapsed_seconds"] = round(time.monotonic() - started, 2)


def _free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _wait_for_health(base_url: str, process: subprocess.Popen[bytes]) -> dict[str, Any]:
    health_url = urljoin(base_url.rstrip("/") + "/", "api/v1/health")
    deadline = time.monotonic() + 40
    last_error = "backend did not start"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"local backend exited with code {process.returncode}")
        try:
            status, payload = _request_json(health_url, timeout=2)
            if status == 200:
                return payload
            last_error = f"health endpoint returned HTTP {status}"
        except (URLError, TimeoutError, OSError) as error:
            last_error = _redact(getattr(error, "reason", error))
        time.sleep(0.2)
    raise RuntimeError(f"local backend health check timed out: {last_error}")


@contextlib.contextmanager
def local_backend(
    python: Path, *, allow_fake_ip_dns: bool
) -> Iterator[tuple[str, dict[str, Any]]]:
    repo_root = Path(__file__).resolve().parents[1]
    backend_root = repo_root / "backend"
    if not (backend_root / "app" / "main.py").is_file():
        raise RuntimeError(f"backend not found under {backend_root}")
    port = _free_loopback_port()
    base_url = f"http://127.0.0.1:{port}"
    env = os.environ.copy()
    env.update(
        MEDIA_HARBOR_HOST="127.0.0.1",
        MEDIA_HARBOR_PORT=str(port),
        MEDIA_HARBOR_ALLOW_FAKE_IP_DNS="true" if allow_fake_ip_dns else "false",
        PYTHONUNBUFFERED="1",
    )
    creationflags = 0
    if os.name == "nt":
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    process = subprocess.Popen(
        [
            str(python),
            "-m",
            "uvicorn",
            "app.main:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--log-level",
            "warning",
        ],
        cwd=backend_root,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=creationflags,
    )
    try:
        yield base_url, _wait_for_health(base_url, process)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def _health_for_remote(base_url: str) -> dict[str, Any]:
    status, payload = _request_json(
        urljoin(base_url.rstrip("/") + "/", "api/v1/health"), timeout=10
    )
    if status != 200:
        raise RuntimeError(f"backend health endpoint returned HTTP {status}")
    return payload


def run_probe(
    base_url: str,
    health: dict[str, Any],
    samples: tuple[Sample, ...],
    *,
    timeout: float,
    workers: int,
    allow_fake_ip_dns: bool | None,
) -> dict[str, Any]:
    records_by_slug: dict[str, dict[str, Any]] = {}
    with ThreadPoolExecutor(
        max_workers=workers, thread_name_prefix="platform-probe"
    ) as pool:
        futures = {
            pool.submit(_probe_one, base_url, sample, timeout): sample
            for sample in samples
        }
        for future in as_completed(futures):
            record = future.result()
            records_by_slug[record["slug"]] = record
            print(
                f"[{record['status_zh']}] {record['platform']}: "
                f"{record['summary']} ({record['elapsed_seconds']:.2f}s)",
                flush=True,
            )
    records = [records_by_slug[sample.slug] for sample in samples]
    counts = {key: 0 for key in STATUS_LABELS}
    for record in records:
        counts[record["status"]] += 1
    return {
        "schema_version": 1,
        "release_candidate": "1.1.0",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "probe_mode": "POST /api/v1/resolve metadata only; no download; no cookies",
        "base_url": base_url,
        "health": health,
        "network": {"allow_fake_ip_dns": allow_fake_ip_dns},
        "sample_count": len(records),
        "summary": counts,
        "results": records,
        "limitations": [
            "每个平台只使用一个公开样例，不能代表该平台的所有页面类型。",
            "成功仅表示解析接口返回期望媒体候选项；本探针不下载媒体字节。",
            "本矩阵验证 FastAPI 后端，不覆盖 Android/iOS 安装包内的本机解析引擎。",
            "不读取或上传浏览器 Cookie，不绕过登录、年龄、地区、付费、私密或 DRM 限制。",
            "结果受执行日期、出口地区、平台风控、样例存续和 yt-dlp 版本影响。",
            "平台规则会变化，本报告不是“所有平台永久可用”的承诺。",
        ],
    }


def _markdown_cell(value: object) -> str:
    return _redact(value, 500).replace("|", "\\|")


def render_markdown(report: dict[str, Any]) -> str:
    counts = report["summary"]
    nonzero_counts = [
        f"{STATUS_LABELS[key]} {value}" for key, value in counts.items() if value
    ]
    lines = [
        "# langbai解析 1.1.0 主流平台真实解析矩阵",
        "",
        f"报告更新时间（UTC）：`{report['generated_at_utc']}`  ",
        f"解析引擎：`{_markdown_cell(report['health'].get('extractor', 'unknown'))}`  ",
        f"结果汇总：{'；'.join(nonzero_counts)}",
        "",
        "## 探针边界",
        "",
        "本次只调用 `POST /api/v1/resolve` 获取元数据和候选格式，不调用下载接口，"
        "不读取浏览器 Cookie，也不绕过登录、地区、年龄、付费、私密或 DRM 限制。"
        "“成功”表示返回了样例期望的视频候选项，不表示已下载并逐字节验证媒体文件。",
        "",
        "该脚本是人工发布审计，不是强制 CI 门禁。失败可能来自平台限制或公开样例失效，"
        "不应通过降低安全边界来让矩阵变绿。",
        "",
        "## 当前矩阵",
        "",
        "| 平台 | 结果 | 候选类型/数量 | 耗时 | 公开样例与来源 | 摘要 |",
        "| --- | --- | --- | ---: | --- | --- |",
    ]
    if report.get("last_rerun"):
        rerun = report["last_rerun"]
        rerun_platforms = "、".join(rerun.get("platforms") or [])
        lines[5:5] = [
            "",
            f"增量复测：`{rerun.get('generated_at_utc', '')}` 更新 {rerun_platforms}；"
            "其余平台沿用同一日期的完整串行探针结果。",
            "",
        ]
    if report["network"].get("allow_fake_ip_dns"):
        lines[lines.index("## 当前矩阵") : lines.index("## 当前矩阵")] = [
            "本次执行环境使用 `198.18.0.0/15` 合成 DNS，因此临时启用了项目已有的 "
            "`MEDIA_HARBOR_ALLOW_FAKE_IP_DNS` 兼容开关；普通公网 DNS 环境不应启用。",
            "",
        ]
    for result in report["results"]:
        details = result.get("result") or {}
        kinds = ", ".join(details.get("kinds") or []) or "—"
        option_count = details.get("option_count", 0)
        sample_link = f"[样例]({result['url']})"
        source = result["source"]
        source_link = f'[来源]({source["url"]} "{_markdown_cell(source["label"])}")'
        lines.append(
            "| "
            + " | ".join(
                (
                    _markdown_cell(result["platform"]),
                    _markdown_cell(result["status_zh"]),
                    f"{_markdown_cell(kinds)} / {option_count}",
                    f"{result['elapsed_seconds']:.2f}s",
                    f"{sample_link} · {source_link}",
                    _markdown_cell(result["summary"]),
                )
            )
            + " |"
        )
    core_results = [
        result for result in report["results"] if result["slug"] in CORE_PLATFORM_SLUGS
    ]
    core_successes = [
        result["platform"] for result in core_results if result["status"] == "success"
    ]
    core_limits = [
        f"{result['platform']}（{result['status_zh']}）"
        for result in core_results
        if result["status"] != "success"
    ]
    extended_results = [
        result
        for result in report["results"]
        if result["slug"] not in CORE_PLATFORM_SLUGS
    ]
    extended_successes = [
        result["platform"]
        for result in extended_results
        if result["status"] == "success"
    ]
    extended_limits = [
        f"{result['platform']}（{result['status_zh']}）"
        for result in extended_results
        if result["status"] != "success"
    ]
    lines.extend(
        (
            "",
            "## 本次结论",
            "",
            f"- 点名的 {len(core_results)} 个核心平台中，{len(core_successes)} 个样例成功："
            f"{'、'.join(core_successes)}。",
            f"- 未成功项：{'、'.join(core_limits) or '无'}；具体原因以矩阵摘要为准，"
            "不会用浏览器 Cookie 或绕过访问控制来强行通过。",
            f"- 扩展样例成功：{'、'.join(extended_successes) or '无'}；"
            f"未成功：{'、'.join(extended_limits) or '无'}。扩展结果用于暴露兼容性缺口，"
            "同样不代表整个站点。",
        )
    )
    local_flags = "--start-local-backend --workers 1"
    if report["network"].get("allow_fake_ip_dns"):
        local_flags += " --allow-fake-ip-dns"
    lines.extend(
        (
            "",
            "## 如何复测",
            "",
            "在仓库根目录执行：",
            "",
            "```powershell",
            ".\\.venv\\Scripts\\python.exe scripts\\probe_platform_matrix.py `",
            f"  {local_flags} `",
            "  --json-out audit\\YYYY-MM-DD\\platform-matrix-v1.1.0.json `",
            "  --markdown-out audit\\YYYY-MM-DD\\platform-matrix-v1.1.0.md",
            "```",
            "",
            "单独复测某个平台可追加 `--platform youtube`；用 `--list` 查看可选名称。"
            "探针中出现失败状态不会改变进程退出码，避免把外部站点波动当成代码 CI 失败。",
            "",
            "## 明确限制",
            "",
        )
    )
    lines.extend(f"- {item}" for item in report["limitations"])
    lines.append("")
    return "\n".join(lines)


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:8787",
        help="running langbai backend (default: %(default)s)",
    )
    parser.add_argument(
        "--start-local-backend",
        action="store_true",
        help="start and stop a temporary loopback backend for this probe",
    )
    parser.add_argument(
        "--python",
        type=Path,
        default=Path(sys.executable),
        help="Python used to start the local backend (default: current interpreter)",
    )
    parser.add_argument(
        "--allow-fake-ip-dns",
        action="store_true",
        help=(
            "allow the 198.18.0.0/15 synthetic DNS range in a temporary backend; "
            "use only when the host resolver intentionally returns fake IPs"
        ),
    )
    parser.add_argument(
        "--platform",
        action="append",
        default=[],
        help="probe only this slug; repeat for multiple platforms",
    )
    parser.add_argument("--timeout", type=float, default=135.0)
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=1)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    parser.add_argument("--list", action="store_true", help="list platform slugs")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.list:
        for sample in SAMPLES:
            print(f"{sample.slug:14} {sample.platform}")
        return 0
    selected = set(args.platform)
    known = {sample.slug for sample in SAMPLES}
    unknown = selected - known
    if unknown:
        raise SystemExit(f"unknown platform slug(s): {', '.join(sorted(unknown))}")
    samples = tuple(
        sample for sample in SAMPLES if not selected or sample.slug in selected
    )

    def execute(base_url: str, health: dict[str, Any]) -> dict[str, Any]:
        return run_probe(
            base_url,
            health,
            samples,
            timeout=args.timeout,
            workers=args.workers,
            allow_fake_ip_dns=(
                args.allow_fake_ip_dns if args.start_local_backend else None
            ),
        )

    if args.start_local_backend:
        with local_backend(
            args.python.resolve(), allow_fake_ip_dns=args.allow_fake_ip_dns
        ) as (base_url, health):
            report = execute(base_url, health)
    else:
        base_url = args.base_url.rstrip("/")
        report = execute(base_url, _health_for_remote(base_url))

    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.json_out:
        _write_text(args.json_out, encoded)
    if args.markdown_out:
        _write_text(args.markdown_out, render_markdown(report))
    if not args.json_out and not args.markdown_out:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
