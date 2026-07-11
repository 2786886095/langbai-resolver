# langbai解析

`langbai解析` 是面向 Windows、Android、iOS 和 Web 的公开媒体解析、下载与转换工作台。它只用于用户有权保存的公开、无 DRM 内容，不绕过付费、私密、地区限制或访问控制。

![langbai解析深色界面](design-reference/implementation-dark-updater.png)

## 平台能力

| 能力 | Windows | Android | iOS | Web |
| --- | --- | --- | --- | --- |
| 公开媒体本机解析 | 支持，Setup 内置后端、yt-dlp、Deno、FFmpeg、aria2 | 支持，APK 内置本地解析引擎 | 支持，App 内嵌 Python/yt-dlp | 不支持，必须连接 HTTPS 服务 |
| B站扫码会话与账号可见画质 | 支持 | 支持 | 支持 | 取决于所连接服务 |
| 视频、音频、封面、图集下载 | 支持 | 支持 | 支持 | 支持浏览器允许的下载 |
| 保存到文件/相册 | 文件与自选目录 | 文件或系统相册 | “文件”App 或系统相册 | 浏览器下载目录 |
| 网页嗅探、媒体压缩、音频提取、并发直链 | 本地支持 | 需配置 HTTPS 服务 | 需配置 HTTPS 服务 | 由 HTTPS 服务提供 |
| 磁力与种子 | 本地服务显式启用后支持 | 需配置已启用 P2P 的 HTTPS 服务 | 需配置已启用 P2P 的 HTTPS 服务 | 由服务端能力决定 |
| 后台下载 | 当前不支持，关闭窗口会中止前台任务 | 当前不支持，任务期间需保持应用前台 | 当前不支持，任务期间需保持应用前台 | 取决于浏览器 |
| 应用更新 | 下载、校验并显示 Setup 安装界面 | 打开已签名 APK 发布页 | 打开发布页 | 打开发布页 |

macOS 和 Linux 目录仅保留 Flutter 工程文件，当前发布流程不生成正式安装包。移动端不会伪装支持未实现的后台任务或高级本地工具：客户端会读取能力矩阵，并将不可用入口标记为需要 HTTPS 服务。

## 解析与下载

- 支持直接粘贴 URL，也支持包含说明文字的抖音、快手等完整分享文案；客户端只提取其中的链接，不会把整段文本加入下载任务。
- 剪贴板检测默认关闭。用户主动开启后，应用只显示“发现链接”的本地提示，确认前不会联网解析，也不会自动创建下载。
- 快手公开分享页优先从 `INIT_STATE` 提取原始视频、封面和图集；抖音公开分享页优先从 `_ROUTER_DATA` 提取资源，不依赖 Cookie。
- 通用站点由 yt-dlp 解析，支持的分辨率、音频、封面和图集以该链接当时公开返回的数据为准。
- B站扫码会话只保存在当前设备的系统加密存储中，仅发送给 B站域名；跨域重定向会移除 Cookie，退出登录会清理会话和临时文件。
- 下载任务支持进度、取消、失败残留清理、历史恢复和重试；直链下载有大小、超时、并发与存储配额。
- 开放音乐搜索聚合 Internet Archive、Wikimedia Commons、Audius、Apple Music、MusicBrainz，并可选接入 Jamendo。Apple Music 和 MusicBrainz 只提供目录元数据；只有明确声明 Creative Commons、CC0、公共领域或来源授权下载的文件才显示下载入口。

> 不存在能够长期、匿名、合法覆盖“所有国内外视频软件”的万能解析接口。站点页面、签名、登录和风控会持续变化，因此项目不承诺所有网站永久可用；实际支持情况以当前解析器版本和具体公开链接测试为准。需要登录或新鲜 Cookie 的非 B站内容会明确提示不属于匿名解析范围，而不会要求读取浏览器 Cookie。

## 本机启动

需要 Python 3.12、Flutter 3.44、JDK 17，以及对应平台的构建工具。

```powershell
.\scripts\start_backend.ps1
Set-Location .\client
flutter run -d windows
```

开发后端默认只监听 `127.0.0.1:8787`。Windows 正式版会为每次进程启动生成随机实例令牌，客户端自动携带该令牌，其他本机进程不能直接调用 `/api/v1/*`。

