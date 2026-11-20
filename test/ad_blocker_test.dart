import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/services/ad_blocker_service.dart';

void main() {
  group('uBlock Origin AdBlockerService Tests', () {
    final adBlock = AdBlockerService.instance;

    setUp(() {
      adBlock.resetCounter();
      if (!adBlock.isEnabled) {
        adBlock.toggle();
      }
    });

    test('Identifies uBlock Origin ad network, popup, and anti-adblock domains', () {
      expect(adBlock.isAdUrl('https://googleads.g.doubleclick.net/pagead/ads?client=ca-pub'), isTrue);
      expect(adBlock.isAdUrl('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'), isTrue);
      expect(adBlock.isAdUrl('https://securepubads.g.doubleclick.net/gampad/ads'), isTrue);
      expect(adBlock.isAdUrl('https://c.amazon-adsystem.com/aax2/apstag.js'), isTrue);
      expect(adBlock.isAdUrl('https://popads.net/serve.js'), isTrue);
      expect(adBlock.isAdUrl('https://propellerads.com/ad_break'), isTrue);
      expect(adBlock.isAdUrl('https://clickadu.com/inpage/push'), isTrue);
      expect(adBlock.isAdUrl('https://blockadblock.com/adblock.js'), isTrue);
      expect(adBlock.isAdUrl('https://delivery.getadmiral.com/ads.js'), isTrue);

      // Legitimate URLs should NOT be flagged as ads
      expect(adBlock.isAdUrl('https://m.youtube.com/watch?v=dQw4w9WgXcQ'), isFalse);
      expect(adBlock.isAdUrl('https://m.facebook.com/watch/'), isFalse);
      expect(adBlock.isAdUrl('https://soundcloud.com/artist/track'), isFalse);
      expect(adBlock.isAdUrl('https://dailymotion.com/video/x8xyz'), isFalse);
    });

    test('Tracks blocked ad count and reset works correctly', () {
      expect(adBlock.blockedCount, equals(0));
      adBlock.recordBlocked();
      adBlock.recordBlocked();
      expect(adBlock.blockedCount, equals(2));
      adBlock.resetCounter();
      expect(adBlock.blockedCount, equals(0));
    });

    test('Disabling ad blocker permits all URLs', () {
      adBlock.toggle();
      expect(adBlock.isEnabled, isFalse);
      expect(adBlock.isAdUrl('https://googleads.g.doubleclick.net/pagead/ads'), isFalse);
      adBlock.toggle();
      expect(adBlock.isEnabled, isTrue);
      expect(adBlock.isAdUrl('https://googleads.g.doubleclick.net/pagead/ads'), isTrue);
    });

    test('Cosmetic CSS contains universal video players and anti-adblock rules', () {
      final css = adBlock.getAdBlockerCss();
      expect(css.contains('.video-ads'), isTrue);
      expect(css.contains('.ima-ad-container'), isTrue);
      expect(css.contains('.vjs-ad-playing'), isTrue);
      expect(css.contains('.jw-flag-ads'), isTrue);
      expect(css.contains('ytd-enforcement-message-view-model'), isTrue);
      expect(css.contains('[class*="adblock-modal"]'), isTrue);
      expect(css.contains('[class*="fc-ab-root"]'), isTrue);
      expect(css.contains('display: none !important'), isTrue);
    });

    test('Script contains uBlock Origin defusers, universal video skipper, and popup blockers', () {
      final js = adBlock.getAdBlockerScript();
      // uBlock Origin defusers / stubs
      expect(js.contains('window.canRunAds = true'), isTrue);
      expect(js.contains('window.adsbygoogle'), isTrue);
      expect(js.contains('fuckAdBlock'), isTrue);
      expect(js.contains('blockAdBlock'), isTrue);

      // Universal Video Ad Skipper
      expect(js.contains('universalSkipVideoAds'), isTrue);
      expect(js.contains('.ytp-ad-skip-button'), isTrue);
      expect(js.contains('.vjs-skip-ad'), isTrue);
      expect(js.contains('.jw-skip'), isTrue);
      expect(js.contains('vid.playbackRate = 16.0'), isTrue);

      // Pop-up and Anti-Adblock
      expect(js.contains('window.open'), isTrue);
      expect(js.contains('neutralizeAntiAdblockModals'), isTrue);
      expect(js.contains('purgeClickjackers'), isTrue);

      // Active DOM ad purger & network interceptors
      expect(js.contains('purgeAllAds'), isTrue);
      expect(js.contains('installNetworkInterceptors'), isTrue);
      expect(js.contains('window.__tubBlockedAdsCount'), isTrue);
    });

    test('setPageBlockedCount updates blocked count if higher', () {
      expect(adBlock.blockedCount, equals(0));
      adBlock.setPageBlockedCount(5);
      expect(adBlock.blockedCount, equals(5));
      adBlock.setPageBlockedCount(3); // Should not decrease
      expect(adBlock.blockedCount, equals(5));
      adBlock.setPageBlockedCount(12);
      expect(adBlock.blockedCount, equals(12));
    });

    test('Bypass anti-adblock script generates correct modal purger and scroll restorer', () {
      final bypassJs = adBlock.getBypassAntiAdblockScript();
      expect(bypassJs.contains('overflow'), isTrue);
      expect(bypassJs.contains('adblock'), isTrue);
      expect(bypassJs.contains('backdrops'), isTrue);
      expect(bypassJs.contains('play()'), isTrue);
    });

    test('Responsive screen auto-fit script contains dynamic scaling and viewport logic', () {
      final script = adBlock.getResponsiveScreenScript();
      expect(script.contains('tub-responsive-screen-styles'), isTrue);
      expect(script.contains('max-width: 100% !important'), isTrue);
      expect(script.contains('meta.setAttribute'), isTrue);
      expect(script.contains('initial-scale'), isTrue);
      expect(script.contains('resizeHandler'), isTrue);
    });
  });
}
