import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:snaptube_pure/services/provider_engine/provider_context.dart';
import 'package:snaptube_pure/services/provider_engine/provider_models.dart';

void main() {
  test('HDHub4u JS provider runs in QuickJS: search -> detail -> real stream',
      () async {
    const repoBase =
        'https://raw.githubusercontent.com/Spyou/zangetsu-providers/main';
    final jsRes = await http.get(Uri.parse('$repoBase/providers/hdhub4u.js'));
    expect(jsRes.statusCode, 200);
    final js = utf8.decode(jsRes.bodyBytes);

    final ctx = ProviderContext(id: 'hdhub4u', name: 'HDHub4u', jsSource: js);
    // The QuickJS native bridge only ships inside a real app build (APK /
    // linux bundle) — a bare `flutter test` on a dev host has no
    // libquickjs_c_bridge_plugin.so to dlopen. Skip there instead of
    // reporting a false failure; on a device this test runs in full.
    try {
      await ctx.bootstrap();
    } catch (e) {
      markTestSkipped('QuickJS native library unavailable in test host: $e');
      return;
    }

    final results = await ctx.search('dune');
    // ignore: avoid_print
    print('SEARCH RESULTS: ${results.length}');
    for (final r in results.take(5)) {
      // ignore: avoid_print
      print(' - ${r.title} :: ${r.url}');
    }
    expect(results, isNotEmpty, reason: 'provider search returned nothing');

    final target = results.first;
    final detail = await ctx.getDetail(target.url);
    expect(detail, isNotNull);
    // ignore: avoid_print
    print('DETAIL: ${detail!.title} episodes=${detail.episodes.length}');

    final epUrl =
        detail.episodes.isNotEmpty ? detail.episodes.first.url : target.url;
    final List<ProviderStream> streams = await ctx.getVideoSources(epUrl);
    // ignore: avoid_print
    print('STREAMS: ${streams.length}');
    for (final s in streams) {
      // ignore: avoid_print
      print(' * [${s.container}] ${s.quality} ${s.label} -> ${s.url}');
    }
    expect(streams, isNotEmpty, reason: 'no real stream resolved');
    expect(streams.any((s) => s.url.startsWith('http')), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
