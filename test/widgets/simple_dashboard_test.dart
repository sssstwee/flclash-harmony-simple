import 'package:dio/dio.dart';
import 'package:fl_clash/common/fixed.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/simple.dart';
import 'package:fl_clash/common/harmony_config_freshness.dart';
import 'package:fl_clash/common/harmony_home_status.dart';
import 'package:fl_clash/common/harmony_theme.dart';
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

class ConnectedHarmonySimple extends IdleHarmonySimple {
  @override
  HarmonySimpleState build() => HarmonySimpleState(
    bootstrapping: false,
    session: HarmonySession(
      'fixture-token',
      'alice',
      DateTime.now().add(const Duration(days: 1)),
    ),
  );
}

class RemoteHarmonySimple extends IdleHarmonySimple {
  @override
  HarmonySimpleState build() => const HarmonySimpleState(
    bootstrapping: false,
    remoteRuntime: {
      'announcement': '远程服务公告',
      'texts': {
        'ready': '远程就绪文案',
        'logout': '退出远程账户',
        'harmonyAiRoutingHint': 'AI 网站将走「🤖 AI服务」分组',
      },
    },
  );
}

class IdleHarmonySimple extends HarmonySimple {
  @override
  HarmonySimpleState build() => const HarmonySimpleState(bootstrapping: false);

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> checkSession() async {}
}

Finder get primaryConnectionControl =>
    find.byKey(const Key('harmony_primary_connect'));

