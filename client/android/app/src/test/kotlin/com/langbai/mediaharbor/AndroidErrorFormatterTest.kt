package com.langbai.mediaharbor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidErrorFormatterTest {
    @Test
    fun `opaque minified exception is replaced with useful guidance`() {
        val error = RuntimeException("d2.f")

        assertTrue(AndroidErrorFormatter.isOpaqueEngineFailure(error))
        assertEquals(
            "手机解析引擎运行异常，已尝试自动修复；请重新解析，仍失败可在设置中更新解析引擎",
            AndroidErrorFormatter.format(error),
        )
    }

    @Test
    fun `nested extractor detail wins over opaque wrapper`() {
        val error = RuntimeException(
            "d2.f",
            IllegalStateException("ERROR: Unable to download webpage: timed out"),
        )

        assertFalse(AndroidErrorFormatter.isOpaqueEngineFailure(error))
        assertEquals(
            "无法连接视频平台，请检查网络或稍后重试",
            AndroidErrorFormatter.format(error),
        )
    }

    @Test
    fun `cookie requirement gets a readable mobile message`() {
        val error = IllegalStateException(
            "ERROR: Fresh cookies (not necessarily logged in) are needed",
        )

        assertEquals(
            "该平台当前要求登录验证；请登录对应平台后重试，或换一个公开链接",
            AndroidErrorFormatter.format(error),
        )
    }

    @Test
    fun `Douyin cookie requirement opens the in-app login flow`() {
        val error = IllegalStateException(
            "ERROR: [Douyin] Fresh cookies (not necessarily logged in) are needed",
        )

        assertEquals(
            "该作品需要抖音登录，请在 langbai解析内登录后重试",
            AndroidErrorFormatter.format(error),
        )
    }

    @Test
    fun `overlong filename gets a readable retry message`() {
        val error = IllegalStateException("open failed: ENAMETOOLONG (File name too long)")

        assertEquals(
            "媒体标题过长，软件已自动缩短文件名，请重新解析",
            AndroidErrorFormatter.format(error),
        )
    }
}
