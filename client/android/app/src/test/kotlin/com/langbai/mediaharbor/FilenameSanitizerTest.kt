package com.langbai.mediaharbor

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FilenameSanitizerTest {
    @Test
    fun `long Chinese title keeps its beginning and fits Android byte limit`() {
        val title = "好牛的审美！原来是MiniMax H3！" + "画面配乐音效一次生成".repeat(40)

        val filename = FilenameSanitizer.withExtension(title, "mp4")

        assertTrue(filename.startsWith("好牛的审美！原来是MiniMax H3！"))
        assertTrue(filename.endsWith(".mp4"))
        assertTrue(
            filename.toByteArray(Charsets.UTF_8).size <= FilenameSanitizer.MAX_FILENAME_BYTES,
        )
    }

    @Test
    fun `UTF-8 truncation never splits an emoji surrogate pair`() {
        val filename = FilenameSanitizer.withExtension("动画✨🎬".repeat(80), "mp4")

        assertFalse(filename.contains('\uFFFD'))
        assertTrue(filename.endsWith(".mp4"))
        assertTrue(
            filename.toByteArray(Charsets.UTF_8).size <= FilenameSanitizer.MAX_FILENAME_BYTES,
        )
    }

    @Test
    fun `collision suffix and extension stay inside byte limit`() {
        val original = FilenameSanitizer.withExtension("测试视频".repeat(80), "mp4")
        val collision = FilenameSanitizer.collisionName(original, 9999)

        assertTrue(collision.endsWith(".mp4"))
        assertTrue(collision.contains("(9999)"))
        assertTrue(
            collision.toByteArray(Charsets.UTF_8).size <= FilenameSanitizer.MAX_FILENAME_BYTES,
        )
    }
}
