import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/services/update_models.dart';
import 'package:media_harbor/services/update_service.dart';

void main() {
  UpdateManifest manifest(Map<String, String> urls) => UpdateManifest(
    version: '1.1.1',
    notes: '',
    publishedAt: '',
    platforms: {
      for (final entry in urls.entries)
        entry.key: UpdatePlatformRelease(url: entry.value),
    },
  );

  test('Android update selects exact ABI before the universal APK', () {
    final value = manifest({
      'android-arm64': 'https://example.com/arm64.apk',
      'android': 'https://example.com/universal.apk',
    });

    expect(
      selectUpdateRelease(value, 'android', androidAbi: 'arm64-v8a')?.url,
      'https://example.com/arm64.apk',
    );
    expect(androidReleaseKeysForAbi('x86_64'), ['android-x86_64', 'android']);
  });

  test('Android update falls back to universal for missing or unknown ABI', () {
    final value = manifest({
      'android-arm64': 'https://example.com/arm64.apk',
      'android': 'https://example.com/universal.apk',
    });

    expect(
      selectUpdateRelease(value, 'android', androidAbi: 'riscv64')?.url,
      'https://example.com/universal.apk',
    );
    expect(
      selectUpdateRelease(value, 'android', androidAbi: 'armeabi-v7a')?.url,
      'https://example.com/universal.apk',
    );
  });
}
