import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_win_floating/webview_plugin.dart'
    show WindowsWebViewPlatform, WindowsWebViewControllerCreationParams;

import '../models/extract_result.dart';
import '../models/site_model.dart';
import '../services/ad_blocker_service.dart';
import '../services/bookmark_service.dart';
import '../services/extractor_service.dart';
import '../services/movie_repository_service.dart';
import '../services/yt_dlp_service.dart';
import '../theme/app_palette.dart';
import '../widgets/analyze_download_flow.dart';
import '../widgets/format_picker_sheet.dart';
import 'zangetsu_providers_hub_screen.dart';

/// SnapTube-style in-app browser.
/// Opens bookmarks/sites directly INSIDE this screen (never externally),
/// behaves as a plain browser: omnibox, back/forward/reload, and a floating
/// round download button in the top-right corner that pops up on every site.
class BrowserScreen extends StatefulWidget {
  final SiteModel initialSite;
  final VoidCallback? onCloseBrowser;

  /// When embedded in the main navigation shell, the parent owns the system
  /// back gesture. It registers a handler here so it can let the WebView step
  /// back through its own history before falling back to the section stack.
  final void Function(Future<bool> Function()? handler)? onBackHandlerChanged;

  const BrowserScreen({
    super.key,
    required this.initialSite,
    this.onCloseBrowser,
    this.onBackHandlerChanged,
  });

