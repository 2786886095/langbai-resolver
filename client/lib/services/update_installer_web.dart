import 'package:url_launcher/url_launcher.dart';

import 'update_models.dart';

Future<String> installUpdate(
  UpdatePlatformRelease release, {
  required String version,
  void Function(double progress)? onProgress,
}) async {
  final uri = Uri.tryParse(release.url);
  if (uri == null || !await launchUrl(uri, webOnlyWindowName: '_blank')) {
    throw StateError('无法打开更新页面');
  }
  onProgress?.call(1);
  return '已打开更新页面';
}
