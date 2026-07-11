import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/models/media_models.dart';
import 'package:media_harbor/services/download_types.dart';
import 'package:media_harbor/services/local_media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native capability payload is parsed without inventing support', () {
    final capabilities = LocalMediaCapabilities.fromJson({
      'platform': 'ios',
      'local_resolver': true,
      'engine_update': false,
      'download_progress': true,
      'download_cancellation': true,
      'background_download': false,
      'save_to_files': true,
      'save_to_gallery': true,
      'custom_save_directory': true,
      'format_conversion': true,
      'conversion_progress': true,
      'conversion_cancellation': true,
      'app_update_install': false,
      'media_probe': true,
      'current_abi': 'arm64',
      'supported_abis': ['arm64', 'armv7'],
      'conversion': {
        'input_extensions': ['mp4', 'png'],
        'output_formats': ['mp4', 'webp'],
        'quality_values': ['medium', 'high'],
      },
      'tools': {'resolve': true, 'compress': false},
    });

    expect(capabilities.platform, 'ios');
    expect(capabilities.localResolver, isTrue);
    expect(capabilities.engineUpdate, isFalse);
    expect(capabilities.downloadCancellation, isTrue);
    expect(capabilities.backgroundDownload, isFalse);
    expect(capabilities.customSaveDirectory, isTrue);
    expect(capabilities.formatConversion, isTrue);
    expect(capabilities.conversionCancellation, isTrue);
    expect(capabilities.appUpdateInstall, isFalse);
    expect(capabilities.mediaProbe, isTrue);
    expect(capabilities.currentAbi, 'arm64');
    expect(capabilities.supportedAbis, ['arm64', 'armv7']);
    expect(capabilities.conversion.outputFormats, ['mp4', 'webp']);
    expect(capabilities.tools['resolve'], isTrue);
    expect(capabilities.tools['compress'], isFalse);
    expect(capabilities.tools['torrent'], isNull);
  });

  test('malformed tool capability values default to unsupported', () {
    final capabilities = LocalMediaCapabilities.fromJson({
      'platform': 'android',
      'tools': {'resolve': 'true', 'music_search': 1},
    });

    expect(capabilities.localResolver, isFalse);
    expect(capabilities.tools['resolve'], isFalse);
    expect(capabilities.tools['music_search'], isFalse);
  });

  test(
    'native media probe payload is parsed without inventing streams',
    () async {
      const channel = MethodChannel('com.langbai.resolver/local_media');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'probeMedia');
            expect((call.arguments as Map)['input_path'], '/tmp/sample.mp4');
            return {
              'filename': 'sample.mp4',
              'extension': 'mp4',
              'mime_type': 'video/mp4',
              'size_bytes': 1024,
              'duration_seconds': 12.5,
              'width': 1920,
              'height': 1080,
              'has_video': true,
              'has_audio': true,
              'streams': [
                {
                  'index': 0,
                  'type': 'video',
                  'codec': 'h264',
                  'width': 1920,
                  'height': 1080,
                },
              ],
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final result = await LocalMediaService.instance.probeMedia(
        inputPath: '/tmp/sample.mp4',
      );

      expect(result.durationSeconds, 12.5);
      expect(result.hasVideo, isTrue);
      expect(result.hasAudio, isTrue);
      expect(result.streams, hasLength(1));
      expect(result.streams.single.codec, 'h264');
    },
  );

  test(
    'all native progress callbacks decode 0..100 percentage points',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('com.langbai.resolver/local_media');
      const rawPercentages = <double>[0.5, 1, 2, 100, -5, 120];

      Future<void> emitProgress(String method, String processId) async {
        for (final percentage in rawPercentages) {
          await TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall(method, {
                    'process_id': processId,
                    'progress': percentage,
                    'downloaded_bytes': 256,
                    'total_bytes': 1024,
                    'speed_bytes_per_second': 128.0,
                  }),
                ),
                null,
              );
        }
      }

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = (call.arguments as Map).cast<String, Object?>();
            final processId = arguments['process_id']! as String;
            switch (call.method) {
              case 'download':
                await emitProgress('downloadProgress', processId);
                return {'filename': 'sample.mp4', 'message': '下载完成'};
              case 'convertMedia':
                await emitProgress('conversionProgress', processId);
                return {
                  'process_id': processId,
                  'filename': 'sample.webm',
                  'format': 'webm',
                  'message': '转换完成',
                };
              case 'installAppUpdate':
                await emitProgress('updateProgress', processId);
                return {'message': '请允许安装未知应用'};
            }
            throw MissingPluginException(call.method);
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final downloadProgress = <double>[];
      final conversionProgress = <double>[];
      final updateProgress = <double>[];

      await LocalMediaService.instance.download(
        mediaId: 'media-1',
        optionId: 'video-1',
        kind: AssetKind.video,
        destination: SaveDestination.files,
        processId: 'download-1',
        onProgressDetails: (progress) {
          downloadProgress.add(progress.progress);
          expect(progress.downloadedBytes, 256);
          expect(progress.totalBytes, 1024);
          expect(progress.speedBytesPerSecond, 128);
        },
      );
      await LocalMediaService.instance.convertMedia(
        inputPath: '/tmp/sample.mp4',
        outputFormat: 'webm',
        quality: 'medium',
        processId: 'conversion-1',
        onProgress: (progress) => conversionProgress.add(progress.progress),
      );
      final installMessage = await LocalMediaService.instance.installAppUpdate(
        url: 'https://example.com/app.apk',
        sha256: 'a' * 64,
        sizeBytes: 1024,
        processId: 'update-1',
        onProgress: (progress) => updateProgress.add(progress.progress),
      );

      const expected = <double>[0.005, 0.01, 0.02, 1, 0, 1];
      expect(downloadProgress, expected);
      expect(conversionProgress, expected);
      expect(updateProgress, expected);
      expect(installMessage, '请允许安装未知应用');
    },
  );
}
