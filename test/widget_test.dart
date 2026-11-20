import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/main.dart';
import 'package:snaptube_pure/screens/home_screen.dart';

void main() {
  testWidgets('Tub Pure smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const TubPureApp());
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(TubPureApp), findsOneWidget);
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
}
