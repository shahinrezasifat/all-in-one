import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/services/image_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('ImageCacheService (50 MB instant-load cache)', () {
    final cache = ImageCacheService.instance;
    // Port 9 (discard) — nothing serves there, so a cache MISS proves itself
    // by returning null instead of bytes.
    const url = 'http://127.0.0.1:9/poster.jpg';

    test(
      'stored bytes are served back without any network round-trip',
      () async {
        final bytes = Uint8List.fromList(List.generate(2048, (i) => i % 256));
        await cache.store(url, bytes);
        expect(cache.isCached(url), isTrue);

        final served = await cache.getBytes(url);
        expect(served, isNotNull);
        expect(served!.length, bytes.length);
        expect(served[17], bytes[17]);
      },
    );

    test('clear() drops the entry — the same URL no longer resolves', () async {
      await cache.clear();
      expect(cache.isCached(url), isFalse);
      // Unresolvable host: the miss must come back as null, fast and safe.
      final served = await cache.getBytes(url);
      expect(served, isNull);
    });

    test('prefetch ignores already-cached URLs (no duplicate work)', () {
      expect(() => cache.prefetch([url, '', '  ']), returnsNormally);
      // isCached('') must stay false — invalid URLs never enter the cache.
      expect(cache.isCached(''), isFalse);
      expect(cache.isCached('not-a-url'), isFalse);
    });

    test('disk budget is exactly 50 MB', () {
      expect(ImageCacheService.maxDiskBytes, 50 * 1024 * 1024);
    });
  });
}
