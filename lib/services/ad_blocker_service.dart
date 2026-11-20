import 'package:flutter/foundation.dart';

/// Comprehensive uBlock Origin-inspired AdBlocker service.
/// Features:
/// 1. Network-level blocking of 70+ major ad, tracker, and popup domains.
/// 2. Cosmetic CSS element hiding (banners, popups, sponsors, ad players).
/// 3. uBlock Origin defusers & scriptlets (defusing FuckAdBlock, BlockAdBlock, adsbygoogle, etc.).
/// 4. Aggressive pop-up and pop-under suppression & clickjack overlay removal.
/// 5. Universal Video Ad Auto-Skipper for ANY website (YouTube, Dailymotion, JWPlayer, Video.js, HTML5).
/// 6. Universal Anti-Adblock Warning Modal Neutralizer & body scroll restorer.
class AdBlockerService extends ChangeNotifier {
  static final AdBlockerService instance = AdBlockerService._();
  AdBlockerService._();

  bool _isEnabled = true;
  int _blockedCount = 0;

  bool get isEnabled => _isEnabled;
  int get blockedCount => _blockedCount;

  void toggle() {
    _isEnabled = !_isEnabled;
    notifyListeners();
  }

  void recordBlocked() {
    _blockedCount++;
    notifyListeners();
  }

  void resetCounter() {
    _blockedCount = 0;
    notifyListeners();
  }

  void setPageBlockedCount(int count) {
    if (count > _blockedCount) {
      _blockedCount = count;
      notifyListeners();
    }
  }

  /// Extensive uBlock Origin / EasyList / Peter Lowe's ad & tracker domain list.
  static const List<String> adDomains = [
    // Major Ad Networks & Exchanges
    'doubleclick.net',
    'googleads.g.doubleclick.net',
    'pagead2.googlesyndication.com',
    'adservice.google.com',
    'googletagservices.com',
    'googletagmanager.com/gtag/js',
    'adnxs.com',
    'criteo.com',
    'criteo.net',
    'amazon-adsystem.com',
    'taboola.com',
    'outbrain.com',
    'adcolony.com',
    'admob.com',
    'inmobi.com',
    'smartadserver.com',
    'rubiconproject.com',
    'pubmatic.com',
    'openx.net',
    'revcontent.com',
    'bidswitch.net',
    'adroll.com',
    'quantserve.com',
    'moatads.com',
    'scorecardresearch.com',
    'zedo.com',
    'mgid.com',
    'teads.tv',
    'spotxchange.com',
    'spotx.tv',
    'adblade.com',
    'bidtheatre.com',
    'sharethrough.com',
    'yieldmo.com',
    'zergnet.com',
    'casalemedia.com',
    'exponential.com',
    'sovrn.com',
    'lijit.com',
    'adform.net',
    'applovin.com',
    'unity3d.com/ads',
    'vungle.com',
    'chartboost.com',
    'ironsrc.com',
    // Pop-up and Pop-under Ad Networks
    'popads.net',
    'popcash.net',
    'propellerads.com',
    'hilltopads.com',
    'admaven.com',
    'onclickads.net',
    'clickadu.com',
    'adcash.com',
    'yllix.com',
    'monetag.com',
    'adsterra.com',
    'juicyads.com',
    'trafficfactory.biz',
    'exoclick.com',
    'trafficjunky.com',
    'ero-advertising.com',
    'plugrush.com',
    'popmyads.com',
    // Anti-adblock and Paywall tracking scripts
    'blockadblock.com',
    'fuckadblock',
    'admiral.com',
    'getadmiral.com',
    'adblockdetector',
    'fundingchoicesmessages.google.com',
    'antiadblocksystems.com',
    'ad-delivery.net',
    // Additional Global Ad, Tracker & Native Widget Networks
    'google-analytics.com',
    'partner.googleadservices.com',
    'tpc.googlesyndication.com',
    'adclick.g.doubleclick.net',
    '2mdn.net',
    'serving-sys.com',
    'adtechus.com',
    'adsystem.com',
    'adskeeper.co.uk',
    'adskeeper.com',
    'engageya.com',
    'content.ad',
    'an.yandex.ru',
    'mc.yandex.ru',
    'ads.yahoo.com',
    'ads.linkedin.com',
    'static.ads-twitter.com',
    'ads-twitter.com',
    'ezoic.com',
    'adpushup.com',
    // The ad exchange is a.media.net specifically — the bare 'media.net'
    // substring also matches legitimate content CDNs (e.g. streammedia.net).
    'a.media.net',
    'carbonads.net',
    'buysellads.com',
    'bidvertiser.com',
    'trafficstars.com',
    'richaudience.com',
    'contextweb.com',
    'gumgum.com',
    'infolinks.com',
    'propellerads.net',
    'admaven.net',
    'exdynsrv.com',
    'exosrv.com',
    'syndication.exoclick.com',
    'a.magsrv.com',
    'pt.magsrv.com',
    'tsyndicate.com',
    'coinhive.com',
    'coin-hive.com',
  ];