Widget app(
  Widget child, {
  bool disableAnimations = true,
  ThemeMode themeMode = ThemeMode.system,
}) => MaterialApp(
  themeMode: themeMode,
  theme: ThemeData(
    useMaterial3: true,
    colorScheme: harmonyColorScheme(Brightness.light),
  ),
  darkTheme: ThemeData(
    useMaterial3: true,
    colorScheme: harmonyColorScheme(Brightness.dark),
  ),
  locale: const Locale('zh', 'CN'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: const [Locale('zh', 'CN')],
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
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

  testWidgets('home follows system appearance and keeps brand contrast', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      scoped(
        api: SignedOutApi(),
        child: app(
          SimpleConnectionPanel(
            phase: ConnectionPhase.connecting,
            username: 'harmony',
            onToggle: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    ColorScheme scheme() => Theme.of(
      tester.element(find.byType(SimpleConnectionPanel)),
    ).colorScheme;

    expect(scheme().brightness, Brightness.light);
    expect(scheme().surface, Colors.white);
    expect(scheme().onSurface, Colors.black);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .color,
      const Color(0xfff8fbff),
    );

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(scheme().brightness, Brightness.dark);
    expect(scheme().surface.computeLuminance(), lessThan(0.01));
    expect(scheme().onSurface, Colors.white);
    expect(
      find.byKey(const ValueKey('harmony_guardian_active')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> renderLogin(WidgetTester tester, SignedOutApi api) async {
    await tester.pumpWidget(
      scoped(api: api, child: app(const SimpleDashboardView())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'connected home shows the core node and configured group latency',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            harmonySimpleProvider.overrideWith(ConnectedHarmonySimple.new),
            initProvider.overrideWithValue(true),
            isStartProvider.overrideWithValue(true),
            currentProfileProvider.overrideWithValue(
              const Profile(
                id: 7,
                currentGroupName: 'Cloud',
                autoUpdateDuration: Duration(hours: 24),
              ),
            ),
            groupsProvider.overrideWithBuild(
              (_, _) => [
                const Group(
                  name: 'Cloud',
                  type: GroupType.Fallback,
                  now: 'Configured node',
                  testUrl: 'https://example.test',
                  all: [Proxy(name: 'Configured node', type: 'Vless')],
                ),
              ],
            ),
            delayDataSourceProvider.overrideWithBuild(
              (_, _) => {
                'https://example.test': {'Cloud': 123},
              },
            ),
            totalTrafficProvider.overrideWithValue(const Traffic()),
            trafficsProvider.overrideWithValue(FixedList(0)),
          ],
          child: app(const SimpleDashboardView()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Configured node'), findsOneWidget);
      expect(find.textContaining('123'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('cached remote announcement and copy override local defaults', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          harmonySimpleProvider.overrideWith(RemoteHarmonySimple.new),
          totalTrafficProvider.overrideWithValue(const Traffic()),
          trafficsProvider.overrideWithValue(FixedList(0)),
        ],
        child: app(
          const SimpleConnectionPanel(
            phase: ConnectionPhase.disconnected,
            username: 'alice',
            homeStatus: HarmonyHomeStatus(aiGroupName: '🤖AI服务'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('远程服务公告'), findsOneWidget);
    expect(find.text('远程就绪文案'), findsOneWidget);
    expect(find.text('退出远程账户'), findsOneWidget);
    expect(find.text('线路加速'), findsOneWidget);
    expect(find.textContaining('AI 网站'), findsNothing);
    expect(find.textContaining('AI服务'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'signed-out users must log in and cannot import or connect cached profiles',
    (tester) async {
      final api = SignedOutApi();
      await renderLogin(tester, api);
      expect(find.text('CC保镖'), findsOneWidget);
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
    'status icon controls connection and is disabled during transitions',
    (tester) async {
      for (final phase in ConnectionPhase.values) {
        var toggles = 0;
        await tester.pumpWidget(
          scoped(
            api: SignedOutApi(),
            child: app(
              SimpleConnectionPanel(
                phase: phase,
                username: 'harmony',
                onToggle: () => toggles++,
                onLogout: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(primaryConnectionControl, findsOneWidget);
        expect(find.byType(FilledButton), findsNothing);
        final busy =
            phase == ConnectionPhase.connecting ||
            phase == ConnectionPhase.disconnecting;
        final awake =
            phase == ConnectionPhase.connected ||
            phase == ConnectionPhase.connecting;
        expect(
          find.byKey(
            ValueKey(
              awake ? 'harmony_guardian_active' : 'harmony_guardian_idle',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('harmony_connection_error')),
          phase == ConnectionPhase.error ? findsOneWidget : findsNothing,
        );
        final control = tester.widget<IconButton>(primaryConnectionControl);
        expect(control.onPressed, busy ? isNull : isNotNull);
        final disc = tester.widget<AnimatedContainer>(
          find.descendant(
            of: primaryConnectionControl,
            matching: find.byType(AnimatedContainer),
          ),
        );
        expect(
          (disc.decoration! as BoxDecoration).color,
          awake ? const Color(0xff1765f6) : const Color(0xff0e3d94),
        );
        expect(tester.getSize(primaryConnectionControl), const Size(64, 64));
        await tester.tap(primaryConnectionControl);
        expect(toggles, busy ? 0 : 1);
        if (phase == ConnectionPhase.connected) {
          expect(control.tooltip, '断开');
        }
        if (phase == ConnectionPhase.disconnected) {
          expect(control.tooltip, '连接');
        }
        if (phase == ConnectionPhase.connected ||
            phase == ConnectionPhase.disconnected) {
          final status = find.text(
            phase == ConnectionPhase.connected ? '代理已启动' : '准备连接',
          );
          final controlRect = tester.getRect(primaryConnectionControl);
          final statusRect = tester.getRect(status);
          final panelRect = tester.getRect(find.byType(SimpleConnectionPanel));
          expect(controlRect.center.dx, panelRect.center.dx);
          expect(statusRect.center.dx, controlRect.center.dx);
          expect(statusRect.top, greaterThan(controlRect.bottom));
        }
        if (phase == ConnectionPhase.connecting) {
          expect(find.text('正在连接…'), findsWidgets);
        }
        if (phase == ConnectionPhase.disconnecting) {
          expect(find.text('正在断开…'), findsWidgets);
        }
        expect(find.byType(ListTile), findsNothing);
        expect(find.byTooltip('切换节点'), findsNothing);
        expect(find.byIcon(Icons.swap_horiz_rounded), findsNothing);
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
          const SimpleConnectionPanel(
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
    expect(find.textContaining('点上方图标连接'), findsWidgets);
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
    'home insight card explains routing without automatic connection copy',
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
      expect(find.text('线路'), findsOneWidget);
      expect(find.text('稳定连接优先'), findsOneWidget);
      expect(find.text('AI'), findsOneWidget);
      expect(find.text('线路加速'), findsOneWidget);
      expect(find.text('AI 网站'), findsNothing);
      expect(find.text('🤖AI服务'), findsNothing);
      expect(find.text('网络'), findsOneWidget);
      expect(find.text('Wi-Fi'), findsOneWidget);
      expect(find.text('自动连接'), findsNothing);
      expect(find.text('打开应用时自动连接'), findsNothing);
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
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ready and connected icons breathe without changing hit size', (
    tester,
  ) async {
    for (final phase in [
      ConnectionPhase.disconnected,
      ConnectionPhase.connected,
    ]) {
      await tester.pumpWidget(
        scoped(
          api: SignedOutApi(),
          child: app(
            SimpleConnectionPanel(phase: phase, username: 'harmony'),
            disableAnimations: false,
          ),
        ),
      );
      final glow = find.byKey(const Key('harmony_connection_glow'));
      final before =
          tester.widget<DecoratedBox>(glow).decoration as BoxDecoration;
      await tester.pump(const Duration(milliseconds: 1200));
      final after =
          tester.widget<DecoratedBox>(glow).decoration as BoxDecoration;
      expect(
        after.boxShadow!.single.blurRadius,
        greaterThan(before.boxShadow!.single.blurRadius),
      );
      expect(tester.getSize(primaryConnectionControl), const Size(64, 64));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('connection details distinguish a failed health check', (
    tester,
  ) async {
    await tester.pumpWidget(
      scoped(
        api: SignedOutApi(),
        child: app(
          SimpleConnectionPanel(
            phase: ConnectionPhase.connected,
            username: 'harmony',
            homeStatus: HarmonyHomeStatus(
              networkKind: HarmonyNetworkKind.wifi,
              lastHealthCheckAt: DateTime(2026, 10, 14, 14, 30),
              lastHealthCheckOk: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('连接检查'), findsOneWidget);
    final failedCheck = find.text('未通过 · 14:30');
    expect(failedCheck, findsOneWidget);
    expect(
      tester.widget<Text>(failedCheck).style?.color,
      Theme.of(tester.element(failedCheck)).colorScheme.error,
    );
    expect(find.text('正常 · 14:30'), findsNothing);
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
              homeStatus: HarmonyHomeStatus(
                routeKind: HarmonyRouteKind.automaticGroup,
                aiGroupName: 'AI 服务 · 一条名称较长的自动选择分组',
                networkKind: HarmonyNetworkKind.wifi,
              ),
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
        primaryConnectionControl,
        100,
        scrollable: connectionScrollable,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