## 安全部署 HTTPS 服务

远程服务必须配置至少 32 字节的随机实例令牌、精确 CORS、TLS、反向代理限速和出口隔离。不要把实例令牌编译进公开 Web 包；公开 Web 应通过独立的用户认证网关访问后端。

Android、iOS 和桌面客户端可在“设置 → 高级工具服务”中填写访问令牌。令牌与规范化后的服务地址绑定，只保存在系统安全存储中；更换地址时不会把旧令牌发送给新服务。所有带令牌的 API 和文件请求都拒绝 HTTP 重定向，避免凭据被跨域转发。Web 端不持久化该令牌。

PowerShell 示例：

```powershell
$env:MEDIA_HARBOR_INSTANCE_TOKEN = python -c "import secrets; print(secrets.token_urlsafe(48))"
$env:MEDIA_HARBOR_CORS_ORIGINS = "https://你的前端域名"
docker compose up -d --build
```

Docker 默认只发布到宿主机 `127.0.0.1:8787`，并要求显式提供实例令牌。P2P 默认关闭；只有在隔离环境中理解 tracker、peer、磁盘与合规风险后，才可设置 `MEDIA_HARBOR_ALLOW_PEER_TO_PEER=true`。服务端同时限制上传、响应、单任务、总存储、排队数量和运行时间，并校验重定向与 DNS，阻止访问内网和保留地址。

完整变量见 `backend/.env.example`。

## 构建与发布

Windows Setup 需要 Flutter、Visual Studio C++ 桌面工作负载、Inno Setup 6 和 Authenticode 证书：

```powershell
.\scripts\build_windows_setup.ps1 `
  -Version "1.0.9" `
  -UpdateManifestUrl "https://github.com/2786886095/langbai-resolver/releases/latest/download/update-manifest.json" `
  -SigningCertificatePath "C:\secure\langbai-signing.pfx"
```

正式 Setup 不允许无签名发布。应用内更新只接受 HTTPS，校验清单版本、安装包大小、SHA-256 和受信任 Authenticode 证书后，显示 Setup 界面；安装日志写入 `%LOCALAPPDATA%\langbai-resolver\logs`。

Android Release 不会回退到 debug 签名。GitHub 必须长期保留同一把 Android 签名密钥，否则系统会把新 APK 视为不同发布者并拒绝覆盖安装。曾安装 1.0.6 及更早临时 debug 签名版本的设备，需要卸载旧版一次；安装固定发布签名版本后可正常覆盖升级。

GitHub Actions 发布前需要配置：

- Secrets：`WINDOWS_SIGNING_CERTIFICATE_BASE64`、`WINDOWS_SIGNING_CERTIFICATE_PASSWORD`
- Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS`
- Repository variable：`WEB_API_BASE_URL`，必须是公网 HTTPS；不发布 Web 时可不配置，工作流会自动跳过 Web job
- Repository variable：`ENABLE_WINDOWS_SIGNED_BUILD=true`，在已配置 Windows 签名 Secrets 后启用日常 Setup 构建
- Repository Settings：启用分支保护或 Ruleset、必需检查、Dependabot alerts，并限制 Release 环境的写权限

依赖构建使用带哈希的 `requirements.lock`、`requirements-build.lock` 和 `requirements-dev.lock`；工作流 Action 固定到完整 commit SHA。推送 `v1.0.9` 形式的 tag 后，Release 流程会产出签名 Windows Setup、固定签名 Android APK、现有未签名 IPA、可选 Web 包和固定版本资产 URL 的更新清单。

iOS 未签名 IPA 的安装/签名问题按当前项目范围保留，不在本轮修复中；正常安装仍需要有效 Apple 证书或用户自己的签名流程。

## 验证

```powershell
Set-Location .\backend
..\.venv\Scripts\python.exe -m pytest -q

Set-Location ..\client
flutter analyze
flutter test
$env:GRADLE_USER_HOME = Join-Path $env:TEMP "langbai-gradle-home"
.\android\gradlew.bat --project-dir android :app:assembleDebug :app:lintDebug --no-daemon --max-workers=1

Set-Location ..
python -m unittest discover -s scripts/tests -v
```

本次深度审计与修复记录位于 `audit/2026-07-11/`。
