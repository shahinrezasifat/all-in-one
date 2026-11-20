import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/models/site_model.dart';
import 'package:snaptube_pure/screens/browser_screen.dart';
import 'package:snaptube_pure/services/yt_dlp_service.dart';

void main() {
  test('YouTube browser URLs resolve only to a concrete video', () {
    const expected = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
    for (final url in [
      'https://m.youtube.com/watch?v=jNQXAC9IVRw&list=example&pp=tracking',
      'https://youtu.be/jNQXAC9IVRw?t=4',
      'https://www.youtube.com/shorts/jNQXAC9IVRw',
      'https://www.youtube-nocookie.com/embed/jNQXAC9IVRw',
    ]) {
      expect(YtDlpService.youtubeVideoUrl(url), expected);
    }
    expect(YtDlpService.youtubeVideoUrl('https://m.youtube.com/results?search_query=zoo'), isNull);
    expect(YtDlpService.youtubeVideoUrl('https://m.youtube.com/watch'), isNull);
    expect(YtDlpService.youtubeVideoUrl('https://youtube.com.example.com/watch?v=jNQXAC9IVRw'), isNull);
  });

  testWidgets('BrowserScreen renders safely with mobile viewport on desktop', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const site = SiteModel(
      title: 'YouTube',
      url: 'https://www.youtube.com',
      icon: '',
      colorHex: 0xFFFF0000,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: BrowserScreen(initialSite: site),
      ),
    );

    expect(tester.takeException(), isNull);
    // Desktop header controls
    expect(find.text('Exit Browser'), findsOneWidget);
    expect(find.text('Auto-Fit Screen'), findsOneWidget);

    // In-app mobile placeholder and address bar
    expect(find.text('Extract Media From URL'), findsOneWidget);
    expect(find.text('Open in Browser'), findsOneWidget);
    expect(find.byTooltip('Download this video'), findsOneWidget);

    // Opens viewport selection sheet
    await tester.tap(find.text('Auto-Fit Screen'));
    await tester.pumpAndSettle();

    expect(find.text('Browser Display Size'), findsOneWidget);
    expect(find.text('Auto-Fit Screen (অটো-ফিট স্ক্রিন)'), findsOneWidget);
    expect(find.text('Mobile Standard (430px)'), findsOneWidget);
    expect(find.text('Mobile Compact (390px)'), findsOneWidget);
    expect(find.text('Mobile Max / Plus (480px)'), findsOneWidget);
  });
}
