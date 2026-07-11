import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/services/local_media_service.dart';

void main() {
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
      'tools': {'resolve': true, 'compress': false},
    });

    expect(capabilities.platform, 'ios');
    expect(capabilities.localResolver, isTrue);
    expect(capabilities.engineUpdate, isFalse);
    expect(capabilities.downloadCancellation, isTrue);
    expect(capabilities.backgroundDownload, isFalse);
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
}
