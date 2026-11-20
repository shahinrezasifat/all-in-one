import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import 'js_prelude.dart';
import 'provider_models.dart';

/// A single Zangetsu JS provider executing inside its own QuickJS context.
///
/// The context is bootstrapped with [kJsPrelude] (host `fetch` + helpers) and
/// then the provider's scraped JS source. All network happens through the
/// `provFetch` message channel: JavaScript calls it synchronously, Dart runs
/// the request with `package:http` and resolves the matching JS promise when it
/// completes — so the UI isolate is never blocked and HTTPS + real response
/// bodies work (the built-in flutter_js XHR mangles bodies and is HTTP-only).
class ProviderContext {
  final String id;
  final String name;
  final String jsSource;
  final Map<String, String>? staticHeaders;

  late final JavascriptRuntime _rt;
  bool _runtimeCreated = false;
  final http.Client _client = http.Client();
  bool _bootstrapped = false;
  bool _disposed = false;

  ProviderContext({
    required this.id,
    required this.name,
    required this.jsSource,
    this.staticHeaders,
  });

  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    // xhr:false → do NOT install flutter_js's built-in async XHR/fetch; our
    // prelude defines its own `fetch`. handlePromises is always enabled.
    _rt = getJavascriptRuntime(xhr: false);
    _runtimeCreated = true;
    _rt.onMessage('provFetch', _onFetchChannel);
    _evalChecked(kJsPrelude, 'prelude');
    _evalChecked('__SOURCE_ID = ${jsonEncode(id)};', 'source-id');
    _evalChecked(jsSource, 'provider:$name');
    _bootstrapped = true;
  }

  JsEvalResult _evalChecked(String code, String label) {
    final res = _rt.evaluate(code);
    if (res.isError) {
      throw StateError('JS evaluate failed [$label]: ${res.stringResult}');
    }
    return res;
  }

  // ── fetch bridge ─────────────────────────────────────────────────────────
  void _onFetchChannel(dynamic args) {
    try {
      final list = args as List;
      final jsId = list[0];
      final method = (list[1] ?? 'GET').toString();
      final url = Uri.parse(list[2].toString());
      final headersRaw = list[3];
      final body = list.length > 4 ? list[4] : null;

      final headers = <String, String>{};
      if (headersRaw is Map) {
        headersRaw.forEach(
          (k, v) => headers[k.toString()] = v?.toString() ?? '',
        );
      }
      staticHeaders?.forEach((k, v) => headers.putIfAbsent(k, () => v));

      _runFetch(jsId, method, url, headers, body);
    } catch (e) {
      // Malformed request; nothing to resolve against.
    }
  }

  Future<void> _runFetch(
    dynamic jsId,
    String method,
    Uri url,
    Map<String, String> headers,
    dynamic body,
  ) async {
    final completer = Completer<void>();
    try {
      final request = http.Request(method.toUpperCase(), url);
      request.headers.addAll(headers);
      if (body != null) request.body = body.toString();

      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 22));
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 22));

      final respMap = <String, dynamic>{
        'status': streamed.statusCode,
        'statusText': '',
        'url': (streamed.request?.url ?? url).toString(),
        'headers': response.headers,
        'body': utf8.decode(response.bodyBytes, allowMalformed: true),
      };
      _resolve(jsId, jsonEncode(respMap));
    } on TimeoutException {
      _reject(jsId, 'timeout');
    } catch (e) {
      _reject(jsId, e.toString());
    } finally {
      completer.complete();
    }
  }

  void _resolve(dynamic jsId, String respJsonDoubleEncoded) {
    if (_disposed || !_bootstrapped) return;
    try {
      // Double-encode so the raw JSON (which may hold HTML/backslashes/newlines)
      // becomes a safe JS string literal — no template-literal corruption.
      _rt.evaluate(
        '__provResolve($jsId, ${jsonEncode(respJsonDoubleEncoded)});',
      );
    } catch (_) {}
  }

  void _reject(dynamic jsId, String msg) {
    if (_disposed || !_bootstrapped) return;
    try {
      _rt.evaluate('__provReject($jsId, ${jsonEncode(msg)});');
    } catch (_) {}
  }

  // ── public API ────────────────────────────────────────────────────────────
  /// Evaluates a provider call. QuickJS converts a returned Promise into a
  /// Dart [Future] whose completion value is already a Dart Map/List (deep
  /// converted), so we await it directly — pumping the JS microtask queue the
  /// whole time so the async `fetch` continuations keep running.
  Future<dynamic> _call(String expr, {Duration? timeout}) async {
    await bootstrap();
    final res = _rt.evaluate(expr);
    if (res.isError) {
      throw StateError('provider call failed: ${res.stringResult}');
    }
    final raw = res.rawResult;
    if (raw is Future) {
      return await _awaitPromise(raw, timeout ?? const Duration(seconds: 40));
    }
    return raw;
  }

  Future<dynamic> _awaitPromise(
    Future<dynamic> future,
    Duration timeout,
  ) async {
    final pump = Timer.periodic(const Duration(milliseconds: 12), (_) {
      try {
        _rt.executePendingJob();
      } catch (_) {}
    });
    try {
      final value = await future.timeout(timeout);
      try {
        _rt.executePendingJob();
      } catch (_) {}
      return value;
    } finally {
      pump.cancel();
    }
  }

  Future<List<ProviderMeta>> search(String query, {int page = 1}) async {
    final arg = 'search(${jsonEncode(query)}, $page, {})';
    final data = await _call(arg);
    return _asMetaList(data);
  }

  Future<List<ProviderMeta>> browse({int page = 1}) async {
    final hasHome =
        _rt.evaluate("typeof getHome === 'function'").stringResult == 'true';
    if (page == 1 && hasHome) {
      final rows = await getHome();
      final items = rows.expand((row) => row.items).toList();
      if (items.isNotEmpty) return items;
    }
    final hasPopular =
        _rt.evaluate("typeof popular === 'function'").stringResult == 'true';
    if (!hasPopular) return const [];
    return _asMetaList(
      await _call('popular($page, {category: "sub", dateRange: 7})'),
    );
  }

  Future<List<ProviderHomeRow>> getHome() async {
    final data = await _call('getHome({category: "sub"})');
    final rows = <ProviderHomeRow>[];
    if (data is List) {
      for (final r in data) {
        if (r is Map)
          rows.add(ProviderHomeRow.fromJson(Map<String, dynamic>.from(r)));
      }
    }
    return rows;
  }

  Future<ProviderMeta?> getDetail(String url) async {
    final data = await _call('getDetail(${jsonEncode(url)}, {})');
    if (data is Map)
      return ProviderMeta.fromJson(Map<String, dynamic>.from(data));
    return null;
  }

  Future<List<ProviderEpisode>> getEpisodes(String url) async {
    final hasEpisodes =
        _rt.evaluate("typeof getEpisodes === 'function'").stringResult ==
        'true';
    if (hasEpisodes) {
      final arg = jsonEncode(url);
      final data = await _call('getEpisodes($arg, {})');
      if (data is List && data.isNotEmpty) {
        return [
          for (final episode in data)
            if (episode is Map)
              ProviderEpisode.fromJson(Map<String, dynamic>.from(episode)),
        ];
      }
    }
    final detail = await getDetail(url);
    return detail?.episodes ?? const [];
  }

  Future<List<ProviderStream>> getVideoSources(String episodeUrl) async {
    final data = await _call(
      'getVideoSources(${jsonEncode(episodeUrl)})',
      timeout: const Duration(seconds: 45),
    );
    final out = <ProviderStream>[];
    if (data is List) {
      for (final s in data) {
        if (s is Map) {
          final st = ProviderStream.fromJson(Map<String, dynamic>.from(s));
          if (st.url.isNotEmpty) out.add(st);
        }
      }
    }
    return out;
  }

  static List<ProviderMeta> _asMetaList(dynamic data) {
    final out = <ProviderMeta>[];
    if (data is List) {
      for (final m in data) {
        if (m is Map) {
          final meta = ProviderMeta.fromJson(Map<String, dynamic>.from(m));
          if (meta.title.isNotEmpty) out.add(meta);
        }
      }
    } else if (data is Map && data['items'] is List) {
      // Some providers wrap lists in {items:[...]}.
      for (final m in (data['items'] as List)) {
        if (m is Map)
          out.add(ProviderMeta.fromJson(Map<String, dynamic>.from(m)));
      }
    }
    return out;
  }

  void dispose() {
    _disposed = true;
    try {
      _client.close();
    } catch (_) {}
    if (_runtimeCreated) {
      try {
        _rt.dispose();
      } catch (_) {}
    }
  }
}