  /// Ad-path markers. Deliberately CONSERVATIVE: player-critical endpoints
  /// (/imasdk/, /vast.xml, /vmap.xml, /vpaid.js, /ad_status, /get_midroll_info,
  /// ?ad_type=...) are NOT blocked here — killing them makes video players hang
  /// on the ad break and trips "disable your blocker / go premium" walls.
  /// Such ads are allowed to load and are instead hidden & auto-skipped.
  static const List<String> adPathPatterns = [
    '/pagead/',
    '/api/stats/ads',
    '/ptracking',
    'ad_break',
    'doubleclick',
    'googlesyndication',
    '/ad-server/',
    'popunder',
    'popup-ad',
    'blockadblock',
    'fuckadblock',
    'getadmiral',
    'adsbygoogle',
    'taboolasyndication',
    'outbrainimg',
    '/pagead2.',
    'google-analytics.com/analytics.js',
    'google-analytics.com/gtag',
    'connect.facebook.net/en_US/fbevents.js',
    '/wp-content/plugins/adrotate',
    '/wp-content/plugins/ad-inserter',
  ];

  /// True when a URL looks like actual media content rather than an ad server
  /// request. Content segments/manifests must never be network-blocked or the
  /// video itself stops playing.
  static bool looksLikeMediaContent(String lowerUrl) {
    const mediaHints = [
      '.mp4',
      '.m3u8',
      '.mpd',
      '.webm',
      '.mov',
      '.avi',
      '.flv',
      'videoplayback',
      'googlevideo.com',
      'mime=video',
      '/hls/',
      '/dash/',
    ];
    for (final hint in mediaHints) {
      if (lowerUrl.contains(hint)) return true;
    }
    return false;
  }

  /// Checks if a navigation or resource URL belongs to an ad server.
  bool isAdUrl(String url) {
    if (!_isEnabled) return false;
    final lower = url.toLowerCase();
    // Never sacrifice real content for an ad block.
    if (looksLikeMediaContent(lower)) return false;
    for (final domain in adDomains) {
      if (lower.contains(domain)) return true;
    }
    for (final pattern in adPathPatterns) {
      if (lower.contains(pattern)) return true;
    }
    return false;
  }

  /// Comprehensive CSS rules that hide ad banners, overlays, sponsor sections,
  /// video ad frames, anti-adblock modals, and popups.
  String getAdBlockerCss() {
    return '''
      /* Universal Banner & Tracking Ads */
      [id^="google_ads_"],
      [id^="div-gpt-ad"],
      [class*="ad-banner"],
      [class*="ad_banner"],
      [class*="banner-ad"],
      [class*="banner_ad"],
      [class*="advertisement"],
      [id*="advertisement"],
      [class*="sponsor"],
      [id*="sponsor"],
      .adsbygoogle,
      .ad-box,
      .ad-container,
      .ad-wrapper,
      .ad-slot,
      .top-ad,
      .bottom-ad,
      .sidebar-ad,
      .sticky-ad,
      .ad-overlay,
      .ad-placeholder,
      .native-ad,
      .native-ad-unit,
      iframe[src*="doubleclick"],
      iframe[src*="googlesyndication"],
      iframe[src*="amazon-adsystem"],
      iframe[src*="adnxs"],
      iframe[src*="taboola"],
      iframe[src*="outbrain"],
      iframe[src*="popads"],
      iframe[src*="propeller"],
      iframe[src*="adsterra"],
      iframe[src*="exoclick"],
      iframe[src*="admaven"],

      /* Pop-up and Pop-under elements */
      div[class*="popup-ad"],
      div[id*="popup-ad"],
      div[class*="popunder"],
      div[id*="popunder"],
      div[class*="ad-modal"],
      div[id*="ad-modal"],
      div[class*="ad-popup"],
      div[id*="ad-popup"],
      div[class*="overlay-ad"],
      div[id*="overlay-ad"],

      /* Universal Video Ad Player Elements */
      .video-ads,
      .ytp-ad-module,
      .ytp-ad-overlay-container,
      .ytp-ad-message-container,
      .ytp-ad-text,
      .ytp-ad-preview-container,
      #player-ads,
      #masthead-ad,
      ytd-promoted-video-renderer,
      ytd-banner-promo-renderer,
      ytd-display-ad-renderer,
      ytd-statement-banner-renderer,
      ytd-in-feed-ad-layout-renderer,
      .ytd-ad-slot-renderer,
      ytd-ad-slot-renderer,
      ytd-companion-slot-renderer,
      ytm-promoted-video-renderer,
      ytm-promoted-sparkles-web-renderer,
      ytm-companion-ad-renderer,
      ytm-ad-slot-renderer,
      ytd-player-legacy-desktop-watch-ads-renderer,
      ytd-action-companion-ad-renderer,
      .sparkles-light-cta,
      #panels.ytd-watch-flexy > ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"],
      .ima-ad-container,
      .ima-ad-overlay,
      .vjs-ad-playing,
      .vjs-ad-overlay,
      .vjs-ad-loading,
      .jw-flag-ads,
      .jw-ad-container,
      .jw-ad-ui,
      .preroll-ad,
      .midroll-ad,
      .video-ad-overlay,
      .vast-ad,
      .vpaid-ad,

      /* Anti-Adblock Modals & Paywalls (uBlock Origin rules) */
      tp-yt-paper-dialog:has(ytd-enforcement-message-view-model),
      ytd-enforcement-message-view-model,
      [class*="adblock-modal"],
      [id*="adblock-modal"],
      [class*="adblocker-modal"],
      [id*="adblocker-modal"],
      [class*="adblock-warning"],
      [id*="adblock-warning"],
      [class*="anti-adblock"],
      [id*="anti-adblock"],
      [class*="adblock-overlay"],
      [id*="adblock-overlay"],
      [class*="adblock-detector"],
      [id*="adblock-detector"],
      [class*="fc-ab-root"],
      [id*="fc-ab-root"],
      [class*="sp_message_container"],
      div[class*="ad-blocker-message"],
      div[id*="ad-blocker-message"] {
        display: none !important;
        visibility: hidden !important;
        opacity: 0 !important;
        pointer-events: none !important;
        width: 0px !important;
        height: 0px !important;
        max-height: 0px !important;
        min-height: 0px !important;
        margin: 0px !important;
        padding: 0px !important;
        overflow: hidden !important;
      }

      /* Universal Screen-Size Auto-Fitting & Responsive Rules */
      html, body {
        max-width: 100% !important;
        overflow-x: hidden !important;
        box-sizing: border-box !important;
      }
      *, *::before, *::after {
        box-sizing: border-box !important;
      }
      img, video, canvas, svg, iframe, embed, object {
        max-width: 100% !important;
      }
      table {
        max-width: 100% !important;
      }
    ''';
  }

