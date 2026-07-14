package com.langbai.mediaharbor

internal object AndroidErrorFormatter {
    private val ansiPattern = Regex("\\u001B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])")
    private val opaqueClassPattern = Regex("^(?:[a-zA-Z]\\d*\\.)+[a-zA-Z]\\d*$")

    fun isOpaqueEngineFailure(error: Throwable): Boolean =
        throwableChain(error).any { throwable ->
            val message = throwable.message?.trim().orEmpty()
            message.isNotEmpty() && isOpaque(message)
        } && throwableChain(error).none { throwable ->
            val message = clean(throwable.message.orEmpty())
            message.isNotEmpty() && !isOpaque(message) && message.length > 8
        }

    fun format(error: Throwable): String {
        val chain = throwableChain(error).toList()
        if (chain.any { it.javaClass.simpleName.contains("CanceledException", ignoreCase = true) }) {
            return "任务已取消"
        }

        val useful = chain
            .flatMap { it.message.orEmpty().lineSequence() }
            .map(::clean)
            .filter {
                it.isNotEmpty() &&
                    !it.startsWith("WARNING:", ignoreCase = true) &&
                    !isOpaque(it)
            }
            .distinct()
            .maxByOrNull(::score)
            .orEmpty()
        val lower = useful.lowercase()

        if (
            "fresh cookies" in lower ||
            "cookies (not necessarily logged in) are needed" in lower ||
            "cookies are needed" in lower ||
            "cookies are required" in lower ||
            "sign in to confirm you're not a bot" in lower ||
            "use --cookies-from-browser or --cookies" in lower
        ) {
            return "该平台当前要求登录验证；请登录对应平台后重试，或换一个公开链接"
        }
        if ("ip address is blocked" in lower) {
            return "当前网络出口被该平台限制，请切换网络后重试"
        }
        if ("impersonate targets are available" in lower) {
            return "该平台需要浏览器模拟组件，当前手机本地解析器暂不支持"
        }
        if ("phantomjs not found" in lower) {
            return "该平台需要额外浏览器组件，当前手机本地解析器暂不支持"
        }
        if (
            "unable to download webpage" in lower ||
            "connection refused" in lower ||
            "connection reset" in lower ||
            "timed out" in lower ||
            "timeout" in lower
        ) {
            return "无法连接视频平台，请检查网络或稍后重试"
        }
        if (
            "unsupported url" in lower ||
            "no suitable extractor" in lower ||
            "no video formats found" in lower
        ) {
            return "该链接暂未发现可下载的公开媒体，请确认链接完整且作品可公开访问"
        }
        if (useful.isNotEmpty()) return useful.take(500)

        return if (chain.any { isOpaque(clean(it.message.orEmpty())) }) {
            "手机解析引擎运行异常，已尝试自动修复；请重新解析，仍失败可在设置中更新解析引擎"
        } else {
            "手机本地解析失败，请检查链接后重试"
        }
    }

    private fun throwableChain(error: Throwable): Sequence<Throwable> =
        generateSequence(error) { current -> current.cause?.takeUnless { it === current } }
            .take(12)

    private fun clean(value: String): String = value
        .replace(ansiPattern, "")
        .replace(Regex("(?:ERROR:\\s*)+", RegexOption.IGNORE_CASE), "")
        .replace(Regex("\\s+"), " ")
        .trim()

    private fun isOpaque(value: String): Boolean {
        val normalized = clean(value)
            .removePrefix("java.lang.RuntimeException:")
            .trim()
        return opaqueClassPattern.matches(normalized) ||
            normalized.matches(Regex("^[a-zA-Z]\\d{0,2}$"))
    }

    private fun score(value: String): Int {
        var result = value.length.coerceAtMost(500)
        if (value.contains("unable", ignoreCase = true)) result += 300
        if (value.contains("failed", ignoreCase = true)) result += 200
        return result
    }
}
