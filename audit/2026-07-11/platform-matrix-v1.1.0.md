# langbai解析 1.1.0 主流平台真实解析矩阵

报告更新时间（UTC）：`2026-07-11T13:52:23+00:00`
解析引擎：`yt-dlp 2026.07.04`
结果汇总：成功 13；需要登录 1；站点/内容未公开 1；缺少运行依赖 1；失败 1

增量复测：`2026-07-11T13:52:23+00:00` 更新 AcFun、Twitch Clips；其余平台沿用同一日期的完整串行探针结果。


## 探针边界

本次只调用 `POST /api/v1/resolve` 获取元数据和候选格式，不调用下载接口，不读取浏览器 Cookie，也不绕过登录、地区、年龄、付费、私密或 DRM 限制。“成功”表示返回了样例期望的视频候选项，不表示已下载并逐字节验证媒体文件。

该脚本是人工发布审计，不是强制 CI 门禁。失败可能来自平台限制或公开样例失效，不应通过降低安全边界来让矩阵变绿。

本次执行环境使用 `198.18.0.0/15` 合成 DNS，因此临时启用了项目已有的 `MEDIA_HARBOR_ALLOW_FAKE_IP_DNS` 兼容开关；普通公网 DNS 环境不应启用。

## 当前矩阵

| 平台 | 结果 | 候选类型/数量 | 耗时 | 公开样例与来源 | 摘要 |
| --- | --- | --- | ---: | --- | --- |
| 抖音 | 成功 | image, video / 2 | 0.80s | [样例](https://www.douyin.com/video/6961737553342991651) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/tiktok.py "yt-dlp 2026.07.04 DouyinIE test") | 返回 2 个候选项：image, video |
| 快手 | 成功 | image, video / 2 | 1.30s | [样例](https://v.kuaishou.com/JogJVR8p) · [来源](https://www.chinanews.com.cn/fileftp/2026/05/2026-05-13/U1106P4T47D56160F29949DT20260513085427.pdf?browser=yes "中国新闻网公开参评材料中的媒体链接") | 返回 2 个候选项：image, video |
| B站 | 成功 | audio, image, video / 13 | 1.00s | [样例](https://www.bilibili.com/video/BV13x41117TL) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/bilibili.py "yt-dlp 2026.07.04 BiliBiliIE test") | 返回 13 个候选项：audio, image, video |
| YouTube | 成功 | audio, image, video / 23 | 1.70s | [样例](https://www.youtube.com/watch?v=YE7VzlLtp-4) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/youtube/_video.py "yt-dlp 2026.07.04 YoutubeIE test") | 返回 23 个候选项：audio, image, video |
| TikTok | 成功 | audio, image, video / 8 | 1.56s | [样例](https://www.tiktok.com/@barudakhb_/video/6984138651336838402) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/tiktok.py "yt-dlp 2026.07.04 TikTokIE test") | 返回 8 个候选项：audio, image, video |
| Instagram | 成功 | image, video / 2 | 2.81s | [样例](https://instagram.com/p/aye83DjauH/) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/instagram.py "yt-dlp 2026.07.04 InstagramIE test") | 返回 2 个候选项：image, video |
| X / Twitter | 成功 | image, video / 4 | 1.28s | [样例](https://x.com/TopHeroes_/status/2001950365332455490) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/twitter.py "yt-dlp 2026.07.04 TwitterIE test") | 返回 4 个候选项：image, video |
| Facebook | 成功 | audio, image, video / 9 | 3.42s | [样例](https://www.facebook.com/WatchESLOne/videos/359649331226507/) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/facebook.py "yt-dlp 2026.07.04 FacebookIE test") | 返回 9 个候选项：audio, image, video |
| Vimeo | 成功 | audio, image, video / 11 | 2.77s | [样例](https://vimeo.com/54469442) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/vimeo.py "yt-dlp 2026.07.04 VimeoIE test") | 返回 11 个候选项：audio, image, video |
| 西瓜视频 | 需要登录 | — / 0 | 0.97s | [样例](https://www.ixigua.com/6996881461559165471) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/ixigua.py "yt-dlp 2026.07.04 IxiguaIE test") | 该平台当前没有可用的匿名公开解析入口；langbai解析不会读取登录 Cookie |
| 小红书 | 站点/内容未公开 | image / 1 | 1.27s | [样例](https://www.xiaohongshu.com/explore/6411cf99000000001300b6d9) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/xiaohongshu.py "yt-dlp 2026.07.04 XiaoHongShuIE test") | 小红书 - 你访问的页面不见了 站点专用解析器不可用，已使用通用网页媒体解析。 |
| 微博 | 成功 | audio, image, video / 7 | 0.91s | [样例](https://weibo.com/7827771738/N4xlMvjhI) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/weibo.py "yt-dlp 2026.07.04 WeiboIE test") | 返回 7 个候选项：audio, image, video |
| 优酷 | 失败 | — / 0 | 0.64s | [样例](https://v.youku.com/v_show/id_XNjA1NzA2Njgw.html) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/youku.py "yt-dlp 2026.07.04 YoukuIE test") | 该页面暂未发现公开媒体资源：[youku] XNjA1NzA2Njgw: Unable to download webpage: [SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol (_ssl.c:1006) (caused by SSLError('[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol (_ssl. |
| AcFun | 成功 | audio, image, video / 10 | 0.81s | [样例](https://www.acfun.cn/v/ac35457073) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/acfun.py "yt-dlp 2026.07.04 AcFunVideoIE test") | 返回 10 个候选项：audio, image, video |
| Dailymotion | 缺少运行依赖 | — / 0 | 4.81s | [样例](https://www.dailymotion.com/video/x5kesuj) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/dailymotion.py "yt-dlp 2026.07.04 DailymotionIE test") | 该页面暂未发现公开媒体资源：[dailymotion] x5kesuj: The extractor is attempting impersonation, but none of these impersonate targets are available: firefox. See https://github.com/yt-dlp/yt-dlp#impersonation for information on installing the required dependencies |
| Twitch Clips | 成功 | audio, image, video / 5 | 0.99s | [样例](https://clips.twitch.tv/FaintLightGullWholeWheat) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/twitch.py "yt-dlp 2026.07.04 TwitchClipsIE test") | 返回 5 个候选项：audio, image, video |
| Reddit | 成功 | audio, image, video / 12 | 3.34s | [样例](https://www.reddit.com/r/videos/comments/6rrwyj/that_small_heart_attack/) · [来源](https://github.com/yt-dlp/yt-dlp/blob/2026.07.04/yt_dlp/extractor/reddit.py "yt-dlp 2026.07.04 RedditIE test") | 返回 12 个候选项：audio, image, video |

## 本次结论

- 点名的 12 个核心平台中，10 个样例成功：抖音、快手、B站、YouTube、TikTok、Instagram、X / Twitter、Facebook、Vimeo、微博。
- 未成功项：西瓜视频（需要登录）、小红书（站点/内容未公开）；具体原因以矩阵摘要为准，不会用浏览器 Cookie 或绕过访问控制来强行通过。
- 扩展样例成功：AcFun、Twitch Clips、Reddit；未成功：优酷（失败）、Dailymotion（缺少运行依赖）。扩展结果用于暴露兼容性缺口，同样不代表整个站点。

## 如何复测

在仓库根目录执行：

```powershell
.\.venv\Scripts\python.exe scripts\probe_platform_matrix.py `
  --start-local-backend --workers 1 --allow-fake-ip-dns `
  --json-out audit\YYYY-MM-DD\platform-matrix-v1.1.0.json `
  --markdown-out audit\YYYY-MM-DD\platform-matrix-v1.1.0.md
```

单独复测某个平台可追加 `--platform youtube`；用 `--list` 查看可选名称。探针中出现失败状态不会改变进程退出码，避免把外部站点波动当成代码 CI 失败。

## 明确限制

- 每个平台只使用一个公开样例，不能代表该平台的所有页面类型。
- 成功仅表示解析接口返回期望媒体候选项；本探针不下载媒体字节。
- 本矩阵验证 FastAPI 后端，不覆盖 Android/iOS 安装包内的本机解析引擎。
- 不读取或上传浏览器 Cookie，不绕过登录、年龄、地区、付费、私密或 DRM 限制。
- 结果受执行日期、出口地区、平台风控、样例存续和 yt-dlp 版本影响。
- 平台规则会变化，本报告不是“所有平台永久可用”的承诺。