  /// Master JavaScript injected on page start/progress/finish/heartbeat.
  /// Includes uBlock Origin scriptlet defusers, popup killers, universal video ad auto-skippers,
  /// active DOM ad element purgers, and network request interceptors.
  String getAdBlockerScript() {
    final css = getAdBlockerCss().replaceAll('\n', ' ').replaceAll("'", "\\'");
    return '''
(function() {
  // 1. Inject or re-verify cosmetic uBlock Origin CSS
  function ensureStyles() {
    try {
      if (!document.getElementById('tub-ublock-styles')) {
        var style = document.createElement('style');
        style.id = 'tub-ublock-styles';
        style.type = 'text/css';
        style.appendChild(document.createTextNode('$css'));
        var target = document.head || document.documentElement || document.body;
        if (target) {
          target.appendChild(style);
        }
      }
    } catch(e) {}
  }
  ensureStyles();

  // Helper: check if a URL string is an ad URL.
  // Conservative policy: on any page that contains a video player we do NOT
  // block network requests at all — those sites stream through their ads, and
  // cutting ad calls makes the video hang or triggers "go premium" walls.
  // Ads there are handled cosmetically (hidden + auto-skipped) instead.
  function looksLikeMediaContent(lower) {
    var hints = ['.mp4', '.m3u8', '.mpd', '.webm', '.mov', '.avi', '.flv',
      'videoplayback', 'googlevideo.com', 'mime=video', '/hls/', '/dash/'];
    for (var i = 0; i < hints.length; i++) {
      if (lower.indexOf(hints[i]) !== -1) return true;
    }
    return false;
  }
  function videoPlayerOnPage() {
    try { return !!document.querySelector('video'); } catch(e) { return false; }
  }
  function isAdUrl(u) {
    if (!u || typeof u !== 'string') return false;
    var lower = u.toLowerCase();
    if (videoPlayerOnPage()) return false;
    if (looksLikeMediaContent(lower)) return false;
    var domains = [
      'doubleclick', 'googleads', 'pagead', 'adservice', 'googlesyndication',
      'googletagservices', 'adnxs', 'criteo', 'amazon-adsystem',
      'taboola', 'outbrain', 'adcolony', 'admob', 'inmobi', 'smartadserver',
      'rubiconproject', 'pubmatic', 'openx', 'revcontent', 'bidswitch', 'adroll',
      'quantserve', 'moatads', 'scorecardresearch', 'zedo', 'mgid', 'teads',
      'spotxchange', 'adblade', 'sharethrough', 'yieldmo', 'casalemedia', 'sovrn',
      'adform', 'applovin', 'unity3d.com/ads', 'vungle', 'chartboost', 'ironsrc',
      'popads', 'popcash', 'propellerads', 'hilltopads', 'admaven', 'onclickads',
      'clickadu', 'adcash', 'yllix', 'monetag', 'adsterra', 'juicyads',
      'trafficfactory', 'exoclick', 'trafficjunky', 'ero-advertising', 'plugrush',
      'popmyads', 'adskeeper', 'engageya', 'ezoic', 'adpushup',
      'a.media.net', 'carbonads', 'buysellads', 'bidvertiser', 'trafficstars',
      'richaudience', 'contextweb', 'gumgum', 'infolinks', 'tsyndicate', 'magsrv',
      'exdynsrv', 'exosrv', 'an.yandex.ru', 'mc.yandex.ru', 'ads.yahoo', 'ads-twitter',
      'adsbygoogle', '/pagead/', '/pagead2.', '/ad-server/', 'ad_break'
    ];
    for (var i = 0; i < domains.length; i++) {
      if (lower.indexOf(domains[i]) !== -1) return true;
    }
    return false;
  }

  // 2. Active DOM Ad Element Purger - Removes ads completely from DOM
  function purgeAllAds() {
    var removedCount = 0;
    try {
      var adSelectors = [
        'ins.adsbygoogle',
        '[class*="adsbygoogle"]',
        '[id*="adsbygoogle"]',
        'iframe[id^="aswift_"]',
        'iframe[name^="aswift_"]',
        'iframe[id^="google_ads_"]',
        'iframe[name^="google_ads"]',
        'iframe[src*="googlesyndication"]',
        'iframe[src*="doubleclick"]',
        'iframe[src*="amazon-adsystem"]',
        'iframe[src*="adnxs"]',
        'iframe[src*="taboola"]',
        'iframe[src*="outbrain"]',
        'iframe[src*="mgid"]',
        'iframe[src*="criteo"]',
        'iframe[src*="popads"]',
        'iframe[src*="propeller"]',
        'iframe[src*="adsterra"]',
        'iframe[src*="admaven"]',
        'iframe[src*="adcash"]',
        'iframe[src*="yllix"]',
        'iframe[src*="monetag"]',
        'iframe[src*="exoclick"]',
        'iframe[src*="tsyndicate"]',
        'iframe[src*="magsrv"]',
        'div[id^="google_ads_"]',
        'div[id^="div-gpt-ad"]',
        'div[id^="dfp-ad"]',
        'div[data-google-query-id]',
        'div[data-ad-slot]',
        'div[data-ad-client]',
        'div[data-ad-unit]',
        '.trc_related_container',
        '.trc_rbox_div',
        '#taboola-below-article-thumbnails',
        'div[id^="taboola-"]',
        '.OUTBRAIN',
        '.ob-widget',
        'div[id^="outbrain_widget"]',
        '.mgbox',
        '[class*="adskeeper"]',
        '[class*="engageya"]',
        'amp-ad',
        'amp-embed',
        '#player-ads',
        '#masthead-ad',
        'ytd-promoted-video-renderer',
        'ytd-banner-promo-renderer',
        'ytd-display-ad-renderer',
        'ytd-ad-slot-renderer',
        '.ytd-ad-slot-renderer',
        'ytd-companion-slot-renderer',
        'ytm-promoted-video-renderer',
        'ytm-promoted-sparkles-web-renderer',
        'ytm-companion-ad-renderer',
        'ytm-ad-slot-renderer',
        '[class*="ad-banner"]',
        '[class*="ad_banner"]',
        '[class*="banner-ad"]',
        '[class*="banner_ad"]',
        '[class*="ad-container"]',
        '[class*="ad_container"]',
        '[class*="ad-slot"]',
        '[class*="ad_slot"]',
        '[class*="ad-wrapper"]',
        '[class*="ad_wrapper"]',
        '[class*="ad-holder"]',
        '[class*="ad-placement"]',
        '[class*="advertisement"]',
        '[id*="advertisement"]',
        '[class*="sponsored-post"]',
        '[class*="sponsored-content"]'
      ];

      for (var s = 0; s < adSelectors.length; s++) {
        var elements = document.querySelectorAll(adSelectors[s]);
        for (var e = 0; e < elements.length; e++) {
          var el = elements[e];
          try {
            el.style.setProperty('display', 'none', 'important');
            el.style.setProperty('visibility', 'hidden', 'important');
            el.style.setProperty('height', '0px', 'important');
            if (el.tagName === 'IFRAME') {
              el.src = 'about:blank';
            }
            el.remove();
            removedCount++;
          } catch(err) {}
        }
      }

      // Also scan all iframes for ad sources
      var iframes = document.querySelectorAll('iframe');
      for (var f = 0; f < iframes.length; f++) {
        var ifr = iframes[f];
        var src = ifr.src || ifr.getAttribute('data-src') || '';
        if (isAdUrl(src)) {
          ifr.style.setProperty('display', 'none', 'important');
          ifr.src = 'about:blank';
          ifr.remove();
          removedCount++;
        }
      }
    } catch(e) {}

    if (removedCount > 0) {
      window.__tubBlockedAdsCount = (window.__tubBlockedAdsCount || 0) + removedCount;
    }
  }

  // 3. Network Request Interceptors (Monkeypatch fetch & XHR)
  function installNetworkInterceptors() {
    try {
      if (!window.__tubFetchHooked && window.fetch) {
        window.__tubFetchHooked = true;
        var realFetch = window.fetch;
        window.fetch = function(input, init) {
          try {
            var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
            if (isAdUrl(url)) {
              window.__tubBlockedAdsCount = (window.__tubBlockedAdsCount || 0) + 1;
              // Never reject: site/player code waiting on this promise would
              // abort with an unhandled error and the video would never start.
              // An empty 200 response lets the ad time out gracefully instead.
              if (typeof Response !== 'undefined') {
                return Promise.resolve(new Response('', { status: 200 }));
              }
            }
          } catch(e) {}
          return realFetch.apply(this, arguments);
        };
      }

      if (!window.__tubXhrHooked && window.XMLHttpRequest) {
        window.__tubXhrHooked = true;
        var realOpen = window.XMLHttpRequest.prototype.open;
        window.XMLHttpRequest.prototype.open = function(method, url) {
          try {
            var urlStr = (url || '').toString();
            if (isAdUrl(urlStr)) {
              window.__tubBlockedAdsCount = (window.__tubBlockedAdsCount || 0) + 1;
              url = 'data:text/plain,';
            }
          } catch(e) {}
          return realOpen.apply(this, arguments);
        };
      }
    } catch(e) {}
  }
  installNetworkInterceptors();
  purgeAllAds();

  // 1b. Universal Screen Auto-Fitting Engine
  // Automatically scales and resizes ANY website to fit the current screen / window width.
  var lastClientWidth = 0;
  var lastScrollWidth = 0;

  function autoResizeToScreen() {
    try {
      var docEl = document.documentElement;
      var body = document.body;
      if (!docEl) return;

      var clientW = window.innerWidth || docEl.clientWidth || (body ? body.clientWidth : 0);
      if (clientW <= 0) return;

      var scrollW = Math.max(docEl.scrollWidth || 0, body ? body.scrollWidth : 0);
      if (Math.abs(clientW - lastClientWidth) < 2 && Math.abs(scrollW - lastScrollWidth) < 5) {
        return;
      }
      lastClientWidth = clientW;
      lastScrollWidth = scrollW;

      var meta = document.querySelector('meta[name="viewport"]');
      if (!meta) {
        meta = document.createElement('meta');
        meta.name = 'viewport';
        (document.head || docEl).appendChild(meta);
      }

      // If content is wider than screen, scale it down proportionally to fit the screen
      if (scrollW > clientW + 4) {
        var scale = (clientW / scrollW);
        if (scale > 0.15 && scale < 1.0) {
          meta.setAttribute('content', 'width=' + scrollW + ', initial-scale=' + scale.toFixed(4) + ', minimum-scale=' + (scale * 0.5).toFixed(4) + ', maximum-scale=5.0, user-scalable=yes');
        }
      } else {
        meta.setAttribute('content', 'width=device-width, initial-scale=1.0, minimum-scale=0.5, maximum-scale=5.0, user-scalable=yes');
      }
    } catch(e) {}
  }

  autoResizeToScreen();
  window.addEventListener('resize', autoResizeToScreen, { passive: true });
  window.addEventListener('orientationchange', autoResizeToScreen, { passive: true });
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', autoResizeToScreen);
  }
  window.addEventListener('load', autoResizeToScreen);

  // 2. uBlock Origin Defusers & Fake Objects (Bypass Anti-Adblock Detection at root)
  try {
    window.canRunAds = true;
    window.hasAdblock = false;
    window.isAdBlockActive = false;
    window.adblock = false;
    window.abp = false;
    window.google_ad_client = "ca-pub-0000000000000000";
    window.google_ad_status = 1;

    // Fake adsbygoogle to satisfy AdSense checks
    window.adsbygoogle = window.adsbygoogle || [];
    window.adsbygoogle.push = function(o) { return 0; };
    window.adsbygoogle.loaded = true;

    // Fake Google Analytics / Tag Manager
    window.ga = window.ga || function() {};
    window.gtag = window.gtag || function() {};
    window.fbq = window.fbq || function() {};

    // Neutralize FuckAdBlock & BlockAdBlock libraries
    var antiAdBlockStub = {
      check: function() { return false; },
      clearEvent: function() {},
      on: function(isAdBlock, fn) {
        if (!isAdBlock && typeof fn === 'function') {
          try { fn(); } catch(e) {}
        }
        return this;
      },
      onDetected: function(fn) { return this; },
      onNotDetected: function(fn) {
        if (typeof fn === 'function') {
          try { fn(); } catch(e) {}
        }
        return this;
      },
      setOption: function() { return this; },
      emitEvent: function() { return this; }
    };
    window.fuckAdBlock = antiAdBlockStub;
    window.FuckAdBlock = function() { return antiAdBlockStub; };
    window.blockAdBlock = antiAdBlockStub;
    window.BlockAdBlock = function() { return antiAdBlockStub; };
    window.sniffAdBlock = antiAdBlockStub;
  } catch(e) {}

  // 3. Aggressive Pop-up & Pop-under Interception
  try {
    if (!window.__tubOpenHooked) {
      window.__tubOpenHooked = true;
      var originalOpen = window.open;
      window.open = function(url, target, features) {
        if (!url) return null;
        var str = url.toString().toLowerCase();
        // Only well-known pop-under ad networks — deliberately no generic
        // words like 'banner', 'onclick' or 'redirect' that also appear in
        // legitimate player/stream URLs and would break site navigation.
        var adPatterns = [
          'doubleclick', 'popads', 'popcash', 'propellerads', 'adsterra',
          'exoclick', 'adnxs', 'admaven', 'clickadu', 'adcash', 'yllix',
          'monetag', 'juicyads', 'ad-delivery', 'popunder', 'popmyads',
          'onclickads', 'plugrush', 'trafficjunky', 'popads'
        ];
        for (var i = 0; i < adPatterns.length; i++) {
          if (str.indexOf(adPatterns[i]) !== -1) {
            console.log('[uBlock] Blocked popup window.open: ' + url);
            return null;
          }
        }
        return originalOpen.apply(window, arguments);
      };
    }
  } catch(e) {}

  // Remove transparent clickjacker overlays
  function purgeClickjackers() {
    try {
      var fullPageLinks = document.querySelectorAll('a[target="_blank"], a[href^="http"]');
      for (var i = 0; i < fullPageLinks.length; i++) {
        var a = fullPageLinks[i];
        var style = window.getComputedStyle(a);
        if (style.position === 'fixed' || style.position === 'absolute') {
          var w = a.offsetWidth || 0;
          var h = a.offsetHeight || 0;
          if (w > window.innerWidth * 0.7 && h > window.innerHeight * 0.7) {
            a.remove();
            console.log('[uBlock] Removed clickjacker transparent overlay link');
          }
        }
      }
    } catch(e) {}
  }

  // 4. Universal Video Ad Auto-Skipper (Works across ANY website with video)
  function universalSkipVideoAds() {
    try {
      // (a) Click universal skip buttons
      var skipSelectors = [
        '.ytp-ad-skip-button',
        '.ytp-ad-skip-button-modern',
        '.ytp-ad-skip-button-slot',
        '.ytp-ad-overlay-close-button',
        'button.ytp-ad-skip-button',
        '.ytp-skip-ad-button',
        '.videoAdUiSkipButton',
        '.video-ad-skip-button',
        '.vjs-skip-ad',
        '.vjs-skip-button',
        '.jw-skip',
        '.jw-icon-skip',
        '[id^="skip-button:"]',
        'button[class*="skip-button"]',
        'button[class*="skip_button"]',
        'button[class*="ad-skip"]',
        'button[class*="ad_skip"]',
        'div[class*="skip-button"]',
        'div[class*="skip_button"]',
        'div[class*="ad-skip"]',
        'span[class*="skip-button"]',
        '[aria-label*="Skip"]',
        '[aria-label*="skip"]'
      ];

      for (var i = 0; i < skipSelectors.length; i++) {
        var buttons = document.querySelectorAll(skipSelectors[i]);
        for (var b = 0; b < buttons.length; b++) {
          var btn = buttons[b];
          if (btn && btn.offsetParent !== null) {
            btn.click();
            console.log('[uBlock] Universal video ad skip button clicked');
          }
        }
      }

      // Look for any visible button containing text "Skip" or "Skip Ad"
      var allButtons = document.querySelectorAll('button, a, div[role="button"]');
      for (var j = 0; j < allButtons.length; j++) {
        var el = allButtons[j];
        var txt = (el.innerText || el.textContent || '').trim().toLowerCase();
        if ((txt === 'skip' || txt === 'skip ad' || txt.indexOf('skip ad') === 0 || txt === 'skip video' || txt === 'স্কিপ') && el.offsetParent !== null) {
          el.click();
          console.log('[uBlock] Clicked text-based skip button: ' + txt);
        }
      }

      // (b) Detect any HTML5 <video> playing an ad.
      // Strict, per-player detection only: a page-wide querySelector (e.g. one
      // static '.video-ad' placeholder div) used to mark the MAIN content
      // video as an ad and fast-forward it to the end — "video never plays".
      // A video counts as an ad only when ITS OWN player container is in an
      // explicit ad state or its own src comes from an ad marker.
      var videos = document.querySelectorAll('video');
      for (var v = 0; v < videos.length; v++) {
        var vid = videos[v];
        var isAd = false;

        // Check YouTube player container
        var ytPlayer = vid.closest('.html5-video-player');
        if (ytPlayer && (ytPlayer.classList.contains('ad-showing') || ytPlayer.classList.contains('ad-interrupting'))) {
          isAd = true;
        }

        // Check the video's own generic player (JWPlayer, Video.js, IMA)
        if (!isAd) {
          var container = vid.closest('.jwplayer, .video-js, .bitmovel_player, [class*="player-container"]');
          if (container) {
            isAd = container.classList.contains('jw-flag-ads') ||
                   container.classList.contains('jw-flag-ads-google') ||
                   container.classList.contains('vjs-ad-playing') ||
                   !!container.querySelector('.ima-display-mode-linear') ||
                   !!container.querySelector('.vjs-ad-overlay') ||
                   !!container.querySelector('.jw-ad-container');
          }
        }

        // Check if this video element itself has ad markers in its own src
        var src = (vid.currentSrc || vid.src || '').toLowerCase();
        if (src.indexOf('/pagead/') !== -1 || src.indexOf('ad_break') !== -1 || src.indexOf('googlesyndication') !== -1) {
          isAd = true;
        }

        // Only skip short clips (real ad breaks are minutes long); a misread
        // on a full-length feature must never scrub the movie away.
        var dur = vid.duration;
        var looksLongForm = isFinite(dur) && dur > 900;
        if (isAd && !vid.paused && !looksLongForm) {
          // Mute and fast-forward to the end instantly
          vid.muted = true;
          vid.playbackRate = 16.0;
          if (dur && !isNaN(dur) && isFinite(dur) && dur > 0) {
            vid.currentTime = dur - 0.05;
          }
          // Trigger skip button again
          var skipBtn = (ytPlayer || vid.closest('.jwplayer, .video-js') || document).querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .vjs-skip-ad, .jw-skip');
          if (skipBtn) skipBtn.click();
        }
      }
    } catch(e) {}
  }

  // 5. Universal Anti-Adblock Modal Neutralizer & Body Scroll Restorer
  function neutralizeAntiAdblockModals() {
    try {
      // (a) Specific anti-adblock dialogs (YouTube, Google Funding Choices, Sourcepoint, etc.)
      var antiAdblockSelectors = [
        'ytd-enforcement-message-view-model',
        'tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)',
        '[class*="adblock-modal"]',
        '[id*="adblock-modal"]',
        '[class*="adblocker-modal"]',
        '[id*="adblocker-modal"]',
        '[class*="anti-adblock"]',
        '[id*="anti-adblock"]',
        '[class*="fc-ab-root"]',
        '[id*="fc-ab-root"]',
        '[class*="sp_message_container"]',
        'div[class*="ad-blocker-message"]',
        'div[id*="ad-blocker-message"]'
      ];

      var modalRemoved = false;
      for (var s = 0; s < antiAdblockSelectors.length; s++) {
        var elements = document.querySelectorAll(antiAdblockSelectors[s]);
        for (var e = 0; e < elements.length; e++) {
          var item = elements[e];
          var container = item.closest('tp-yt-paper-dialog') || item.closest('[role="dialog"]') || item;
          container.remove();
          modalRemoved = true;
          console.log('[uBlock] Removed anti-adblock dialog: ' + antiAdblockSelectors[s]);
        }
      }

      // (b) Text-heuristic scanner for generic anti-adblock full-screen overlays
      var dialogs = document.querySelectorAll('div[role="dialog"], div[class*="modal"], div[class*="overlay"], div[class*="popup"]');
      for (var d = 0; d < dialogs.length; d++) {
        var dlg = dialogs[d];
        var text = (dlg.innerText || '').toLowerCase();
        if (text.indexOf('ad blocker') !== -1 || text.indexOf('adblock') !== -1 || text.indexOf('disable your ad') !== -1 || text.indexOf('turn off your ad') !== -1 || text.indexOf('whitelist') !== -1 || text.indexOf('বিজ্ঞাপন') !== -1) {
          dlg.remove();
          modalRemoved = true;
          console.log('[uBlock] Removed generic anti-adblock modal by text heuristic');
        }
      }

      // (c) Remove leftover gray backdrops
      if (modalRemoved || document.querySelector('tp-yt-iron-overlay-backdrop')) {
        var backdrops = document.querySelectorAll('tp-yt-iron-overlay-backdrop, .modal-backdrop, [class*="backdrop"]');
        for (var b = 0; b < backdrops.length; b++) {
          backdrops[b].remove();
        }
      }

      // (d) Restore page scrollability
      if (document.body && document.body.style) {
        if (document.body.style.overflow === 'hidden') {
          document.body.style.setProperty('overflow', 'auto', 'important');
        }
        if (document.body.style.position === 'fixed') {
          document.body.style.setProperty('position', 'static', 'important');
        }
        if (document.body.style.filter && document.body.style.filter.indexOf('blur') !== -1) {
          document.body.style.setProperty('filter', 'none', 'important');
        }
      }
      if (document.documentElement && document.documentElement.style && document.documentElement.style.overflow === 'hidden') {
        document.documentElement.style.setProperty('overflow', 'auto', 'important');
      }

      // (e) Resume any paused video
      var mainVideos = document.querySelectorAll('video');
      for (var mv = 0; mv < mainVideos.length; mv++) {
        if (mainVideos[mv].paused && modalRemoved) {
          try { mainVideos[mv].play(); } catch(err) {}
        }
      }
    } catch(e) {}
  }

  // 6. Loop every 150ms & observe DOM
  function runLoop() {
    ensureStyles();
    purgeAllAds();
    universalSkipVideoAds();
    neutralizeAntiAdblockModals();
    purgeClickjackers();
    autoResizeToScreen();
  }

  runLoop();

  if (!window.__tubLoopRegistered) {
    window.__tubLoopRegistered = true;
    setInterval(runLoop, 150);

    if (window.MutationObserver) {
      var observer = new MutationObserver(function() {
        runLoop();
      });
      observer.observe(document.documentElement || document.body, {
        childList: true,
        subtree: true
      });
    }

    window.addEventListener('load', runLoop, { passive: true });
    window.addEventListener('DOMContentLoaded', runLoop, { passive: true });
  }
})();
''';
  }

