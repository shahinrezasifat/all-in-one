import 'package:http/http.dart' as http;

typedef DownloadSize = ({int bytes, bool estimated});

Future<int?> probeResourceBytes(
  http.Client client,
  Uri uri,
  Map<String, String> headers,
) async {
  Future<int?> request(String method) async {
    try {
      final request = http.Request(method, uri)..headers.addAll(headers);
      request.headers.removeWhere((key, _) =>
          const {'accept-encoding', 'range'}.contains(key.toLowerCase()));
      request.headers['Accept-Encoding'] = 'identity';
      if (method == 'GET') request.headers['Range'] = 'bytes=0-0';
      final response = await client.send(request).timeout(const Duration(seconds: 2));
      await response.stream.listen((_) {}).cancel();
      final contentType = response.headers['content-type'] ?? '';
      if (contentType.contains('html') || contentType.contains('json')) return null;
      final int? total;
      if (response.statusCode == 206) {
        final range = response.headers['content-range'] ?? '';
        total = int.tryParse(range.split('/').last);
      } else if (response.statusCode == 200) {
        total = response.contentLength;
      } else {
        total = null;
      }
      return total != null && total > 0 ? total : null;
    } on Exception {
      return null;
    }
  }

  final declared = int.tryParse(uri.queryParameters['clen'] ?? '');
  if (uri.host.endsWith('.googlevideo.com')) {
    return declared != null && declared > 0 ? declared : null;
  }
  return await request('HEAD') ?? await request('GET');
}

Future<DownloadSize?> probeSegmentedSize(
  List<String> segments, {
  String? initSegment,
  required Future<int?> Function(String url) probe,
}) async {
  if (segments.isEmpty) return null;
  final indexes = {0, segments.length ~/ 2, segments.length - 1};
  final sizes = await Future.wait([
    for (final i in indexes) probe(segments[i]),
    if (initSegment != null) probe(initSegment),
  ]);
  final sampled = sizes.take(indexes.length).whereType<int>().toList();
  if (sampled.isEmpty) return null;
  final sum = sampled.fold(0, (total, size) => total + size);
  final initBytes = initSegment == null ? 0 : sizes.last;
  return (
    bytes: (sum * segments.length / sampled.length).round() + (initBytes ?? 0),
    estimated: sampled.length != segments.length || initBytes == null,
  );
}
