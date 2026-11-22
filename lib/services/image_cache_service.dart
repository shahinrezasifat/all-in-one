import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent 50 MB media cache (disk LRU + in-memory hot layer).
///
/// Why this exists: every poster/thumbnail in the app was re-downloaded on
/// each scroll and each fresh launch (Flutter's built-in ImageCache is
/// memory-only), which is the main source of the "heavy, laggy" feeling.
/// This service stores the raw bytes of every image ON DISK inside a strict
/// 50 MB LRU budget, keeps a small in-memory hot layer on top, and can
/// PRELOAD art in the background the moment a list of results arrives —
/// so by the time a tile scrolls into view the picture is already local and
/// paints instantly.
///
/// Three layers, always checked in this order:
///   1. memory hot layer  (LRU, ~8 MB of encoded bytes)  → sub-ms paints
///   2. disk cache        (LRU, 50 MB, survives restart) → instant on relaunch
///   3. network           (browser-UA HttpClient, deduped in-flight)
class ImageCacheService {
  ImageCacheService._();

  static final ImageCacheService instance = ImageCacheService._();

  /// Hard disk budget: the cache NEVER grows past this — oldest-used files are
  /// deleted first (LRU), so the app stays light instead of bloating storage.
  static const int maxDiskBytes = 50 * 1024 * 1024; // 50 MB
  static const int _maxMemoryBytes = 8 * 1024 * 1024; // hot layer budget
  static const int _maxFetchBytes = 12 * 1024 * 1024; // per-image sanity cap
  static const int _prefetchConcurrency = 3;

  int _diskBytes = 0;
  int _memoryBytes = 0;
  bool _ready = false;
  String? _dirPath;

  /// url -> decoded bytes (hot layer, access-ordered LRU).
  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();

  /// sha1(url) -> on-disk entry (size + last-used), the LRU index.
  final Map<String, _DiskEntry> _index = {};

  /// Dedup parallel fetches of the same URL (widget rebuild + prefetch race).
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// Background preload queue.
  final List<String> _prefetchQueue = [];
  int _prefetchActive = 0;

  // Browser UA: image CDNs (i.scdn.co, googleusercontent, mzstatic…) 403 the
  // bare Dart client, so all cache fills must present a normal identity.
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36';

