# langbai解析深度审计修复记录

日期：2026-07-11

## 已修复

- 客户端不再自动解析剪贴板内容；检测默认关闭，开启后也只在本地提示并等待确认。
- 快手和抖音增加匿名分享页专用解析，避免短链错误落入通用解析；分享文案只提取 URL。
- B站二维码会话使用系统加密存储、限定 B站域名、跨域移除凭据，退出时清理会话；未登录状态保持匿名公开解析。
- API 客户端不再把手机端 `127.0.0.1` 当作远程服务；远程地址只接受 HTTPS，本地 HTTP 只允许回环地址。
- 自建 HTTPS 服务访问令牌按服务地址绑定并保存在系统安全存储中；所有带令牌的 API/文件请求拒绝重定向，防止凭据跨域泄露。
- Windows 进程实例令牌只允许发送给回环 API；远程 HTTPS 服务未配置自己的令牌时不会回退使用本机令牌。
- Windows 后端使用随机进程令牌、PID/端口所有权校验、单实例、崩溃限频重启和本地日志；所有 `/api/v1/*` 路由受令牌保护。
- 远程监听必须配置至少 32 字节实例令牌；Docker 默认仅发布回环端口且要求显式令牌。CORS 增加 DELETE 与安全预检支持。
- SSRF 防护覆盖初始 URL、DNS、连接 peer 和每次重定向；阻止内网、保留地址、用户信息和凭据跨域转发。
- HTTP 重定向按完整 origin 比较；HTTPS 降级被拒绝，跨协议、主机或端口都会移除 Cookie、Authorization 等敏感头。
- 下载和工具任务增加队列、并发、大小、存储、超时、取消、清理与错误脱敏；FFmpeg 限制可用协议。
- P2P 默认关闭，启用后仍拒绝 UDP/HTTP tracker、Web Seed 和未经校验的 tracker。
- Android/iOS 本地下载增加并发隔离、取消、进度、重复文件改名、失败残留清理与保存目标选择；Android 7–9 增加旧存储权限处理。
- iOS 下载使用独立任务目录并原子管理取消/合并生命周期，不再互相选错或清理文件；Android/iOS 对页面、单流、合并输入与最终文件执行 8 MB/8 GB 上限。
- 移动端未实现的后台下载、压缩、磁力等能力不再伪装可用；UI 按能力矩阵禁用并提示 HTTPS 服务要求。
- 下载历史持久化、过期运行任务恢复为失败、支持清空与重试；服务失败不再泄露原始异常堆栈或 ANSI 控制符。
- 音乐聚合扩展为多来源并显示逐源状态；只有明确开放许可或来源授权的文件才可下载。
- Web 带鉴权下载改为受限流式缓冲，增加取消、大小和超时；移除已弃用 `dart:html`。
- Windows 更新强制 HTTPS、大小、SHA-256、SemVer 防回退和 Authenticode 证书校验；Setup 以可见界面启动并记录日志。
- Windows Setup 强制签名、清理旧文件、携带 VC++ Runtime 与固定校验的 Deno；Runner 和后端均有诊断日志。
- Android Release 禁止 debug 签名回退；发布工作流使用固定证书并验证 APK 签名，解决后续覆盖安装身份不一致。
- Android 升级到 API 36、AGP 8.11.1、Gradle 8.14.5、Kotlin 2.2.20、NDK 28；补齐 adaptive/round 图标与生物识别权限。
- 深浅色对比度、窄屏/200% 字号布局、语义化选中状态和实时错误提示已修复并加入组件测试。
- Python 运行、开发和构建依赖全部生成 `--require-hashes` 锁文件；GitHub Actions 固定完整 SHA、收紧权限并新增 CodeQL。
- Android 官方 Gradle Wrapper、JAR 与发行包校验值已纳入仓库；发布版本升为 `1.0.9+10`，SemVer、Android versionCode 与 iOS build number 强制从 pubspec 同步。
- 后端无令牌时只接受真实回环连接并拒绝跨站浏览器请求；yt-dlp/FFmpeg 运行于可终止进程树，队列预留存储，分段越界即时终止且 Range 异常回退顺序下载。

## 已验证

- 后端：41 项 pytest 通过，无弃用警告；Ruff、Bandit 与依赖漏洞审计通过。
- Flutter 3.44：`flutter analyze` 零问题，22 项测试通过。
- Android：API 36 Debug APK 与应用模块 lint 均在干净 ASCII Gradle 缓存中通过，并已纳入 CI 门禁。
- 真实链接：用户提供的快手链接成功解析为 MP4 与封面，Range 下载返回 `206 video/mp4`；抖音分享链接成功返回视频和封面；B站匿名公开视频成功返回视频、音频和封面选项。
- 音乐：`周杰伦` 实测聚合 57 条目录结果，开放许可资源可列出文件并完成 `206 audio/mpeg` Range 下载。
- 发布工具：11 项单元测试、PowerShell 语法、Inno Setup smoke、Actionlint 与 Zizmor 已通过；各发布任务显式导出版本/构建号，后端测试固定在正确模块目录运行，无可信 Windows 证书时可安全发布移动端且更新清单省略 Windows，Web Release 构建与官方 Gradle Wrapper 校验通过。
- 品牌资源：小人主图、头像、Windows ICO、Android density/adaptive/round 图标、iOS AppIcon 与 Web favicon 均存在并被工程引用；源码无实际 mojibake 或 ESC 控制字符。

## 有意保留或需要仓库管理员完成

- 按用户要求，本轮不处理未签名 IPA 的安装/签名问题。
- Android/iOS 真正的系统级后台下载尚未实现；当前修复是诚实声明能力并要求任务期间保持前台。
- 1.0.6 及更早使用临时 debug 签名的 Android 安装无法与新的正式证书建立升级关系，必须卸载一次；之后必须永久复用同一 keystore。
- Windows 正式产物必须由配置 Authenticode 证书的 CI 生成；本机缺少 Visual Studio C++ 工作负载时不能完成最终 Runner 编译。
- Web 必须配置公网 HTTPS 后端；实例令牌不得作为公开 Dart define 嵌入浏览器包，应在反向代理层提供用户认证。
- 分支保护、Ruleset、Dependabot alerts、Release environment 审批与 Secrets 只能在 GitHub Settings 中启用，代码无法代替仓库管理员操作。
- 网站规则会变化，“所有站点永久可用”不是可验证承诺；应持续更新 yt-dlp/专用解析器并运行真实链接回归。
- Flutter 3.44/AGP 8 当前仍兼容传统 Kotlin Gradle Plugin，但工具链已提示未来 AGP 9 将切换 Built-in Kotlin；应在所有原生依赖声明兼容后单独迁移，不能在当前依赖尚未就绪时强行开启。
