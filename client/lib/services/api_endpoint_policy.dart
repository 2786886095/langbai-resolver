const _loopbackHosts = {'127.0.0.1', 'localhost', '::1'};

bool isLoopbackApiUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      uri.hasAuthority &&
      _loopbackHosts.contains(uri.host.toLowerCase());
}

String selectInstanceTokenForApi(
  String baseUrl, {
  String? explicitToken,
  required String runtimeToken,
}) {
  if (explicitToken != null) return explicitToken.trim();
  return isLoopbackApiUrl(baseUrl) ? runtimeToken.trim() : '';
}

String? normalizeTrustedApiUrl(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final loopback = _loopbackHosts.contains(host);
  if (scheme != 'https' && !loopback) return null;
  try {
    final explicitPort = uri.hasPort ? uri.port : null;
    final omitDefaultPort =
        (scheme == 'https' && explicitPort == 443) ||
        (scheme == 'http' && explicitPort == 80);
    final normalized = Uri(
      scheme: scheme,
      host: host,
      port: omitDefaultPort ? null : explicitPort,
      path: uri.path,
    ).toString();
    return normalized.replaceAll(RegExp(r'/+$'), '');
  } on FormatException {
    return null;
  }
}
