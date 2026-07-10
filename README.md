# langbai解析

`langbai解析` 是面向 Windows、Android、iOS 和 Web 的公开媒体解析、转换与下载工作台。复制链接进入应用后会自动识别，但始终由用户确认是否解析；界面同时提供深色与浅色模式。

![langbai解析深色界面](design-reference/implementation-dark.png)

## 主要能力

- 使用 yt-dlp 的站点解析器并提供通用网页元数据兜底，可选择视频分辨率、音频、封面和图片。
- 静态网页媒体嗅探、并发分段直链下载、磁力链接和 `.torrent` 种子任务。
- 本地视频提取音频、视频压缩、图片压缩和媒体信息读取。
- 基于 Internet Archive 的开放授权/公共领域音乐搜索及无损音频文件筛选。
- Windows 软件内下载 Setup、SHA-256 校验并启动静默更新；Android、iOS、Web 启动时统一检测更新。
- 自适应桌面侧边栏和移动端底部导航，支持深色、浅色和跟随系统。

> 网站接口、登录策略和风控会变化，因此无法承诺“所有网站永久适配”。解析器可独立升级以降低维护成本。项目只处理公开、无 DRM 且用户有权保存的内容，不绕过付费、私密、地区限制或访问控制。BT/磁力功能也只用于合法内容。

## 目录

```text
client/                 Flutter 全平台客户端
backend/                FastAPI + yt-dlp + FFmpeg + aria2 服务
installer/windows/      Inno Setup 安装器配置
scripts/                构建、发布清单和维护脚本
.github/workflows/      APK、IPA、Web、Setup 和 Release 自动化
```

## 本机启动

Windows PowerShell：

```powershell
.\scripts\start_backend.ps1
Set-Location .\client
flutter run -d windows
```

后端接口文档位于 `http://127.0.0.1:8787/docs`。手机需要将解析服务地址改为电脑可访问的局域网或 HTTPS 地址。

Docker 部署：

```powershell
docker compose up -d --build
```

生产环境应限制 `MEDIA_HARBOR_CORS_ORIGINS`，并在反向代理增加认证、限速、上传大小限制和出口隔离。登录 Cookie 只能在确认拥有内容访问权时通过 `MEDIA_HARBOR_COOKIE_FILE` 配置，且不能提交到仓库。

## 构建

Windows Setup（需要 Flutter、Visual Studio C++ 桌面工作负载和 Inno Setup 6）：

```powershell
.\scripts\build_windows_setup.ps1 `
  -Version "1.0.0" `
  -UpdateManifestUrl "https://github.com/你的账号/langbai-resolver/releases/latest/download/update-manifest.json"
```

输出为 `dist/langbai-resolver-Setup.exe`。

Android APK：

```powershell
.\scripts\build_android.ps1 `
  -ApiBaseUrl "https://你的解析服务域名" `
  -UpdateManifestUrl "https://github.com/你的账号/langbai-resolver/releases/latest/download/update-manifest.json"
```

iOS 必须在 macOS/Xcode 环境构建。`build-unsigned-ipa.yml` 可生成未签名 IPA；安装前仍需使用自己的 Apple 证书签名。已配置签名环境时可运行：

```bash
API_BASE_URL="https://你的解析服务域名" \
UPDATE_MANIFEST_URL="https://github.com/你的账号/langbai-resolver/releases/latest/download/update-manifest.json" \
./scripts/build_ipa.sh --export-options-plist=../ios/ExportOptions.ad-hoc.plist
```

## GitHub Release 与自动更新

推送 `v1.0.0` 形式的标签，`release.yml` 会自动生成并发布：

- `langbai-resolver-Setup.exe`
- `langbai-resolver-Android.apk`
- `langbai-resolver-iOS.ipa`
- `langbai-resolver-Web.zip`
- `update-manifest.json`

客户端默认从 Release 的 `latest/download/update-manifest.json` 检查版本。后端也提供 `/api/v1/update` 作为可自托管的更新清单入口，对应环境变量记录在 `backend/.env.example`。

## 测试

```powershell
Set-Location .\backend
..\.venv\Scripts\python.exe -m pytest -q

Set-Location ..\client
flutter analyze
flutter test
```
