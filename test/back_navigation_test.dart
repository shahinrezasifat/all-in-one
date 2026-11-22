import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/main.dart';
import 'package:snaptube_pure/models/site_model.dart';
import 'package:snaptube_pure/screens/browser_screen.dart';
import 'package:snaptube_pure/screens/home_screen.dart';
import 'package:snaptube_pure/screens/vault_screen.dart';

void main() {
  testWidgets('system back unwinds visited sections instead of exiting', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MainNavigationScreen()));
    await tester.pump();

    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.tap(find.text('Vault'));
    await tester.pump();
    expect(find.byType(VaultScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(HomeScreen), findsOneWidget);

    // Flush the version-check timeout started by the hidden Settings screen.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('browser toolbar back always returns to the home page', (
    tester,
  ) async {
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserScreen(
          initialSite: const SiteModel(
            title: 'YouTube',
            url: 'https://m.youtube.com',
            icon: '▶',
          ),
          onCloseBrowser: () => closed++,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Back to home'));
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('double back on home exits after showing a hint', (tester) async {
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(const MaterialApp(home: MainNavigationScreen()));
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(platformCalls.where((m) => m == 'SystemNavigator.pop'), isEmpty);
    expect(find.text('Press back again to exit'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(platformCalls.where((m) => m == 'SystemNavigator.pop').length, 1);
    expect(find.byType(MainNavigationScreen), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });
}
