import 'update_models.dart';

Future<void> installUpdate(
  UpdatePlatformRelease release, {
  required String version,
  void Function(double progress)? onProgress,
}) async {
  throw UnsupportedError('当前平台不支持自动安装更新');
}
