from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import probe_platform_matrix as probe  # noqa: E402


class PlatformProbeTests(unittest.TestCase):
    def test_required_platforms_have_public_samples(self) -> None:
        samples = {sample.slug: sample for sample in probe.SAMPLES}
        self.assertTrue(
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
            }.issubset(samples)
        )
        for sample in samples.values():
            self.assertTrue(sample.url.startswith("https://"))
            self.assertNotIn("cookie", sample.url.casefold())

    def test_failure_categories_are_distinct(self) -> None:
        cases = {
            "Sign in to continue; use --cookies": "login_required",
            "This video is not available in your country": "geo_restricted",
            "Your IP address is blocked from accessing this post": "access_restricted",
            "This private video has been removed": "not_public",
            "Unsupported URL": "unsupported",
            "none of these impersonate targets are available": "runtime_missing",
            "unexpected extractor response": "failed",
        }
        for message, expected in cases.items():
            with self.subTest(message=message):
                self.assertEqual(probe.classify_failure(message), expected)

    def test_video_sample_is_not_green_for_cover_only_fallback(self) -> None:
        sample = probe.Sample(
            "example",
            "Example",
            "https://example.com/video/1",
            "fixture",
            "https://example.com/source",
        )
        payload = {
            "platform": "Example",
            "title": "Public page",
            "options": [
                {
                    "id": "cover",
                    "kind": "image",
                    "extension": "jpg",
                    "resolution": None,
                }
            ],
            "warnings": ["站点专用解析器不可用，已使用通用网页媒体解析。"],
        }
        with mock.patch.object(probe, "_request_json", return_value=(200, payload)):
            result = probe._probe_one("http://127.0.0.1:8787", sample, 1)
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["result"]["kinds"], ["image"])

    def test_removed_page_fallback_is_not_public(self) -> None:
        sample = probe.Sample(
            "example",
            "Example",
            "https://example.com/video/1",
            "fixture",
            "https://example.com/source",
        )
        payload = {
            "platform": "Example",
            "title": "你访问的页面不见了",
            "options": [{"id": "cover", "kind": "image", "extension": "jpg"}],
            "warnings": [],
        }
        with mock.patch.object(probe, "_request_json", return_value=(200, payload)):
            result = probe._probe_one("http://127.0.0.1:8787", sample, 1)
        self.assertEqual(result["status"], "not_public")


if __name__ == "__main__":
    unittest.main()
