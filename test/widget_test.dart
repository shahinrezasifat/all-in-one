import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/main.dart';
import 'package:snaptube_pure/models/video_item.dart';
import 'package:snaptube_pure/widgets/remote_image.dart';
import 'package:snaptube_pure/widgets/video_card.dart';
import 'package:snaptube_pure/screens/home_screen.dart';
import 'package:snaptube_pure/services/bookmark_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await BookmarkService.instance.init();
  });

  testWidgets(
    'Feed cards use the provided channel avatar and keep the initial fallback',
    (tester) async {
      const avatar = 'https://example.test/channel.png';
      final video = VideoItem.fromJson(
        const VideoItem(
          id: 'video',
          title: 'Video',
          author: 'Creator',
          thumbnailUrl: '',
          videoUrl: 'https://example.test/video',
          channelAvatarUrl: avatar,
        ).toJson(),
      );
      for (final compact in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VideoCard(video: video, isCompact: compact),
            ),
          ),
        );
        expect(
          find.byWidgetPredicate(
            (widget) => widget is SmartNetworkImage && widget.url == avatar,
          ),
          findsOneWidget,
        );
        expect(find.text('C'), findsOneWidget);
      }
    },
  );

  testWidgets('Tub Pure smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const TubPureApp());
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(TubPureApp), findsOneWidget);
  });

  testWidgets('home separates glowing bookmarks from the unfiltered feed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(onOpenBrowser: (site) => opened = site.title),
      ),
    );
    await tester.pump();
    expect(find.text('Quick access'), findsOneWidget);
    expect(find.text('Trending now'), findsOneWidget);
    expect(find.byIcon(Icons.trending_up_rounded), findsNothing);
    expect(find.text('Gaming'), findsNothing);
    expect(find.text('Shorts'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).gradient is RadialGradient,
      ),
      findsNWidgets(8),
    );
    await tester.tap(find.text('YouTube'));
    expect(opened, 'YouTube');
    await tester.longPress(find.text('YouTube'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Edit Bookmark'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('download feedback clears the floating navigation bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: MainNavigationScreen()));
    await tester.pump();
    final shell = find.byType(MainNavigationScreen);
    final nav = find.byWidgetPredicate(
      (widget) => widget is Container && widget.constraints?.maxHeight == 68,
    );
    final homeFeed = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byType(CustomScrollView),
    );
    expect(tester.getRect(homeFeed.first).bottom, 850);
    expect(tester.getRect(nav.last).bottom, lessThan(850));
    ScaffoldMessenger.of(tester.element(shell)).showSnackBar(
      const SnackBar(
        content: Text('Downloading video'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getRect(find.byType(SnackBar).first).bottom,
      lessThanOrEqualTo(tester.getRect(nav.last).top),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('bookmark URLs keep their query strings when adding HTTPS', () {
    expect(
      BookmarkService.parseBookmarkUrl('example.com/?target=https://other.test')
          ?.toString(),
      'https://example.com/?target=https://other.test',
    );
    expect(BookmarkService.parseBookmarkUrl('ftp://example.com'), isNull);
  });

  testWidgets('bookmark sheet validates links and saves a pasted domain', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return call.method == 'Clipboard.getData'
          ? {'text': 'example.com/page'}
          : null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    await tester.tap(find.text('Add bookmark'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Save bookmark'));
    await tester.pump();
    expect(find.text('Enter a valid website link.'), findsOneWidget);

    await tester.tap(find.text('Paste'));
    await tester.pump();
    expect(find.text('Suggested name Example'), findsOneWidget);
    expect(find.text('Enter a valid website link.'), findsNothing);
    await tester.tap(find.text('Save bookmark'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final saved = BookmarkService.instance.bookmarks.singleWhere(
      (site) => site.title == 'Example',
    );
    expect(saved.url, 'https://example.com/page');
    expect(find.text('Save bookmark'), findsNothing);
    await BookmarkService.instance.removeBookmark(saved);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
