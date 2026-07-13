import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/services/download_saver.dart';

void main() {
  test(
    'completed transfer is emitted only after the file is published',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'langbai-download-saver-test-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      const bytes = <int>[1, 2, 3, 4, 5, 6, 7, 8];
      server.listen((request) async {
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });

      final simpleProgress = <double>[];
      final progress = <double>[];
      final result = await saveDownload(
        Uri.parse('http://127.0.0.1:${server.port}/output.mp4'),
        'output.mp4',
        simpleProgress.add,
        destination: SaveDestination.custom,
        customDestinationUri: directory.path,
        onTransferProgress: (value) => progress.add(value.progress),
      );

      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      expect(progress.where((value) => value >= 1), hasLength(1));
      expect(progress.take(progress.length - 1), everyElement(lessThan(1)));
      expect(simpleProgress.last, 1);
      expect(simpleProgress.where((value) => value >= 1), hasLength(1));
      expect(
        simpleProgress.take(simpleProgress.length - 1),
        everyElement(lessThan(1)),
      );
      expect(result.path, isNotNull);
      expect(await File(result.path!).readAsBytes(), bytes);
    },
  );

  test('authorized public downloads may follow provider redirects', () async {
    final directory = await Directory.systemTemp.createTemp(
      'langbai-download-redirect-test-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    const bytes = <int>[9, 8, 7, 6];
    server.listen((request) async {
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/audio.mp3');
      } else {
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    });

    final result = await saveDownload(
      Uri.parse('http://127.0.0.1:${server.port}/redirect'),
      'audio.mp3',
      (_) {},
      destination: SaveDestination.custom,
      customDestinationUri: directory.path,
      followRedirects: true,
    );

    expect(await File(result.path!).readAsBytes(), bytes);
  });
}
