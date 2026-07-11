import sys
import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1] / "Runner" / "app"
sys.path.insert(0, str(APP_DIR))

from media_url_utils import (
    is_obvious_text_media_error,
    normalize_douyin_play_url,
    should_expose_douyin_video,
)


class MediaUrlUtilsTests(unittest.TestCase):
    def test_normalizes_watermark_endpoint_and_preserves_query(self):
        self.assertEqual(
            normalize_douyin_play_url(
                "https://v3-dy.example/aweme/v1/playwm/?video_id=abc&ratio=720p"
            ),
            "https://v3-dy.example/aweme/v1/play/?video_id=abc&ratio=720p",
        )

    def test_image_post_never_exposes_placeholder_video(self):
        self.assertFalse(
            should_expose_douyin_video("https://example.test/video.mp4", 3)
        )
        self.assertTrue(
            should_expose_douyin_video("https://example.test/video.mp4", 0)
        )

    def test_detects_text_soft_errors_without_guessing_binary_payloads(self):
        html = b"  <!doctype html><title>blocked</title>"
        self.assertTrue(is_obvious_text_media_error("text/html; charset=utf-8", html))
        self.assertTrue(
            is_obvious_text_media_error("application/problem+json", b'{"error":1}')
        )
        self.assertTrue(
            is_obvious_text_media_error(
                "application/vnd.apple.mpegurl", b"#EXTM3U\n#EXT-X-VERSION:3"
            )
        )
        self.assertTrue(is_obvious_text_media_error("text/plain", b"access denied"))
        self.assertTrue(is_obvious_text_media_error("application/octet-stream", html))
        self.assertTrue(is_obvious_text_media_error("video/mp4", html))
        self.assertTrue(is_obvious_text_media_error(None, b'{"error":1}'))
        self.assertFalse(
            is_obvious_text_media_error(
                "application/octet-stream", b"\x00\x00\x00\x18ftyp"
            )
        )


if __name__ == "__main__":
    unittest.main()