  /// Force script executed when the user explicitly triggers "Bypass Anti-Adblock".
  String getBypassAntiAdblockScript() {
    return '''
(function() {
  try {
    // 1. Remove all fixed overlay dialogs that contain adblock keywords
    var all = document.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var text = (el.innerText || '').toLowerCase();
      if ((text.indexOf('adblock') !== -1 || text.indexOf('ad blocker') !== -1 || text.indexOf('disable your ad') !== -1 || text.indexOf('whitelist') !== -1) && (el.offsetWidth > 250 && el.offsetHeight > 150)) {
        var style = window.getComputedStyle(el);
        if (style.position === 'fixed' || style.position === 'absolute') {
          el.remove();
        }
      }
    }
    // 2. Remove all backdrops
    var backdrops = document.querySelectorAll('tp-yt-iron-overlay-backdrop, .modal-backdrop, [class*="backdrop"], [class*="overlay"]');
    for (var b = 0; b < backdrops.length; b++) {
      var bdStyle = window.getComputedStyle(backdrops[b]);
      if (bdStyle.position === 'fixed') {
        backdrops[b].remove();
      }
    }
    // 3. Force restore scroll and remove blur
    document.body.style.setProperty('overflow', 'auto', 'important');
    document.body.style.setProperty('position', 'static', 'important');
    document.body.style.setProperty('filter', 'none', 'important');
    document.documentElement.style.setProperty('overflow', 'auto', 'important');

    // 4. Unpause video
    var vids = document.querySelectorAll('video');
    for (var v = 0; v < vids.length; v++) {
      if (vids[v].paused) {
        try { vids[v].play(); } catch(e) {}
      }
    }
    return 'SUCCESS';
  } catch(e) {
    return 'ERROR: ' + e;
  }
})();
''';
  }

