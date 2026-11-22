import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/screens/vault_screen.dart';
import 'package:snaptube_pure/services/vault_service.dart';

void main() {
  testWidgets('one biometric success opens the headerless vault lock', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({
      'vault_pin_hash': 'existing-pin',
      'vault_biometrics': true,
    });
    final vault = VaultService.instance;
    await vault.ready;
    addTearDown(vault.lock);

    var prompts = 0;
    final verified = Completer<bool>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const auth = MethodChannel('snaptube_pure/vault_auth');
    messenger.setMockMethodCallHandler(auth, (call) {
      expect(call.method, 'authenticate');
      prompts++;
      return verified.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(auth, null));

    await tester.pumpWidget(const MaterialApp(home: VaultScreen()));
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Secret Vault'), findsNothing);
    await tester.ensureVisible(find.text('Unlock with biometrics'));
    await tester.tap(find.text('Unlock with biometrics'));
    await tester.pump();
    await tester.tap(find.text('Unlock with biometrics'));
    expect(prompts, 1);

    verified.complete(true);
    await tester.pumpAndSettle();
    expect(vault.isUnlocked, isTrue);
    expect(find.text('Unlock with biometrics'), findsNothing);
    expect(find.text('Your vault is empty'), findsOneWidget);
    expect(prompts, 1);
  });
}
