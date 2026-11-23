import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaptube_pure/screens/developer_screen.dart';
import 'package:snaptube_pure/screens/settings_screen.dart';

void main() {
  testWidgets(
    'Settings opens the developer profile when GitHub is unavailable',
    (tester) async {
      tester.view.physicalSize = const Size(390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      expect(find.text('Open folder'), findsNothing);
      expect(find.text('Choose folder'), findsOneWidget);
      final developerTile = find.text('Developer');
      for (
        var scroll = 0;
        scroll < 12 && developerTile.hitTestable().evaluate().isEmpty;
        scroll++
      ) {
        await tester.drag(find.byType(ListView), const Offset(0, -340));
        await tester.pumpAndSettle();
      }
      await tester.tap(developerTile);
      await tester.pumpAndSettle();
      // Widget tests reject real HTTP requests, exercising the offline UI.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(find.byType(DeveloperScreen), findsOneWidget);
      expect(find.text('S. M. Shahin Reza Sifat'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(find.text('@shahinrezasifat'), findsOneWidget);
      expect(find.text('STATS OFFLINE'), findsOneWidget);
      expect(find.text('github.com/shahinrezasifat'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('WhatsApp'), 300);
      expect(find.text('+8801766522499'), findsOneWidget);

    },
  );
}