  static final HttpClient _client = () {
    // Keep full TLS validation — accepting every certificate would expose
    // every thumbnail/poster request to man-in-the-middle attacks.
    return HttpClient()
      ..userAgent = _userAgent
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 10);
  }();

  /// Restores the on-disk index. Awaited lazily by every entry point, so
  /// nobody has to remember to call it at boot.
  Future<void> init() async {
    if (_ready) return;
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/MediaCache');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dirPath = dir.path;
      _diskBytes = 0;
      _index.clear();
      for (final e in dir.listSync().whereType<File>()) {
        try {
          final stat = e.statSync();
          _index[e.uri.pathSegments.last] = _DiskEntry(
            stat.size,
            stat.modified,
          );
          _diskBytes += stat.size;
        } catch (_) {}
      }
      // A crash mid-write could already have blown the budget — trim now.
      await _evictIfNeeded();
      _ready = true;
    } catch (e) {
      debugPrint('[ImageCache] init failed (memory-only mode): $e');
      _ready = true; // memory layer still works without disk
    }
  }

  bool get isReady => _ready;

  /// Current on-disk usage in bytes (0 until init).
  int get diskBytesUsed => _diskBytes;

  String get diskBytesFormatted {
    final mb = _diskBytes / 1048576;
    if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
    return '${(_diskBytes / 1024).toStringAsFixed(0)} KB';
  }

  // ------------------------------------------------------------------ reads

  /// Returns image bytes for [url]: memory → disk → network (then caches).
  /// Null means the image is unreachable/bad — callers show a placeholder.
  Future<Uint8List?> getBytes(String url) async {
    await init();
    final key = _key(url);
    if (key == null) return null;

    final hot = _memoryGet(url);
    if (hot != null) return hot;

    final onDisk = await _diskGet(key);
    if (onDisk != null) {
      _memoryPut(url, onDisk);
      return onDisk;
    }

    return _fetchAndStore(url, key);
  }

  /// True when bytes are ALREADY local (memory or disk) — prefetch uses this
  /// so it never re-downloads what the UI already has.
  bool isCached(String url) {
    final key = _key(url);
    if (key == null) return false;
    return _memory.containsKey(url) || _index.containsKey(key);
  }

  // ------------------------------------------------------------- background

  /// PRELOAD a batch of art URLs into the cache without waiting: fires right
  /// after a list/search result arrives, so tiles paint from local bytes
  /// when the user scrolls to them. Bounded concurrency, silent on failure.
  void prefetch(Iterable<String> urls) {
    for (final u in urls) {
      if (u.trim().isEmpty || isCached(u)) continue;
      if (_prefetchQueue.contains(u)) continue;
      _prefetchQueue.add(u);
    }
    _drainPrefetch();
  }

  void _drainPrefetch() {
    while (_prefetchActive < _prefetchConcurrency &&
        _prefetchQueue.isNotEmpty) {
      final url = _prefetchQueue.removeAt(0);
      _prefetchActive++;
      unawaited(() async {
        try {
          await getBytes(url);
        } finally {
          _prefetchActive--;
          _drainPrefetch();
        }
      }());
    }
  }

  // ----------------------------------------------------------------- writes

  /// Cache externally-fetched bytes (e.g. a response the caller already has).
  Future<void> store(String url, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    await init();
    final key = _key(url);
    if (key == null) return;
    _memoryPut(url, bytes);
    await _diskPut(key, bytes);
  }

  Future<Uint8List?> _fetchAndStore(String url, String key) async {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final fut = _doFetch(url, key);
    _inFlight[key] = fut;
    try {
      return await fut;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<Uint8List?> _doFetch(String url, String key) async {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      final req = await _client.openUrl('GET', uri);
      req.headers.set(
        HttpHeaders.acceptHeader,
        'image/avif,image/webp,image/apng,image/png,image/*;q=0.8,*/*;q=0.5',
      );
      req.followRedirects = true;
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        await res.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
        if (builder.length > _maxFetchBytes) {
          unawaited(res.drain<void>());
          return null;
        }
      }
      final bytes = builder.toBytes();
      if (bytes.isEmpty) return null;
      _memoryPut(url, bytes);
      await _diskPut(key, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------- memory layer

  Uint8List? _memoryGet(String url) {
    final b = _memory.remove(url);
    if (b == null) return null;
    _memory[url] = b; // re-insert at tail = most recently used
    return b;
  }

  void _memoryPut(String url, Uint8List bytes) {
    final old = _memory.remove(url);
    if (old != null) _memoryBytes -= old.length;
    _memory[url] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > _maxMemoryBytes && _memory.isNotEmpty) {
      final evicted = _memory.remove(_memory.keys.first);
      if (evicted != null) _memoryBytes -= evicted.length;
    }
  }

  // ------------------------------------------------------------- disk layer

  Future<Uint8List?> _diskGet(String key) async {
    final dir = _dirPath;
    final entry = _index[key];
    if (dir == null || entry == null) return null;
    try {
      final f = File('$dir/$key');
      if (!f.existsSync()) {
        _diskBytes -= entry.size;
        _index.remove(key);
        return null;
      }
      entry.lastUsed = DateTime.now();
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _diskPut(String key, Uint8List bytes) async {
    final dir = _dirPath;
    if (dir == null) return;
    try {
      final old = _index[key];
      if (old != null) _diskBytes -= old.size;
      await File('$dir/$key').writeAsBytes(bytes, flush: false);
      _index[key] = _DiskEntry(bytes.length, DateTime.now());
      _diskBytes += bytes.length;
      await _evictIfNeeded();
    } catch (_) {}
  }

  /// Drop least-recently-used files until the whole cache fits the 50 MB
  /// budget again. Never deletes more than needed, never throws.
  Future<void> _evictIfNeeded() async {
    final dir = _dirPath;
    if (dir == null || _diskBytes <= maxDiskBytes) return;
    final byAge = _index.entries.toList()
      ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));
    for (final e in byAge) {
      if (_diskBytes <= maxDiskBytes) break;
      try {
        final f = File('$dir/${e.key}');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      _diskBytes -= e.value.size;
      _index.remove(e.key);
    }
    if (_diskBytes < 0) _diskBytes = 0;
  }

  /// Delete the entire cache (settings screen action).
  Future<void> clear() async {
    await init();
    final dir = _dirPath;
    if (dir != null) {
      try {
        for (final e in Directory(dir).listSync().whereType<File>()) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      } catch (_) {}
    }
    _index.clear();
    _diskBytes = 0;
    _memory.clear();
    _memoryBytes = 0;
    _prefetchQueue.clear();
  }

  // ------------------------------------------------------------------ misc

  static String? _key(String url) {
    final u = url.trim();
    if (u.isEmpty || !(u.startsWith('http://') || u.startsWith('https://'))) {
      return null;
    }
    return crypto.sha1.convert(utf8.encode(u)).toString();
  }
}

class _DiskEntry {
  final int size;
  DateTime lastUsed;
  _DiskEntry(this.size, this.lastUsed);
}
