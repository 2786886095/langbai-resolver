package com.langbai.mediaharbor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaUrlNormalizerTest {
    @Test
    fun replacesOnlyTheDouyinWatermarkEndpoint() {
        assertEquals(
            "https://v3-dy.example.com/aweme/v1/play/?video_id=abc&ratio=720p",
            MediaUrlNormalizer.normalizeDouyinPlayUrl(
                "https://v3-dy.example.com/aweme/v1/playwm/?video_id=abc&ratio=720p",
            ),
        )
        assertEquals(
            "https://example.com/path/playwm/file.mp4",
            MediaUrlNormalizer.normalizeDouyinPlayUrl("https://example.com/path/playwm/file.mp4"),
        )
    }

    @Test
    fun imagePostsDoNotExposeThePlaceholderVideo() {
        assertFalse(MediaUrlNormalizer.shouldExposeDouyinVideo("https://example.com/video.mp4", 4))
        assertTrue(MediaUrlNormalizer.shouldExposeDouyinVideo("https://example.com/video.mp4", 0))
    }

    @Test
    fun detectsTextualSoftErrorsButNeverGuessesOctetStream() {
        val html = "  <!doctype html><title>blocked</title>".toByteArray()
        val json = "{\"status\":\"denied\"}".toByteArray()
        val playlist = "#EXTM3U\n#EXT-X-VERSION:3".toByteArray()
        assertTrue(MediaUrlNormalizer.isObviousTextMediaError("text/html; charset=utf-8", html))
        assertTrue(MediaUrlNormalizer.isObviousTextMediaError("application/problem+json", json))
        assertTrue(MediaUrlNormalizer.isObviousTextMediaError("application/vnd.apple.mpegurl", playlist))
        assertTrue(MediaUrlNormalizer.isObviousTextMediaError("text/plain", "access denied".toByteArray()))
        assertTrue(MediaUrlNormalizer.isObviousTextMediaError("application/octet-stream", html))
        assertTrue(MediaUrlNormalizer.isObviousTextMediaError("video/mp4", html))
        assertTrue(MediaUrlNormalizer.isObviousTextMediaError(null, json))
        assertFalse(
            MediaUrlNormalizer.isObviousTextMediaError(
                "application/octet-stream",
                byteArrayOf(0, 0, 0, 24, 'f'.code.toByte(), 't'.code.toByte()),
            ),
        )
    }
}
