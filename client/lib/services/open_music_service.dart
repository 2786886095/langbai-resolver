import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/media_models.dart';

class OpenMusicService {
  OpenMusicService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<MusicSearchResult>> search(String query, {int limit = 60}) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final buckets = await Future.wait([
      _safe(() => _archive(term, 20)),
      _safe(() => _commons(term, 16)),
      _safe(() => _audius(term, 20)),
      _safe(() => _apple(term, 20)),
      _safe(() => _musicBrainz(term, 20)),
    ]);
    final merged = <MusicSearchResult>[];
    final positions = List<int>.filled(buckets.length, 0);
    final seen = <String>{};
    while (merged.length < limit) {
      var added = false;
      for (var index = 0; index < buckets.length; index++) {
        if (positions[index] >= buckets[index].length) continue;
        final item = buckets[index][positions[index]++];
        added = true;
        final key = '${item.title}${item.creator ?? ''}'
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');
        if (key.isNotEmpty && !seen.add(key)) continue;
        merged.add(item);
        if (merged.length >= limit) break;
      }
      if (!added) break;
    }
    return merged;
  }

  Future<List<MusicFile>> files(String identifier) async {
    final separator = identifier.indexOf(':');
    final source =
        separator < 0 ? 'internet_archive' : identifier.substring(0, separator);
    final value =
        separator < 0 ? identifier : identifier.substring(separator + 1);
    return switch (source) {
      'internet_archive' => _archiveFiles(value),
      'wikimedia_commons' => _commonsFiles(value),
      'audius' => _audiusFiles(value),
      _ => const [],
    };
  }

  Future<List<MusicSearchResult>> _archive(String query, int limit) async {
    final uri = Uri.https('archive.org', '/advancedsearch.php', {
      'q': 'mediatype:audio AND ($query)',
      'fl[]': 'identifier,title,creator,year',
      'rows': '$limit',
      'page': '1',
      'output': 'json',
      'sort[]': 'downloads desc',
    });
    final data = await _getMap(uri);
    final docs = ((data['response'] as Map?)?['docs'] as List?) ?? const [];
    return docs
        .whereType<Map>()
        .map((raw) {
          final item = raw.cast<String, dynamic>();
          final id = item['identifier']?.toString() ?? '';
          final creatorValue = item['creator'];
          final creator = creatorValue is List
              ? creatorValue.take(3).join(', ')
              : creatorValue?.toString();
          return MusicSearchResult(
            identifier: 'internet_archive:$id',
            title: item['title']?.toString() ?? id,
            itemUrl: 'https://archive.org/details/${Uri.encodeComponent(id)}',
            source: 'internet_archive',
            sourceLabel: 'Internet Archive',
            canDownload: true,
            creator: creator,
            year: item['year']?.toString(),
            license: '开放授权 / 公共领域（以资源页为准）',
          );
        })
        .where((item) => item.identifier.length > 17)
        .toList(growable: false);
  }

  Future<List<MusicSearchResult>> _musicBrainz(String query, int limit) async {
    final data =
        await _getMap(Uri.https('musicbrainz.org', '/ws/2/recording/', {
      'query': query,
      'fmt': 'json',
      'limit': '$limit',
      'dismax': 'true',
    }));
    final items = data['recordings'] as List? ?? const [];
    return items
        .whereType<Map>()
        .map((raw) {
          final item = raw.cast<String, dynamic>();
          final id = item['id']?.toString() ?? '';
          final credits = item['artist-credit'] as List? ?? const [];
          final creator = credits
              .whereType<Map>()
              .map((credit) {
                return '${credit['name'] ?? ''}${credit['joinphrase'] ?? ''}';
              })
              .join()
              .trim();
          final released = item['first-release-date']?.toString() ?? '';
          final length = (item['length'] as num?)?.toInt();
          return MusicSearchResult(
            identifier: 'musicbrainz:$id',
            title: item['title']?.toString() ?? id,
            itemUrl: 'https://musicbrainz.org/recording/$id',
            source: 'musicbrainz',
            sourceLabel: 'MusicBrainz',
            canDownload: false,
            creator: creator.isEmpty ? null : creator,
            year: released.length >= 4 ? released.substring(0, 4) : null,
            durationSeconds: length == null ? null : length ~/ 1000,
          );
        })
        .where((item) => item.identifier.length > 12)
        .toList(growable: false);
  }

  Future<List<MusicSearchResult>> _apple(String query, int limit) async {
    final data = await _getMap(Uri.https('itunes.apple.com', '/search', {
      'term': query,
      'media': 'music',
      'entity': 'song',
      'country': 'CN',
      'limit': '$limit',
      'lang': 'zh_cn',
    }));
    final items = data['results'] as List? ?? const [];
    return items
        .whereType<Map>()
        .map((raw) {
          final item = raw.cast<String, dynamic>();
          final id = item['trackId']?.toString() ?? '';
          final released = item['releaseDate']?.toString() ?? '';
          final artwork = item['artworkUrl100']
              ?.toString()
              .replaceAll('100x100', '600x600');
          final duration = (item['trackTimeMillis'] as num?)?.toInt();
          return MusicSearchResult(
            identifier: 'apple_music:$id',
            title: item['trackName']?.toString() ?? id,
            itemUrl:
                item['trackViewUrl']?.toString() ?? 'https://music.apple.com',
            source: 'apple_music',
            sourceLabel: 'Apple Music',
            canDownload: false,
            creator: item['artistName']?.toString(),
            year: released.length >= 4 ? released.substring(0, 4) : null,
            artworkUrl: artwork,
            album: item['collectionName']?.toString(),
            durationSeconds: duration == null ? null : duration ~/ 1000,
          );
        })
        .where((item) => item.identifier.length > 12)
        .toList(growable: false);
  }

  Future<List<MusicSearchResult>> _audius(String query, int limit) async {
    final data = await _getMap(Uri.https('api.audius.co', '/v1/tracks/search', {
      'query': query,
      'limit': '$limit',
      'sort_method': 'relevant',
    }));
    final items = data['data'] as List? ?? const [];
    return items
        .whereType<Map>()
        .map((raw) {
          final item = raw.cast<String, dynamic>();
          final id = item['id']?.toString() ?? '';
          final user =
              (item['user'] as Map?)?.cast<String, dynamic>() ?? const {};
          final preview =
              (item['preview'] as Map?)?.cast<String, dynamic>() ?? const {};
          final download =
              (item['download'] as Map?)?.cast<String, dynamic>() ?? const {};
          final artwork =
              (item['artwork'] as Map?)?.cast<String, dynamic>() ?? const {};
          final permalink = item['permalink']?.toString() ?? '';
          return MusicSearchResult(
            identifier: 'audius:$id',
            title: item['title']?.toString() ?? id,
            itemUrl: permalink.isEmpty
                ? 'https://audius.co'
                : 'https://audius.co$permalink',
            source: 'audius',
            sourceLabel: 'Audius',
            canDownload:
                item['is_downloadable'] == true && download['url'] != null,
            creator: user['name']?.toString() ?? user['handle']?.toString(),
            previewUrl: preview['url']?.toString(),
            artworkUrl: artwork['480x480']?.toString(),
            durationSeconds: (item['duration'] as num?)?.toInt(),
            license: item['license']?.toString(),
          );
        })
        .where((item) => item.identifier.length > 8)
        .toList(growable: false);
  }

  Future<List<MusicSearchResult>> _commons(String query, int limit) async {
    final data =
        await _getMap(Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'generator': 'search',
      'gsrsearch': '$query filetype:audio',
      'gsrnamespace': '6',
      'gsrlimit': '$limit',
      'prop': 'imageinfo|info',
      'iiprop': 'url|mime|size|extmetadata',
      'inprop': 'url',
      'iiextmetadatalanguage': 'zh',
    }));
    final queryData =
        (data['query'] as Map?)?.cast<String, dynamic>() ?? const {};
    final pages = (queryData['pages'] as Map?)?.values.whereType<Map>() ??
        const Iterable.empty();
    final results = <MusicSearchResult>[];
    for (final raw in pages) {
      final item = raw.cast<String, dynamic>();
      final infoItems = item['imageinfo'] as List? ?? const [];
      if (infoItems.isEmpty || infoItems.first is! Map) continue;
      final info = (infoItems.first as Map).cast<String, dynamic>();
      if (!(info['mime']?.toString().startsWith('audio/') ?? false)) continue;
      final metadata =
          (info['extmetadata'] as Map?)?.cast<String, dynamic>() ?? const {};
      final pageId = item['pageid']?.toString() ?? '';
      final title =
          item['title']?.toString().replaceFirst('File:', '') ?? pageId;
      results.add(MusicSearchResult(
        identifier: 'wikimedia_commons:$pageId',
        title: _metadata(metadata, 'ObjectName') ?? title,
        itemUrl: item['canonicalurl']?.toString() ??
            info['descriptionurl']?.toString() ??
            '',
        source: 'wikimedia_commons',
        sourceLabel: 'Wikimedia Commons',
        canDownload: true,
        creator: _metadata(metadata, 'Artist') ?? _metadata(metadata, 'Credit'),
        previewUrl: info['url']?.toString(),
        license: _metadata(metadata, 'LicenseShortName') ??
            _metadata(metadata, 'UsageTerms'),
      ));
    }
    return results;
  }

  Future<List<MusicFile>> _archiveFiles(String identifier) async {
    final data = await _getMap(Uri.https(
        'archive.org', '/metadata/${Uri.encodeComponent(identifier)}'));
    final items = data['files'] as List? ?? const [];
    final results = <MusicFile>[];
    for (final raw in items.whereType<Map>()) {
      final item = raw.cast<String, dynamic>();
      final name = item['name']?.toString() ?? '';
      final extension =
          name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (!const {'flac', 'wav', 'mp3', 'm4a', 'ogg', 'opus'}
          .contains(extension)) {
        continue;
      }
      results.add(MusicFile(
        name: name,
        format: item['format']?.toString() ?? extension.toUpperCase(),
        downloadUrl:
            'https://archive.org/download/${Uri.encodeComponent(identifier)}/${Uri.encodeComponent(name)}',
        size: int.tryParse(item['size']?.toString() ?? ''),
      ));
    }
    results.sort((a, b) => (a.format.toLowerCase().contains('flac') ? 0 : 1)
        .compareTo(b.format.toLowerCase().contains('flac') ? 0 : 1));
    return results.take(80).toList(growable: false);
  }

  Future<List<MusicFile>> _commonsFiles(String pageId) async {
    final data =
        await _getMap(Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'pageids': pageId,
      'prop': 'imageinfo',
      'iiprop': 'url|mime|size',
    }));
    final pages = ((data['query'] as Map?)?['pages'] as Map?) ?? const {};
    final page = pages[pageId] as Map?;
    final infos = page?['imageinfo'] as List? ?? const [];
    if (infos.isEmpty || infos.first is! Map) return const [];
    final info = (infos.first as Map).cast<String, dynamic>();
    final url = info['url']?.toString() ?? '';
    if (url.isEmpty) return const [];
    return [
      MusicFile(
        name: Uri.parse(url).pathSegments.last,
        format:
            info['mime']?.toString().split('/').last.toUpperCase() ?? 'AUDIO',
        downloadUrl: url,
        size: (info['size'] as num?)?.toInt(),
      ),
    ];
  }

  Future<List<MusicFile>> _audiusFiles(String identifier) async {
    final data =
        await _getMap(Uri.https('api.audius.co', '/v1/tracks/$identifier'));
    final item = (data['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final download =
        (item['download'] as Map?)?.cast<String, dynamic>() ?? const {};
    final url = item['is_downloadable'] == true
        ? download['url']?.toString() ?? ''
        : '';
    if (url.isEmpty) return const [];
    return [
      MusicFile(
        name: item['orig_filename']?.toString() ??
            '${item['title'] ?? identifier}.mp3',
        format: '原始音频',
        downloadUrl: url,
      ),
    ];
  }

  Future<Map<String, dynamic>> _getMap(Uri uri) async {
    final response = await _client.get(uri, headers: const {
      'user-agent':
          'langbai-resolver/1.0.3 (https://github.com/2786886095/langbai-resolver)',
    }).timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OpenMusicException('音乐来源返回 ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const OpenMusicException('音乐来源返回格式不正确');
    return decoded.cast<String, dynamic>();
  }

  Future<List<MusicSearchResult>> _safe(
    Future<List<MusicSearchResult>> Function() action,
  ) async {
    try {
      return await action();
    } on Object {
      return const [];
    }
  }

  String? _metadata(Map<String, dynamic> metadata, String key) {
    final value = metadata[key];
    final text = value is Map ? value['value']?.toString() : value?.toString();
    if (text == null) return null;
    final clean = text
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return clean.isEmpty ? null : clean;
  }

  void close() => _client.close();
}

class OpenMusicException implements Exception {
  const OpenMusicException(this.message);

  final String message;

  @override
  String toString() => message;
}
