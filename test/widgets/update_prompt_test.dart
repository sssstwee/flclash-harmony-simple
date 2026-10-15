import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _CaptureUpdates extends CommonAction {
  final notices = <String>[];

  @override
  Future<void> checkUpdateResultHandle({
    Map<String, dynamic>? data,
    bool isUser = false,
  }) async {
    notices.add(data!['tag_name'] as String);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    globalState.packageInfo = PackageInfo(
      appName: '小猫AI加速',
      packageName: 'com.follow.clash.simple',
      version: '0.8.94',
      buildNumber: '2026101502',
    );
    await AppLocalizations.load(const Locale('zh', 'CN'));
  });

  Future<void> render(WidgetTester tester, ProviderContainer container) =>
      tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: globalState.navigatorKey,
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('zh', 'CN')],
            home: const Scaffold(),
          ),
        ),
      );

  testWidgets('failed startup checks retry and notify each newer build once', (
    tester,
  ) async {
    var requests = 0;
    var release = 'v0.8.94+2026101503';
    final interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        expect(
          options.uri.path,
          '/repos/sssstwee/xiaomao-ai-proxy/releases/latest',
        );
        requests++;
        if (requests == 1) {
          handler.reject(DioException(requestOptions: options));
        } else {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{'tag_name': release, 'body': '- 修复更新提示'},
            ),
          );
        }
      },
    );
    request.dio.interceptors.add(interceptor);
    addTearDown(() => request.dio.interceptors.remove(interceptor));
    final action = _CaptureUpdates();
    final container = ProviderContainer(
      overrides: [commonActionProvider.overrideWith(() => action)],
    );
    addTearDown(container.dispose);
    container.listen(appSettingProvider, (_, _) {});
    await render(tester, container);
    container.read(commonActionProvider);
    await tester.runAsync(action.autoCheckUpdate);
    expect(requests, 1);
    expect(action.notices, isEmpty);
    await tester.runAsync(action.autoCheckUpdate);
    expect(action.notices, [release]);
    await tester.runAsync(action.autoCheckUpdate);
    expect(action.notices, [release]);
    expect(container.read(appSettingProvider).autoCheckUpdate, isTrue);
    release = 'v0.8.94+2026101502';
    expect(await tester.runAsync(request.checkForUpdate), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('new build prompt renders release notes and a download action', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [viewSizeProvider.overrideWithValue(const Size(800, 600))],
    );
    addTearDown(container.dispose);
    await render(tester, container);
    final showing = container
        .read(commonActionProvider.notifier)
        .checkUpdateResultHandle(
          data: {'tag_name': 'v0.8.94+2026101503', 'body': '- 修复更新提示'},
        );
    await tester.pumpAndSettle();
    expect(
      find.text(AppLocalizations.current.discoverNewVersion),
      findsOneWidget,
    );
    expect(find.text(AppLocalizations.current.goDownload), findsOneWidget);
    expect(
      find.textContaining('v0.8.94+2026101503', findRichText: true),
      findsOneWidget,
    );
    globalState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await showing;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
