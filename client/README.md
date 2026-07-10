# langbai解析 Flutter 客户端

跨平台客户端代码，支持 Windows、Android、iOS、Web、macOS 和 Linux。完整功能、构建方式与合法使用边界请查看仓库根目录的 `README.md`。

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

正式构建应同时传入 `APP_VERSION`、`API_BASE_URL` 和 `UPDATE_MANIFEST_URL`；GitHub Actions 工作流已统一配置这些参数。
