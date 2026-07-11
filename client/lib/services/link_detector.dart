import 'package:flutter/services.dart';

enum DetectedLinkKind { web, direct, magnet, torrent }

class DetectedLink {
  const DetectedLink({required this.value, required this.kind});

  final String value;
  final DetectedLinkKind kind;

  String get label => switch (kind) {
    DetectedLinkKind.web => '网页媒体链接',
    DetectedLinkKind.direct => '媒体直链',
    DetectedLinkKind.magnet => '磁力链接',
    DetectedLinkKind.torrent => '种子链接',
  };
}

class LinkDetector {
  static final _urlPattern = RegExp(
    r'''https?://[^\s<>"']+''',
    caseSensitive: false,
  );
  static final _magnetPattern = RegExp(
    r'''magnet:\?xt=urn:[^\s<>"']+''',
    caseSensitive: false,
  );
  static const _directExtensions = {
    'mp4',
    'mkv',
    'webm',
    'mov',
    'm4v',
    'mp3',
    'm4a',
    'flac',
    'wav',
    'jpg',
    'jpeg',
    'png',
    'webp',
    'zip',
    '7z',
    'rar',
    'pdf',
    'iso',
  };

  Future<DetectedLink?> readClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return detect(data?.text);
  }

  static String? extractHttpUrl(String? input) {
    if (input == null || input.trim().isEmpty) return null;
    final value = _urlPattern.firstMatch(input)?.group(0);
    if (value == null) return null;
    return value.replaceFirst(RegExp(r'''[\)\]}>，。！？；：、]+$'''), '');
  }

  DetectedLink? detect(String? input) {
    if (input == null || input.trim().isEmpty) return null;
    final text = input.trim();
    final magnet = _magnetPattern.firstMatch(text)?.group(0);
    if (magnet != null) {
      return DetectedLink(value: magnet, kind: DetectedLinkKind.magnet);
    }
    final value = extractHttpUrl(text);
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    final extension = uri?.pathSegments.isEmpty ?? true
        ? ''
        : uri!.pathSegments.last.split('.').last.toLowerCase();
    if (extension == 'torrent') {
      return DetectedLink(value: value, kind: DetectedLinkKind.torrent);
    }
    if (_directExtensions.contains(extension)) {
      return DetectedLink(value: value, kind: DetectedLinkKind.direct);
    }
    return DetectedLink(value: value, kind: DetectedLinkKind.web);
  }
}
