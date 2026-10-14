import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _readArb(String locale) {
  return jsonDecode(File('arb/intl_$locale.arb').readAsStringSync())
      as Map<String, dynamic>;
}

Map<String, String> _dashboardStrings(AppLocalizations strings) => {
  'harmonyOfflineConfig': strings.harmonyOfflineConfig,
  'harmonyRetry': strings.harmonyRetry,
  'harmonyCurrentNode': strings.harmonyCurrentNode,
  'harmonySwitchNode': strings.harmonySwitchNode,
  'harmonySessionTraffic': strings.harmonySessionTraffic,
  'harmonyUpload': strings.harmonyUpload,
  'harmonyDownload': strings.harmonyDownload,
  'harmonyLatency': strings.harmonyLatency,
  'harmonyAccount': strings.harmonyAccount,
  'simpleErrorState': strings.simpleErrorState,
  'harmonyLogin': strings.harmonyLogin,
  'harmonyLoginHint': strings.harmonyLoginHint,
  'harmonyUsername': strings.harmonyUsername,
  'harmonyLogout': strings.harmonyLogout,
  'harmonyRequired': strings.harmonyRequired,
  'harmonyCredentialsError': strings.harmonyCredentialsError,
  'harmonySessionExpired': strings.harmonySessionExpired,
  'harmonyRateLimited': strings.harmonyRateLimited,
  'harmonyServiceError': strings.harmonyServiceError,
  'harmonyConfigError': strings.harmonyConfigError,
  'harmonyConnecting': strings.harmonyConnecting,
  'harmonyDisconnecting': strings.harmonyDisconnecting,
  'harmonyAutomaticHint': strings.harmonyAutomaticHint,
  'harmonyConnected': strings.harmonyConnected,
  'harmonyChecking': strings.harmonyChecking,
  'harmonyCheckingHint': strings.harmonyCheckingHint,
  'harmonyHealthyHint': strings.harmonyHealthyHint,
  'harmonyReconnecting': strings.harmonyReconnecting,
  'harmonyReconnectingHint': strings.harmonyReconnectingHint,
  'harmonyDegraded': strings.harmonyDegraded,
  'harmonyDomesticUnavailable': strings.harmonyDomesticUnavailable,
  'harmonyForeignUnavailable': strings.harmonyForeignUnavailable,
  'harmonyDegradedHint': strings.harmonyDegradedHint,
  'harmonyOffline': strings.harmonyOffline,
  'harmonyOfflineHint': strings.harmonyOfflineHint,
  'harmonyCaptivePortal': strings.harmonyCaptivePortal,
  'harmonyCaptivePortalHint': strings.harmonyCaptivePortalHint,
  'harmonyLoginRequired': strings.harmonyLoginRequired,
  'harmonyLoginRequiredHint': strings.harmonyLoginRequiredHint,
  'harmonyNoRoute': strings.harmonyNoRoute,
  'harmonyNoRouteHint': strings.harmonyNoRouteHint,
  'harmonyVpnConsentHint': strings.harmonyVpnConsentHint,
  'harmonyDomesticCheck': strings.harmonyDomesticCheck,
  'harmonyForeignCheck': strings.harmonyForeignCheck,
  'harmonyCheckPassed': strings.harmonyCheckPassed,
  'harmonyCheckFailed': strings.harmonyCheckFailed,
  'harmonyCheckPending': strings.harmonyCheckPending,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final english = _readArb('en');
  final chinese = _readArb('zh_CN');

  test('only English and Simplified Chinese ARBs are included', () {
    final arbNames = Directory('arb')
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('.arb'));
    expect(arbNames, unorderedEquals(['intl_en.arb', 'intl_zh_CN.arb']));
    expect(chinese.keys, unorderedEquals(english.keys));
    for (final translations in [english, chinese]) {
      expect(translations, isNot(contains('ja')));
      expect(translations, isNot(contains('ru')));
      for (final entry in translations.entries) {
        if (entry.key.startsWith('@')) continue;
        expect(entry.value, isA<String>(), reason: entry.key);
        expect(entry.value, isNotEmpty, reason: entry.key);
      }
    }
  });

  test('generated locales only offer English and Simplified Chinese', () {
    expect(AppLocalizations.delegate.supportedLocales, const [
      Locale('en'),
      Locale('zh', 'CN'),
    ]);
    for (final language in ['ja', 'ru', 'fr']) {
      expect(AppLocalizations.delegate.isSupported(Locale(language)), isFalse);
      expect(
        File('lib/l10n/intl/messages_$language.dart').existsSync(),
        isFalse,
      );
    }
    for (final language in ['ja', 'ru']) {
      expect(
        Directory('ohos/entry/src/main/resources/$language').existsSync(),
        isFalse,
      );
    }
  });

  for (final locale in const [Locale('en'), Locale('zh', 'CN')]) {
    test(
      '$locale generated dashboard strings match their ARB source',
      () async {
        final translations = _readArb(locale.toString());
        final strings = await AppLocalizations.load(locale);
        for (final entry in _dashboardStrings(strings).entries) {
          expect(
            entry.value,
            translations[entry.key],
            reason: '$locale: ${entry.key}; run dart run intl_utils:generate',
          );
        }
      },
    );
  }

  test('unsupported or empty preferred locales fall back to English', () {
    expect(resolveAppLocale(null), const Locale('en'));
    expect(resolveAppLocale([]), const Locale('en'));
    for (final locale in const [
      Locale('ja', 'JP'),
      Locale('ru', 'RU'),
      Locale('fr', 'FR'),
    ]) {
      expect(resolveAppLocale([locale]), const Locale('en'));
    }
  });

  test('Chinese variants resolve to the existing Chinese translation', () {
    for (final locale in const [
      Locale('zh'),
      Locale('zh', 'CN'),
      Locale('zh', 'TW'),
      Locale('zh', 'HK'),
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
        countryCode: 'TW',
      ),
    ]) {
      expect(resolveAppLocale([locale]), const Locale('zh', 'CN'));
    }
    expect(resolveAppLocale([const Locale('en', 'GB')]), const Locale('en'));
  });

  test('system language preferences skip unsupported languages', () {
    expect(
      resolveAppLocale([const Locale('ja'), const Locale('zh', 'CN')]),
      const Locale('zh', 'CN'),
    );
    expect(
      resolveAppLocale([const Locale('ru'), const Locale('en', 'US')]),
      const Locale('en'),
    );
  });

  test('global localization helper follows runtime language changes', () async {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('en'),
    ]) {
      final strings = await AppLocalizations.load(locale);
      expect(currentAppLocalizations, same(strings));
      expect(
        currentAppLocalizations.harmonyRetry,
        _readArb(locale.toString())['harmonyRetry'],
      );
    }
  });

  for (final locale in const [Locale('ja'), Locale('ru')]) {
    test('previously saved $locale settings load English strings', () async {
      final strings = await AppLocalizations.load(resolveAppLocale([locale]));
      expect(strings.harmonyRetry, english['harmonyRetry']);
      expect(strings.harmonyAccount, english['harmonyAccount']);
    });

    testWidgets('$locale system locale displays the English fallback', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = [locale];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) {
              expect(Localizations.localeOf(context), const Locale('en'));
              return Text(AppLocalizations.of(context).harmonyAccount);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(english['harmonyAccount'] as String), findsOneWidget);
    });
  }
}
