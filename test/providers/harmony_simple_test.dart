import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/harmony_simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CredentialFailApi extends HarmonyAccountApi {
  @override
  Future<HarmonySession> login(String username, String password) async {
    throw HarmonyAccountError.credentials;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await AppLocalizations.load(const Locale('zh', 'CN'));
  });

  test('login stores credential errors in notifier state', () async {
    final container = ProviderContainer(
      overrides: [
        harmonyAccountApiProvider.overrideWithValue(CredentialFailApi()),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(harmonySimpleProvider.notifier);
    await notifier.login('user', 'wrong');
    expect(
      container.read(harmonySimpleProvider).error,
      AppLocalizations.current.harmonyCredentialsError,
    );
  });
}
