import 'package:dio/dio.dart';
import 'package:fl_clash/common/fixed.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/simple.dart';
import 'package:fl_clash/common/harmony_config_freshness.dart';
import 'package:fl_clash/common/harmony_home_status.dart';
import 'package:fl_clash/common/harmony_user_issue.dart';
import 'package:fl_clash/views/dashboard/widgets/simple_connection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class SignedOutApi extends HarmonyAccountApi {
  SignedOutApi()
    : super(http: Dio(BaseOptions(baseUrl: 'https://api.example.test')));

  int logins = 0;

  @override
  Future<HarmonySession?> restore() async => null;

  @override
  Future<HarmonySession> login(String username, String password) async {
    logins++;
    throw HarmonyAccountError.credentials;
  }
}

/// Avoids bootstrap/profile sync and path/database init during widget tests.
class _EmptyProfiles extends Profiles {
  @override
  List<Profile> build() => [];
}

class IdleHarmonySimple extends HarmonySimple {
  @override
  HarmonySimpleState build() => const HarmonySimpleState(bootstrapping: false);

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> checkSession() async {}
}

Finder get primaryFilledButton =>
    find.byKey(const Key('harmony_primary_connect'));

Widget app(Widget child) => MaterialApp(
  locale: const Locale('zh', 'CN'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: const [Locale('zh', 'CN')],
  home: Scaffold(body: child),
);

Widget scoped({required Widget child, required SignedOutApi api}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      harmonySimpleProvider.overrideWith(IdleHarmonySimple.new),
      harmonyAccountApiProvider.overrideWithValue(api),
      profilesProvider.overrideWith(_EmptyProfiles.new),
      initProvider.overrideWithValue(true),
      isStartProvider.overrideWithValue(false),
      totalTrafficProvider.overrideWithValue(const Traffic()),
      trafficsProvider.overrideWithValue(FixedList(0)),
    ],
    child: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await AppLocalizations.load(const Locale('zh', 'CN'));
  });

  Future<void> renderLogin(WidgetTester tester, SignedOutApi api) async {
    await tester.pumpWidget(
      scoped(api: api, child: app(const SimpleDashboardView())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'signed-out users must log in and cannot import or connect cached profiles',
    (tester) async {
      final api = SignedOutApi();
      await renderLogin(tester, api);
      expect(find.text('Clash Harmony'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.text('导入订阅'), findsNothing);
      expect(find.text('连接'), findsNothing);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(api.logins, 0);
      expect(find.text('请填写此项。'), findsNWidgets(2));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('bad credentials keep the login screen and clear the password', (
    tester,
  ) async {
    final api = SignedOutApi();
    await renderLogin(tester, api);
    await tester.enterText(find.byType(TextFormField).first, 'harmony');
    await tester.enterText(find.byType(TextFormField).last, 'wrong-password');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(api.logins, 1);
    expect(find.text('用户名或密码错误。'), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).last)
          .controller
          .text,
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'connection phases expose one disabled action during transitions',
    (tester) async {
      for (final phase in ConnectionPhase.values) {
        await tester.pumpWidget(
          scoped(
            api: SignedOutApi(),
            child: app(
              SimpleConnectionPanel(
                phase: phase,
                username: 'harmony',
                onToggle: () {},
                onLogout: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final scrollable = find.descendant(
          of: find.byType(SimpleConnectionPanel),
          matching: find.byType(Scrollable),
        );
        if (scrollable.evaluate().isNotEmpty) {
          await tester.scrollUntilVisible(
            primaryFilledButton,
            120,
            scrollable: scrollable.first,
          );
        }
        expect(primaryFilledButton, findsOneWidget);
        final busy =
            phase == ConnectionPhase.connecting ||
            phase == ConnectionPhase.disconnecting;
        expect(
          tester.widget<FilledButton>(primaryFilledButton).onPressed,
          busy ? isNull : isNotNull,
        );
        if (phase == ConnectionPhase.connected) {
          expect(find.text('断开'), findsOneWidget);
        }
        if (phase == ConnectionPhase.disconnected) {
          expect(find.text('连接'), findsOneWidget);
        }
        if (phase == ConnectionPhase.connecting) {
          expect(find.text('正在连接…'), findsWidgets);
        }
        if (phase == ConnectionPhase.disconnecting) {
          expect(find.text('正在断开…'), findsWidgets);
        }
        expect(find.byType(ListTile), findsNothing);
        expect(find.text('DNS'), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('offline cached issue explains next step in plain Chinese', (
    tester,
  ) async {
    await tester.pumpWidget(
      scoped(
        api: SignedOutApi(),
        child: app(
          SimpleConnectionPanel(
            phase: ConnectionPhase.error,
            username: 'harmony',
            issue: HarmonyUserIssue.offlineCached,
            usingCachedConfig: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法更新订阅'), findsOneWidget);
    expect(find.textContaining('账号服务器暂时连不上'), findsOneWidget);
    expect(find.textContaining('点「连接」'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'config freshness row shows up-to-date text and refresh control',
    (tester) async {
      await tester.pumpWidget(
        scoped(
          api: SignedOutApi(),
          child: app(
            SimpleConnectionPanel(
              phase: ConnectionPhase.disconnected,
              username: 'harmony',
              configFreshness: HarmonyConfigFreshness(
                kind: HarmonyConfigFreshnessKind.upToDate,
                versionShort: 'abcd1234',
                lastCheckedAt: DateTime(2026, 3, 20, 14, 30),
              ),
              onConfigRefresh: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('配置已是最新'), findsOneWidget);
      expect(find.textContaining('abcd1234'), findsOneWidget);
      expect(find.byKey(const Key('harmony_config_refresh')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('config freshness row shows updating state while syncing', (
    tester,
  ) async {
    await tester.pumpWidget(
      scoped(
        api: SignedOutApi(),
        child: app(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: SimpleConnectionPanel(
              phase: ConnectionPhase.disconnected,
              username: 'harmony',
              configFreshness: const HarmonyConfigFreshness(
                kind: HarmonyConfigFreshnessKind.discoveringUpdate,
                refreshInProgress: true,
              ),
              homeStatus: const HarmonyHomeStatus(configSyncInProgress: true),
              onConfigRefresh: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('发现新配置，正在更新…'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('harmony_config_refresh')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'home insight card explains auto route and reconnect in Chinese',
    (tester) async {
      await tester.pumpWidget(
        scoped(
          api: SignedOutApi(),
          child: app(
            const SimpleConnectionPanel(
              phase: ConnectionPhase.disconnected,
              username: 'harmony',
              homeStatus: HarmonyHomeStatus(
                routeKind: HarmonyRouteKind.tcpPreferred,
                aiGroupName: '🤖AI服务',
                networkKind: HarmonyNetworkKind.wifi,
                autoReconnectArmed: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('连接说明'), findsOneWidget);
      expect(find.textContaining('TCP'), findsOneWidget);
      expect(find.textContaining('AI 网站'), findsOneWidget);
      expect(find.text('下次打开应用将自动连接'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('reduced motion avoids continuously running animations', (
    tester,
  ) async {
    await tester.pumpWidget(
      scoped(
        api: SignedOutApi(),
        child: app(
          const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: SimpleConnectionPanel(
              phase: ConnectionPhase.disconnecting,
              username: 'harmony',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'folded screen with large text keeps login and connection actions reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await renderLogin(tester, SignedOutApi());
      final loginScrollable = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byType(FilledButton),
        100,
        scrollable: loginScrollable,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        scoped(
          api: SignedOutApi(),
          child: app(
            const SimpleConnectionPanel(
              phase: ConnectionPhase.disconnected,
              username: 'harmony',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final connectionScrollable = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        primaryFilledButton,
        100,
        scrollable: connectionScrollable,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