  /// Standalone Universal Responsive Screen Auto-Resize Script.
  /// Runs unconditionally on any page (regardless of ad blocker toggle) to guarantee
  /// that all websites automatically adapt and resize to match the exact screen width.
  String getResponsiveScreenScript() {
    return '''
(function() {
  try {
    // 1. Inject responsive CSS
    if (!document.getElementById('tub-responsive-screen-styles')) {
      var style = document.createElement('style');
      style.id = 'tub-responsive-screen-styles';
      style.type = 'text/css';
      style.appendChild(document.createTextNode(
        'html, body { max-width: 100% !important; overflow-x: hidden !important; box-sizing: border-box !important; }' +
        '*, *::before, *::after { box-sizing: border-box !important; }' +
        'img, video, canvas, svg, iframe, embed, object { max-width: 100% !important; }' +
        'table { max-width: 100% !important; }'
      ));
      (document.head || document.documentElement).appendChild(style);
    }

    // 2. Dynamic auto-fit to screen size
    var docEl = document.documentElement;
    var body = document.body;
    if (!docEl) return;

    var clientW = window.innerWidth || docEl.clientWidth || (body ? body.clientWidth : 0);
    if (clientW <= 0) return;

    var scrollW = Math.max(docEl.scrollWidth || 0, body ? body.scrollWidth : 0);
    var meta = document.querySelector('meta[name="viewport"]');
    if (!meta) {
      meta = document.createElement('meta');
      meta.name = 'viewport';
      (document.head || docEl).appendChild(meta);
    }

    if (scrollW > clientW + 4) {
      var scale = (clientW / scrollW);
      if (scale > 0.15 && scale < 1.0) {
        meta.setAttribute('content', 'width=' + scrollW + ', initial-scale=' + scale.toFixed(4) + ', minimum-scale=' + (scale * 0.5).toFixed(4) + ', maximum-scale=5.0, user-scalable=yes');
      }
    } else {
      meta.setAttribute('content', 'width=device-width, initial-scale=1.0, minimum-scale=0.5, maximum-scale=5.0, user-scalable=yes');
    }

    if (!window.__tubResizeListenerAttached) {
      window.__tubResizeListenerAttached = true;
      var resizeHandler = function() {
        var cW = window.innerWidth || (document.documentElement ? document.documentElement.clientWidth : 0);
        var sW = Math.max(document.documentElement ? document.documentElement.scrollWidth : 0, document.body ? document.body.scrollWidth : 0);
        var m = document.querySelector('meta[name="viewport"]');
        if (m && cW > 0) {
          if (sW > cW + 4) {
            var sc = cW / sW;
            if (sc > 0.15 && sc < 1.0) {
              m.setAttribute('content', 'width=' + sW + ', initial-scale=' + sc.toFixed(4) + ', minimum-scale=' + (sc * 0.5).toFixed(4) + ', maximum-scale=5.0, user-scalable=yes');
            }
          } else {
            m.setAttribute('content', 'width=device-width, initial-scale=1.0, minimum-scale=0.5, maximum-scale=5.0, user-scalable=yes');
          }
        }
      };
      window.addEventListener('resize', resizeHandler, { passive: true });
      window.addEventListener('orientationchange', resizeHandler, { passive: true });
    }
  } catch(e) {}
})();
''';
  }
}