  static void open(BuildContext context, SiteModel site) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (ctx) => BrowserScreen(initialSite: site)),
    );
  }

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  bool _importingRepository = false;

  Future<void> _importRepository(String link) async {
    if (!mounted || _importingRepository) return;
    _importingRepository = true;
    try {
      final url = MovieRepositoryService.normalizeRepoUrl(link);
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty) return;
      final add = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Add CloudStream repository?'),
          content: Text(url),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Add'),
            ),
          ],
        ),
      );
      if (add != true || !mounted) return;
      final added = await MovieRepositoryService.instance.addCustomRepository(
        '',
        url,
      );
      if (!mounted) return;
      if (added) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ZangetsuProvidersHubScreen()),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add the repository.')),
        );
      }
    } finally {
      _importingRepository = false;
    }
  }

  // ---- Shared browser state ----
  final TextEditingController _addressCtrl = TextEditingController();
  final FocusNode _addressFocus = FocusNode();
  String _currentUrl = '';
  String _pageTitle = '';
  bool _pageLoading = false;
  double _progress = 1.0;
  bool _isExtracting = false;

  // ---- Mobile viewport sizing ----
  static String mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
  static double _defaultMobileWidth = 430.0;
  static double _compactMobileWidth = 390.0;
  static double _plusMobileWidth = 480.0;
  double _currentViewportWidth = _defaultMobileWidth;
  bool _isFullScreenMode = true; // Auto-fit to screen/window size by default

  // ---- WebView engine ----
  WebViewController? _controller;
  String? _engineError;
  Timer? _mediaWatcher;
  String _mediaSrc = '';
  bool _mediaDetected = false;
  bool _checkingForMedia = false;
  int _mediaPageRevision = 0;

  void _resetMediaDetection() {
    _mediaSrc = '';
    _mediaDetected = false;
    _mediaPageRevision++;
  }

  /// Real web rendering on platforms with an initialized WebView controller.
  /// On platforms without an embedded web engine, shows the safe media extractor preview.
  bool get _supportsWebView => !kIsWeb && _controller != null;

  @override
  void initState() {
    super.initState();
    _currentUrl = _normalizeInput(widget.initialSite.url);
    _pageTitle = widget.initialSite.title;
    _addressCtrl.text = _currentUrl;
    // Attempt real web rendering. _setupWebView() itself decides if a WebView
    // platform is available and leaves _controller == null otherwise, so it
    // must run unconditionally here (not gated on _supportsWebView, which
    // depends on _controller already being set — a circular check).
    if (!kIsWeb) {
      _setupWebView();
    }
    widget.onBackHandlerChanged?.call(_handleSystemBack);
  }

  @override
  void dispose() {
    widget.onBackHandlerChanged?.call(null);
    _mediaWatcher?.cancel();
    _addressFocus.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  /// Returns true when the WebView consumed the back gesture itself.
  Future<bool> _handleSystemBack() async {
    final controller = _controller;
    if (controller == null) return false;
    try {
      if (await controller.canGoBack()) {
        await controller.goBack();
        return true;
      }
    } catch (_) {
      // A disposed engine must never block navigation.
    }
    return false;
  }

  /// The in-toolbar arrow is an explicit "leave browser" action: it always
  /// returns to the home page, independent of the WebView's own history.
  void _handleToolbarBack() {
    final close = widget.onCloseBrowser;
    if (close != null) {
      close();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation core
  // ---------------------------------------------------------------------------

  String _normalizeInput(String raw) {
    var t = raw.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('http://')) {
      // The app blocks cleartext traffic; upgrade legacy links to HTTPS,
      // except local development servers which are explicitly allowed.
      final uri = Uri.tryParse(t);
      final local =
          uri != null &&
          {
            'localhost',
            '127.0.0.1',
            '[::1]',
            '10.0.2.2',
          }.contains(uri.host);
      if (!local) t = t.replaceFirst('http://', 'https://');
    } else if (!t.startsWith('https://')) {
      if (t.contains('.') && !t.contains(' ')) {
        t = 'https://$t';
      } else {
        return 'https://www.google.com/search?q=${Uri.encodeComponent(t)}';
      }
    }
    // Always prefer mobile version for YouTube
    if (t.startsWith('https://www.youtube.com') ||
        t.startsWith('http://www.youtube.com')) {
      t = t.replaceFirst('www.youtube.com', 'm.youtube.com');
    } else if (t.startsWith('https://youtube.com') ||
        t.startsWith('http://youtube.com')) {
      t = t.replaceFirst('youtube.com', 'm.youtube.com');
    }
    return t;
  }

  /// Navigate inside this browser tab — always internal, never external.
  void _navigateTo(String raw) {
    final url = _normalizeInput(raw);
    if (url.isEmpty) return;
    setState(() {
      _currentUrl = url;
      _addressCtrl.text = url;
      _resetMediaDetection();
    });
    _controller?.loadRequest(Uri.parse(url));
  }

  static String _mediaCheckJs = r'''
(function() {
  function findPlaying(root) {
    var videos = root.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      var video = videos[i];
      if (!video.paused && !video.ended) {
        return { src: video.currentSrc || video.src || '' };
      }
    }
    var frames = root.querySelectorAll('iframe');
    for (var j = 0; j < frames.length; j++) {
      try {
        var child = frames[j].contentDocument;
        var playing = child && findPlaying(child);
        if (playing) return playing;
      } catch (_) {}
    }
    return null;
  }
  return JSON.stringify({
    href: location.href,
    video: findPlaying(document)
  });
})();
''';

  /// Harvests every plausible media URL the live page knows about: <video>/
  /// <audio>/<source> tags, OpenGraph metadata, download links and the actual
  /// network requests (which catches blob:/MSE and HLS streams that have no
  /// usable src attribute). Returns JSON so the Dart side can parse it safely.
  static String _mediaHarvestJs = r'''
(function() {
  try {
    var out = [];
    function add(u) {
      if (!u) return;
      u = String(u).trim();
      if (!u || u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      if (u.indexOf('//') === 0) u = location.protocol + u;
      try { u = new URL(u, location.href).href; } catch (e) { return; }
      if (u.indexOf('http') !== 0) return;
      out.push(u);
    }
    function scan(el) {
      if (!el) return;
      add(el.currentSrc);
      add(el.src);
      add(el.getAttribute && el.getAttribute('data-src'));
      add(el.getAttribute && el.getAttribute('data-video'));
      if (el.querySelectorAll) {
        var ss = el.querySelectorAll('source');
        for (var i = 0; i < ss.length; i++) {
          add(ss[i].src);
          add(ss[i].getAttribute && ss[i].getAttribute('src'));
        }
      }
    }

    var media = document.querySelectorAll('video,audio');
    for (var i = 0; i < media.length; i++) scan(media[i]);

    var metas = document.querySelectorAll('meta[property="og:video"],meta[property="og:video:url"],meta[property="og:video:secure_url"],meta[property="og:audio"],meta[name="twitter:player:stream"]');
    for (var m = 0; m < metas.length; m++) add(metas[m].content);

    var links = document.querySelectorAll('a[href]');
    for (var l = 0; l < links.length; l++) {
      var h = links[l].href || '';
      if (/\.(mp4|webm|mkv|m4v|mov|m3u8|mp3|m4a|aac|flac|opus|ogg|wav)(\?|#|$)/i.test(h)) add(h);
    }

    try {
      var entries = performance.getEntriesByType('resource');
      for (var p = 0; p < entries.length; p++) {
        var n = entries[p].name || '';
        if (/\.(mp4|webm|mkv|m4v|mov|m3u8|mpd|mp3|m4a|aac|flac|opus|ogg|wav)(\?|#|$)/i.test(n) ||
            /videoplayback|\/manifest|\/playlist|\/stream/i.test(n)) add(n);
      }
    } catch (e) {}

    var seen = {}, unique = [];
    for (var k = 0; k < out.length; k++) {
      if (!seen[out[k]]) { seen[out[k]] = 1; unique.push(out[k]); }
    }

    var poster = '';
    var ogImg = document.querySelector('meta[property="og:image"],meta[name="twitter:image"]');
    if (ogImg) poster = ogImg.content || '';

    var author = '';
    var authorEl = document.querySelector('meta[name="author"],meta[name="twitter:creator"],meta[property="og:video:actor"],meta[property="article:author"],.usernameBadgesWrapper a,.bolded[href*="users"],.bolded[href*="channels"],[data-mxptext="uploader"],.channel-name,.uploader-name,.author-name,[itemprop="author"]');
    if (authorEl) {
      author = (authorEl.content || authorEl.textContent || '').trim();
    }

    return JSON.stringify({ title: document.title || '', poster: poster, author: author, urls: unique.slice(0, 50) });
  } catch (e) {
    return JSON.stringify({ title: '', poster: '', urls: [] });
  }
})();
''';

  void _setupWebView() {
    // The floating-surface plugin (WebKitGTK on Linux) is a dartPluginClass,
    // normally auto-registered; register explicitly as a belt-and-braces so a
    // missing registrant can never leave us without a web engine.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows)) {
      if (WebViewPlatform.instance == null) {
        WindowsWebViewPlatform.registerWith();
      }
    }

    if (WebViewPlatform.instance == null) {
      _engineError = 'No WebView platform registered for this device.';
      _controller = null;
      return;
    }

    try {
      _engineError = null;
      PlatformWebViewControllerCreationParams params =
          PlatformWebViewControllerCreationParams();
      // The floating plugin's create* overrides require its own params subtype.
      if (WebViewPlatform.instance is WindowsWebViewPlatform) {
        params = WindowsWebViewControllerCreationParams();
      }

      late final WebViewController controller;
      controller = WebViewController.fromPlatformCreationParams(params)
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(context.palette.card);
      controller.setUserAgent(mobileUserAgent);
      controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (Uri.tryParse(request.url)?.scheme.toLowerCase() ==
                'cloudstreamrepo') {
              if (request.isMainFrame)
                unawaited(_importRepository(request.url));
              return NavigationDecision.prevent;
            }
            if (AdBlockerService.instance.isAdUrl(request.url)) {
              debugPrint('[AdBlocker] Blocked ad navigation: ${request.url}');
              AdBlockerService.instance.recordBlocked();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onProgress: (p) {
            if (mounted) setState(() => _progress = p / 100.0);
            if (AdBlockerService.instance.isEnabled &&
                (p == 15 || p == 40 || p == 70 || p == 90)) {
              controller
                  .runJavaScript(AdBlockerService.instance.getAdBlockerScript())
                  .catchError((_) {});
            }
          },
          onUrlChange: (change) {
            if (mounted && change.url != null) _syncPageUrl(change.url!);
          },
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _pageLoading = true;
              _currentUrl = url;
              _addressCtrl.text = url;
              // A new navigation invalidates the previous page's media.
              _resetMediaDetection();
            });
            controller
                .runJavaScript(
                  AdBlockerService.instance.getResponsiveScreenScript(),
                )
                .catchError((_) {});
            if (AdBlockerService.instance.isEnabled) {
              controller
                  .runJavaScript(AdBlockerService.instance.getAdBlockerScript())
                  .catchError((_) {});
            }
          },
          onPageFinished: (url) async {
            if (!mounted) return;
            setState(() => _pageLoading = false);
            controller
                .runJavaScript(
                  AdBlockerService.instance.getResponsiveScreenScript(),
                )
                .catchError((_) {});
            if (AdBlockerService.instance.isEnabled) {
              controller
                  .runJavaScript(AdBlockerService.instance.getAdBlockerScript())
                  .catchError((_) {});
            }
            try {
              final t = await controller.runJavaScriptReturningResult(
                'document.title',
              );
              final title = t.toString().replaceAll('"', '').trim();
              if (mounted && title.isNotEmpty) {
                setState(() => _pageTitle = title);
              }
            } catch (_) {}
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() => _pageLoading = false);
            if (error.isForMainFrame == true) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to load page: ${error.description}'),
                  behavior: SnackBarBehavior.floating,
                  duration: Duration(seconds: 2),
                ),
              );
            }
          },
        ),
      );
      controller.loadRequest(Uri.parse(_normalizeInput(_currentUrl)));
      _controller = controller;
      _startMediaWatcher();
    } catch (e) {
      debugPrint('WebView initialization failed: $e');
      // Keep the reason visible in the fallback UI instead of swallowing it,
      // so a broken engine shows up as a message rather than a blank page.
      _engineError = '$e';
      _controller = null;
    }
  }

  /// SnapTube-style auto detection: watch the page for playing media; when a
  /// video/audio starts, pop up the download button automatically.
  void _startMediaWatcher() {
    _mediaWatcher?.cancel();
    _mediaWatcher = Timer.periodic(Duration(milliseconds: 1500), (
      _,
    ) async {
      final c = _controller;
      if (c == null || !mounted) return;
      c
          .runJavaScript(AdBlockerService.instance.getResponsiveScreenScript())
          .catchError((_) {});
      if (AdBlockerService.instance.isEnabled) {
        c
            .runJavaScript(AdBlockerService.instance.getAdBlockerScript())
            .catchError((_) {});
        c
            .runJavaScriptReturningResult('window.__tubBlockedAdsCount || 0')
            .then((res) {
              final count =
                  int.tryParse(
                    res.toString().replaceAll(RegExp(r'[^0-9]'), ''),
                  ) ??
                  0;
              if (count > 0 && mounted) {
                AdBlockerService.instance.setPageBlockedCount(count);
              }
            })
            .catchError((_) {});
      }
      if (_pageLoading || _checkingForMedia) return;
      _checkingForMedia = true;
      final revision = _mediaPageRevision;
      try {
        final raw = await c
            .runJavaScriptReturningResult(_mediaCheckJs)
            .timeout(Duration(seconds: 3));
        if (!mounted || revision != _mediaPageRevision) return;
        final state = jsonDecode(_decodeJsResult(raw));
        if (state is! Map<String, dynamic>) return;
        final href = state['href'];
        if (href is! String) return;
        _syncPageUrl(href);
        if (href != _currentUrl) return;
        final video = state['video'];
        if (video is! Map<String, dynamic>) return;
        final source = video['src'];
        final uri = source is String ? Uri.tryParse(source) : null;
        final directSource =
            uri != null && ['http', 'https'].contains(uri.scheme)
            ? uri.toString()
            : '';
        if (!_mediaDetected ||
            (directSource.isNotEmpty && directSource != _mediaSrc)) {
          setState(() {
            _mediaDetected = true;
            _mediaSrc = directSource;
          });
        }
      } catch (_) {
        // A page may navigate or dispose its document during detection.
      } finally {
        _checkingForMedia = false;
      }
    });
  }

  Future<void> _goBack() async {
    final c = _controller;
    if (c != null && await c.canGoBack()) {
      await c.goBack();
    } else if (mounted) {
      if (widget.onCloseBrowser != null) {
        widget.onCloseBrowser!();
      } else {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _goForward() async {
    final c = _controller;
    if (c != null && await c.canGoForward()) {
      await c.goForward();
    }
  }

  void _reloadPage() {
    _controller?.reload();
  }

  // ---------------------------------------------------------------------------
  // Media extraction + download popup
  // ---------------------------------------------------------------------------

  void _syncPageUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        url == _currentUrl) {
      return;
    }
    setState(() {
      _currentUrl = url;
      _resetMediaDetection();
      if (!_addressFocus.hasFocus) _addressCtrl.text = url;
    });
  }

  Future<String> _livePageUrl() async {
    final controller = _controller;
    if (controller != null) {
      try {
        final raw = await controller
            .runJavaScriptReturningResult('location.href')
            .timeout(Duration(seconds: 2));
        final url = _decodeJsResult(raw);
        final uri = Uri.tryParse(url);
        if (uri != null && ['http', 'https'].contains(uri.scheme)) {
          return url;
        }
      } catch (_) {}
    }
    return _currentUrl;
  }

  Future<void> _extractCurrentPage() async {
    if (_isExtracting) return;
    setState(() => _isExtracting = true);
    try {
      final url = await _livePageUrl();
      if (!mounted) return;
      _syncPageUrl(url);
      final youtubeVideo = YtDlpService.youtubeVideoUrl(url);
      if (youtubeVideo != null) {
        await analyzeAndPickFormat(context, url: youtubeVideo);
        return;
      }
      if (YtDlpService.isYouTubeSite(url)) {
        _showDownloadMessage(
          'Open a YouTube video, then tap Download this video.',
        );
        return;
      }
      final result = await _extractWebsiteMedia(url, _mediaSrc);
      if (!mounted) return;
      if (result != null &&
          (result.videoFormats.isNotEmpty || result.audioFormats.isNotEmpty)) {
        FormatPickerSheet.show(context, result);
      } else {
        _showDownloadMessage('No downloadable media found on this page.');
      }
    } catch (error) {
      debugPrint('Browser download analysis failed: $error');
      if (mounted)
        _showDownloadMessage(
          'Could not check this page. Tap Download to retry.',
        );
    } finally {
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  void _showDownloadMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<ExtractResult?> _extractWebsiteMedia(
    String pageUrl,
    String directSrc,
  ) async {
    ExtractResult? result;

    // 1. Known platforms have dedicated extractors.
    final platform = ExtractorService.instance.detectPlatform(pageUrl);
    final nativePlatforms = {
      'TikTok',
      'Instagram',
      'Facebook',
      'Twitter / X',
      'SoundCloud',
      'Vimeo',
      'Dailymotion',
    };
    if (nativePlatforms.contains(platform)) {
      result = await ExtractorService.instance.extract(pageUrl);
    }

    // 2. Ask the live page which media it is actually loading. This is the
    //    crucial step for ordinary websites: it sees <video>/<source> tags,
    //    download links and real network requests (including HLS), then probes
    //    each candidate for a genuine content type/size.
    if (result == null) {
      final harvested = await _harvestPageMedia();
      final candidates = <String>[
        if (directSrc.startsWith('http')) directSrc,
        ...harvested.urls,
      ];
      if (candidates.isNotEmpty) {
        result = await ExtractorService.instance.extractFromCandidates(
          pageUrl,
          candidates,
          pageTitle: harvested.title,
          author: harvested.author,
          thumbnailUrl: harvested.poster,
        );
      }
    }

    // 3. Direct media URL / HTML page fallback (also covers pages whose media
    //    is only present in the server HTML, not the rendered DOM).
    result ??= await ExtractorService.instance.extract(
      directSrc.startsWith('http') ? directSrc : pageUrl,
    );

    if (result == null ||
        (result.videoFormats.isEmpty && result.audioFormats.isEmpty)) {
      try {
        result = await resolveNativeFormats(pageUrl);
      } catch (error) {
        debugPrint('Page media analysis failed: $error');
      }
    }

    return result;
  }

  Future<_HarvestedMedia> _harvestPageMedia() async {
    final controller = _controller;
    if (controller == null) {
      return _HarvestedMedia(title: '', poster: '', urls: []);
    }
    try {
      final raw = await controller
          .runJavaScriptReturningResult(_mediaHarvestJs)
          .timeout(Duration(seconds: 5));
      final text = _decodeJsResult(raw);
      if (text.isEmpty)
        return _HarvestedMedia(title: '', poster: '', urls: []);

      final data = jsonDecode(text);
      if (data is! Map)
        return _HarvestedMedia(title: '', poster: '', urls: []);

      final urls = (data['urls'] is List)
          ? (data['urls'] as List)
                .map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList()
          : <String>[];
      return _HarvestedMedia(
        title: data['title']?.toString() ?? '',
        poster: data['poster']?.toString() ?? '',
        author: data['author']?.toString() ?? '',
        urls: urls,
      );
    } catch (_) {
      return _HarvestedMedia(title: '', poster: '', urls: []);
    }
  }

  /// webview_flutter returns JavaScript strings either raw or JSON-encoded
  /// (double-quoted and escaped) depending on the platform.
  String _decodeJsResult(dynamic raw) {
    var text = raw?.toString() ?? '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) text = decoded;
      } catch (_) {
        text = text.substring(1, text.length - 1);
      }
    }
    return text;
  }

  // ---------------------------------------------------------------------------
  // Bookmarks: only "bookmark this page" from the menu (no visible bars)
  // ---------------------------------------------------------------------------

  Future<void> _bookmarkCurrentPage() async {
    if (_currentUrl.trim().isEmpty) return;
    final title = _pageTitle.isNotEmpty ? _pageTitle : _currentUrl;
    await BookmarkService.instance.addBookmark(title: title, url: _currentUrl);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
        content: Row(
          children: [
            Icon(Icons.star_rounded, color: context.palette.info),
            SizedBox(width: 8),
            Expanded(child: Text('Bookmarked "$title"')),
          ],
        ),
      ),
    );
  }

  void _showBrowserMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    Icons.public_rounded,
                    color: context.palette.primary,
                  ),
                  title: Text(
                    _pageTitle.isNotEmpty ? _pageTitle : _currentUrl,
                    style: TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _currentUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Divider(),
                ListTile(
                  leading: Icon(Icons.arrow_forward_rounded),
                  title: Text('Forward'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _goForward();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.refresh_rounded),
                  title: Text('Reload Page'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _reloadPage();
                  },
                ),
                ListTile(
                  leading: Icon(
                    AdBlockerService.instance.isEnabled
                        ? Icons.shield_rounded
                        : Icons.shield_outlined,
                    color: AdBlockerService.instance.isEnabled
                        ? context.palette.success
                        : context.palette.textSecondary,
                  ),
                  title: Text('uBlock Origin AdBlocker'),
                  subtitle: Text(
                    AdBlockerService.instance.isEnabled
                        ? 'Active • ${AdBlockerService.instance.blockedCount} ads & trackers blocked'
                        : 'Disabled',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showAdBlockerSheet(context);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.security_update_good_rounded,
                    color: context.palette.success,
                  ),
                  title: Text('Bypass Anti-Adblock Popup'),
                  subtitle: Text(
                    'Dismiss any "AdBlocker Detected" warning modal & unlock page',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _bypassAntiAdblock();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.star_outline_rounded,
                    color: context.palette.info,
                  ),
                  title: Text('Bookmark This Page'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _bookmarkCurrentPage();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.download_rounded,
                    color: context.palette.primary,
                  ),
                  title: Text('Extract & Download Media From Page'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _extractCurrentPage();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.copy_rounded),
                  title: Text('Copy Page URL'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: _currentUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('URL copied'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: Icon(Icons.open_in_new_rounded),
                  title: Text('Open in System Browser (optional)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (_currentUrl.isNotEmpty) {
                      launchUrl(
                        Uri.parse(_currentUrl),
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _bypassAntiAdblock() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.runJavaScript(
        AdBlockerService.instance.getBypassAntiAdblockScript(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: context.palette.success),
                SizedBox(width: 8),
                Expanded(child: Text('Anti-adblock bypassed & page unlocked!')),
              ],
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {}
  }

  void _showAdBlockerSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return ListenableBuilder(
          listenable: AdBlockerService.instance,
          builder: (context, _) {
            final adBlock = AdBlockerService.instance;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color:
                                (adBlock.isEnabled
                                        ? context.palette.success
                                        : context.palette.textSecondary)
                                    .withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            adBlock.isEnabled
                                ? Icons.shield_rounded
                                : Icons.shield_outlined,
                            color: adBlock.isEnabled
                                ? context.palette.success
                                : context.palette.textSecondary,
                            size: 28,
                          ),
                        ),
                        SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'uBlock Origin Protection',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                              Text(
                                adBlock.isEnabled
                                    ? '${adBlock.blockedCount} ads & trackers blocked'
                                    : 'Ad protection is turned off',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: adBlock.isEnabled
                                      ? context.palette.success
                                      : context.palette.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: adBlock.isEnabled,
                          activeThumbColor: context.palette.success,
                          onChanged: (val) {
                            adBlock.toggle();
                            if (adBlock.isEnabled && _controller != null) {
                              _controller!
                                  .runJavaScript(adBlock.getAdBlockerScript())
                                  .catchError((_) {});
                            }
                          },
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    Divider(),
                    SizedBox(height: 10),
                    _buildAdBlockFeature(
                      Icons.play_circle_outline_rounded,
                      'Universal Video Ad Auto-Skipper',
                      'Instantly fast-forwards and skips pre-roll & mid-roll ads across YouTube, Dailymotion, JW Player, Video.js, and ANY site.',
                    ),
                    SizedBox(height: 12),
                    _buildAdBlockFeature(
                      Icons.security_update_good_rounded,
                      'Anti-Adblock Defuser & Modal Bypass',
                      'Stubs AdBlock detection scripts and neutralizes "Please disable adblocker" modals automatically.',
                    ),
                    SizedBox(height: 12),
                    _buildAdBlockFeature(
                      Icons.block_rounded,
                      'Pop-up & Pop-under Interception',
                      'Blocks annoying new tab popups, ad spawns, and transparent click-jacker overlays.',
                    ),
                    SizedBox(height: 12),
                    _buildAdBlockFeature(
                      Icons.visibility_off_outlined,
                      'uBlock Origin Filters & Cosmetic Hiding',
                      'Filters 70+ ad networks at network level and strips all banners, overlays, and sponsor slots.',
                    ),
                    SizedBox(height: 18),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _bypassAntiAdblock();
                          },
                          icon: Icon(
                            Icons.security_update_good_rounded,
                            size: 16,
                            color: context.palette.success,
                          ),
                          label: Text(
                            'Bypass Anti-Adblock',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        if (adBlock.blockedCount > 0)
                          TextButton(
                            onPressed: () => adBlock.resetCounter(),
                            child: Text(
                              'Reset Counter',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: context.palette.primary,
                            foregroundColor: context.palette.background,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _reloadPage();
                          },
                          icon: Icon(Icons.refresh_rounded, size: 17),
                          label: Text(
                            'Reload Page',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAdBlockFeature(IconData icon, String title, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: context.palette.primary),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
              SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(fontSize: 12, color: context.palette.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showViewportSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.smartphone_rounded,
                      color: context.palette.primary,
                      size: 24,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Browser Display Size',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6),
                Text(
                  'Choose the viewport size for browsing sites.',
                  style: TextStyle(fontSize: 12.5, color: context.palette.textSecondary),
                ),
                SizedBox(height: 14),
                _buildViewportOption(
                  ctx,
                  title: 'Auto-Fit Screen (অটো-ফিট স্ক্রিন)',
                  subtitle: 'Automatically resize and fit 100% of your screen/window size',
                  width: 0,
                  selected: _isFullScreenMode,
                ),
                _buildViewportOption(
                  ctx,
                  title: 'Mobile Standard (430px)',
                  subtitle: 'Default phone screen (Pixel 8 / Galaxy S24)',
                  width: _defaultMobileWidth,
                  selected:
                      !_isFullScreenMode &&
                      _currentViewportWidth == _defaultMobileWidth,
                ),
                _buildViewportOption(
                  ctx,
                  title: 'Mobile Compact (390px)',
                  subtitle: 'Compact phone screen (iPhone standard)',
                  width: _compactMobileWidth,
                  selected:
                      !_isFullScreenMode &&
                      _currentViewportWidth == _compactMobileWidth,
                ),
                _buildViewportOption(
                  ctx,
                  title: 'Mobile Max / Plus (480px)',
                  subtitle: 'Larger phone screen (Pro Max / Plus size)',
                  width: _plusMobileWidth,
                  selected:
                      !_isFullScreenMode &&
                      _currentViewportWidth == _plusMobileWidth,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildViewportOption(
    BuildContext ctx, {
    required String title,
    required String subtitle,
    required double width,
    required bool selected,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(
        width == 0 ? Icons.desktop_windows_rounded : Icons.smartphone_rounded,
        color: selected ? context.palette.primary : context.palette.textSecondary,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          color: selected ? context.palette.primary : null,
        ),
      ),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 11.5)),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: context.palette.primary)
          : null,
      onTap: () {
        setState(() {
          if (width == 0) {
            _isFullScreenMode = true;
          } else {
            _isFullScreenMode = false;
            _currentViewportWidth = width;
          }
        });
        _controller
            ?.runJavaScript(
              AdBlockerService.instance.getResponsiveScreenScript(),
            )
            .catchError((_) {});
        Navigator.pop(ctx);
      },
    );
  }

  Widget _buildDesktopBackButton(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: context.palette.shadowAt(0.15),
            blurRadius: 10,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _handleToolbarBack,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_rounded, size: 17),
                SizedBox(width: 6),
                Text(
                  'Exit Browser',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopViewportBadge(bool isDark) {
    final label = _isFullScreenMode
        ? 'Auto-Fit Screen'
        : 'Mobile (${_currentViewportWidth.toInt()}px)';
    return Container(
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: context.palette.shadowAt(0.15),
            blurRadius: 10,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _showViewportSelector(context),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isFullScreenMode
                      ? Icons.desktop_windows_rounded
                      : Icons.smartphone_rounded,
                  size: 16,
                  color: context.palette.primary,
                ),
                SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(width: 4),
                Icon(Icons.arrow_drop_down_rounded, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileHeader(
    bool isDark,
    Color brandColor, {
    bool isDesktop = false,
  }) {
    final surface = context.palette.card;
    final border = isDark ? context.palette.border : context.palette.card;
    final soft = isDark
        ? context.palette.tint(context.palette.card, .07)
        : context.palette.tint(context.palette.primary, .07);

    return Container(
      padding: EdgeInsets.fromLTRB(8, 10, 8, 10),
      decoration: BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: border)),
        boxShadow: [
          BoxShadow(
            color: context.palette.shadowAt(isDark ? .30 : .06),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _toolbarButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back to home',
            color: isDark ? context.palette.card : context.palette.textPrimary,
            background: soft,
            onTap: _handleToolbarBack,
          ),
          SizedBox(width: 8),
          Expanded(child: _buildAddressBar(isDark, brandColor)),
          SizedBox(width: 8),
          _toolbarButton(
            icon: Icons.download_rounded,
            tooltip: 'Download this video',
            color: context.palette.primary,
            background: context.palette.tint(context.palette.primary, .12),
            onTap: _isExtracting ? null : _extractCurrentPage,
            busy: _isExtracting,
          ),
          SizedBox(width: 6),
          ListenableBuilder(
            listenable: AdBlockerService.instance,
            builder: (context, _) {
              final adBlock = AdBlockerService.instance;
              final isEnabled = adBlock.isEnabled;
              final count = adBlock.blockedCount;
              return _toolbarButton(
                icon: isEnabled ? Icons.shield_rounded : Icons.shield_outlined,
                tooltip: isEnabled
                    ? 'AdBlocker Active ($count blocked)'
                    : 'AdBlocker Disabled',
                color: isEnabled ? context.palette.success : context.palette.textSecondary,
                background: isEnabled
                    ? context.palette.tint(context.palette.success, .12)
                    : soft,
                onTap: () => _showAdBlockerSheet(context),
                badge: isEnabled && count > 0
                    ? (count > 99 ? '99+' : '$count')
                    : null,
              );
            },
          ),
          SizedBox(width: 6),
          _toolbarButton(
            icon: Icons.more_vert_rounded,
            tooltip: 'Menu',
            color: context.palette.textSecondary,
            background: soft,
            onTap: _showBrowserMenu,
          ),
          if (isDesktop) ...[
            SizedBox(width: 2),
            TextButton.icon(
              onPressed: _handleToolbarBack,
              icon: Icon(Icons.close_rounded, size: 16),
              label: Text('Exit Browser', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: context.palette.textSecondary,
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One consistent, softly-tinted round-square action for the browser toolbar.
  Widget _toolbarButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required Color background,
    required VoidCallback? onTap,
    String? badge,
    bool busy = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                busy
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                        ),
                      )
                    : Icon(icon, size: 19, color: color),
                if (badge != null)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: IgnorePointer(
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 1,
                        ),
                        constraints: BoxConstraints(
                          minWidth: 14,
                          minHeight: 14,
                        ),
                        decoration: BoxDecoration(
                          color: context.palette.success,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            color: context.palette.onAccent,
                            fontSize: 8.5,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final brandColor = Color(widget.initialSite.colorHex);

    final page = Scaffold(
      backgroundColor: isDark
          ? context.palette.background
          : context.palette.textSecondary,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screenWidth = constraints.maxWidth;
            final isDesktop = screenWidth > 540;
            final mobileWidth = _isFullScreenMode
                ? screenWidth
                : _currentViewportWidth.clamp(320.0, screenWidth);

            return Stack(
              children: [
                // Centered Mobile Screen Container
                Center(
                  child: Container(
                    width: mobileWidth,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: context.palette.card,
                      border: isDesktop && !_isFullScreenMode
                          ? Border.symmetric(
                              horizontal: BorderSide(
                                color: context.palette.border,
                                width: 1.5,
                              ),
                            )
                          : null,
                      boxShadow: isDesktop && !_isFullScreenMode
                          ? [
                              BoxShadow(
                                color: context.palette.shadowAt(0.35),
                                blurRadius: 30,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                    child: Column(
                      children: [
                        _buildMobileHeader(
                          isDark,
                          brandColor,
                          isDesktop: isDesktop,
                        ),
                        if (_pageLoading)
                          LinearProgressIndicator(
                            value: _progress,
                            minHeight: 2,
                            backgroundColor: brandColor.withValues(alpha: 0.15),
                            color: context.palette.primary,
                          ),
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              (!_supportsWebView || _controller == null)
                                  ? _buildWebPlaceholder(isDark)
                                  : WebViewWidget(controller: _controller!),
                              if (_mediaDetected)
                                Positioned(
                                  right: 16,
                                  bottom: 12,
                                  child: FloatingActionButton(
                                    heroTag: null,
                                    tooltip: 'Download detected video',
                                    backgroundColor: context.palette.primary,
                                    foregroundColor: context.palette.card,
                                    shape: CircleBorder(),
                                    onPressed: _isExtracting
                                        ? null
                                        : _extractCurrentPage,
                                    child: _isExtracting
                                        ? SizedBox.square(
                                            dimension: 23,
                                            child: CircularProgressIndicator(
                                              color: context.palette.card,
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : Icon(Icons.download_rounded),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (isDesktop) ...[
                  if (!_isFullScreenMode)
                    Positioned(
                      top: 14,
                      left: 18,
                      child: _buildDesktopBackButton(isDark),
                    ),
                  Positioned(
                    top: 14,
                    right: 18,
                    child: _buildDesktopViewportBadge(isDark),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );

    // The navigation shell owns the system back gesture for the embedded
    // browser. A standalone, pushed BrowserScreen still handles its own.
    if (widget.onCloseBrowser != null) return page;
    return PopScope(
      canPop: !_supportsWebView,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _goBack();
      },
      child: page,
    );
  }

  Widget _buildWebPlaceholder(bool isDark) {
    final title = _pageTitle.isNotEmpty ? _pageTitle : widget.initialSite.title;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: context.palette.tint(context.palette.primary, 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.public_rounded,
                size: 52,
                color: context.palette.primary,
              ),
            ),
            SizedBox(height: 18),
            Text(
              title,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 6),
            Text(
              _currentUrl,
              style: TextStyle(
                fontSize: 12.5,
                color: context.palette.textSecondary,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: 28),
            if (_engineError != null)
              Padding(
                padding: EdgeInsets.only(bottom: 20),
                child: Text(
                  'Web engine unavailable: $_engineError',
                  style: TextStyle(fontSize: 12, color: context.palette.primary),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.palette.primary,
                    foregroundColor: context.palette.background,
                    padding: EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  onPressed: _extractCurrentPage,
                  icon: Icon(Icons.download_rounded, size: 19),
                  label: Text(
                    'Extract Media From URL',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  onPressed: () {
                    setState(() => _engineError = null);
                    _setupWebView();
                    if (mounted) setState(() {});
                  },
                  icon: Icon(Icons.public_rounded, size: 18),
                  label: Text('Retry In-App Page'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  onPressed: () => launchUrl(
                    Uri.parse(_currentUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text('Open in Browser'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddressBar(bool isDark, Color brandColor) {
    final field = isDark ? context.palette.textSecondary : context.palette.background;
    final border = isDark ? context.palette.border : context.palette.card;
    final hint = context.palette.textSecondary;
    final actionColor = context.palette.textSecondary;

    return LayoutBuilder(
      builder: (context, constraints) {
        // During window resizing / split-screen the header can give this field
        // almost no width. Drop the decorative actions in that case instead of
        // overflowing the Row.
        final compact = constraints.maxWidth < 110;
        return Container(
          height: 40,
          decoration: BoxDecoration(
            color: field,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border),
          ),
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: brandColor.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.public_rounded, size: 14, color: brandColor),
              ),
              SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _addressCtrl,
                  focusNode: _addressFocus,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: isDark ? context.palette.card : context.palette.textPrimary,
                  ),
                  textInputAction: TextInputAction.go,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                    hintText: 'Search or enter URL',
                    hintStyle: TextStyle(fontSize: 12, color: hint),
                  ),
                  onSubmitted: (val) {
                    _addressFocus.unfocus();
                    _navigateTo(val);
                  },
                ),
              ),
              if (!compact)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    if (_pageLoading) {
                      _controller?.loadRequest(Uri.parse('about:blank'));
                    } else {
                      _reloadPage();
                    }
                  },
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      _pageLoading
                          ? Icons.close_rounded
                          : Icons.refresh_rounded,
                      size: 16,
                      color: actionColor,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HarvestedMedia {
  final String title;
  final String poster;
  final String author;
  final List<String> urls;

  _HarvestedMedia({
    required this.title,
    required this.poster,
    this.author = '',
    required this.urls,
  });
}
