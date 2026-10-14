import 'package:dio/dio.dart';
import 'package:fl_clash/common/fixed.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/simple.dart';
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

class ControlledHarmonySimple extends IdleHarmonySimple {
  final HarmonySimpleState initialState;
  final List<(String, String)> switches = [];

  ControlledHarmonySimple(this.initialState);

  @override
  HarmonySimpleState build() => initialState;

  void setSnapshot(HarmonySimpleState snapshot) => state = snapshot;

  @override
  Future<void> switchNode(String groupName, String proxyName) async {
    switches.add((groupName, proxyName));
  }
}

class SheetGroups extends Groups {
  @override
  List<Group> build() => const [
    Group(
      name: 'Main',
      type: GroupType.Selector,
      all: [
        Proxy(name: 'route-one', type: 'Trojan'),
        Proxy(name: 'route-two', type: 'Trojan'),
        Proxy(name: 'DIRECT', type: 'Direct'),
        Proxy(name: 'COMPATIBLE', type: 'Compatible'),
      ],
    ),
  ];
}

HarmonySession testSession(String token) => HarmonySession(
  token,
  'harmony',
  DateTime.now().add(const Duration(days: 1)),
);

Finder get primaryFilledButton => find.descendant(
  of: find.byType(SimpleConnectionPanel),
  matching: find.byType(FilledButton),
);

Widget app(Widget child, {Locale locale = const Locale('zh', 'CN')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.delegate.supportedLocales,
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
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pump();
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
        await tester.pump(const Duration(milliseconds: 400));
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
  test('running service alone never produces a connected status', () {
    const initial = HarmonySimpleState(bootstrapping: false);
    expect(connectionPhaseFor(initial, true), ConnectionPhase.checking);
    const bothPassed = HarmonySimpleState(
      bootstrapping: false,
      connectionRequested: true,
      health: HarmonyConnectionHealth.connected,
      domesticHealthy: true,
      foreignHealthy: true,
    );
    expect(connectionPhaseFor(bothPassed, true), ConnectionPhase.connected);
    expect(connectionPhaseFor(bothPassed, false), ConnectionPhase.checking);
    expect(
      connectionPhaseFor(bothPassed.copyWith(domesticHealthy: false), true),
      ConnectionPhase.checking,
    );
    expect(
      connectionPhaseFor(bothPassed.copyWith(foreignHealthy: false), true),
      ConnectionPhase.checking,
    );
  });

  test('health states remain distinct from service runtime', () {
    const phases = {
      HarmonyConnectionHealth.checking: ConnectionPhase.checking,
      HarmonyConnectionHealth.reconnecting: ConnectionPhase.reconnecting,
      HarmonyConnectionHealth.degraded: ConnectionPhase.degraded,
      HarmonyConnectionHealth.offline: ConnectionPhase.offline,
      HarmonyConnectionHealth.captivePortal: ConnectionPhase.captivePortal,
      HarmonyConnectionHealth.loginRequired: ConnectionPhase.loginRequired,
      HarmonyConnectionHealth.noRoute: ConnectionPhase.noRoute,
    };
    for (final entry in phases.entries) {
      for (final running in [false, true]) {
        expect(
          connectionPhaseFor(
            HarmonySimpleState(
              bootstrapping: false,
              connectionRequested: true,
              health: entry.key,
            ),
            running,
          ),
          entry.value,
        );
      }
    }
  });

  for (final locale in const [Locale('en'), Locale('zh', 'CN')]) {
    testWidgets('$locale explains each health state without claiming success', (
      tester,
    ) async {
      final texts = await AppLocalizations.load(locale);
      final phases = {
        ConnectionPhase.checking: texts.harmonyChecking,
        ConnectionPhase.reconnecting: texts.harmonyReconnecting,
        ConnectionPhase.degraded: texts.harmonyDegraded,
        ConnectionPhase.offline: texts.harmonyOffline,
        ConnectionPhase.captivePortal: texts.harmonyCaptivePortal,
        ConnectionPhase.loginRequired: texts.harmonyLoginRequired,
        ConnectionPhase.noRoute: texts.harmonyNoRoute,
      };
      for (final entry in phases.entries) {
        var disconnects = 0;
        await tester.pumpWidget(
          scoped(
            api: SignedOutApi(),
            child: app(
              SimpleConnectionPanel(
                phase: entry.key,
                username: 'harmony',
                connectionRequested: true,
                onToggle: () => disconnects++,
              ),
              locale: locale,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text(texts.harmonyConnected), findsNothing);
        expect(find.text(texts.simpleRunning), findsNothing);
        expect(find.text(texts.simpleDisconnect), findsOneWidget);
        final button = tester.widget<FilledButton>(primaryFilledButton);
        expect(button.onPressed, isNotNull);
        button.onPressed!();
        expect(disconnects, 1);
        if (entry.key != ConnectionPhase.captivePortal) {
          expect(find.text(texts.harmonyCaptivePortalHint), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$locale identifies which route check failed', (tester) async {
      final texts = await AppLocalizations.load(locale);
      for (final domesticFailed in [true, false]) {
        await tester.pumpWidget(
          scoped(
            api: SignedOutApi(),
            child: app(
              SimpleConnectionPanel(
                phase: ConnectionPhase.degraded,
                username: 'harmony',
                connectionRequested: true,
                domesticHealthy: !domesticFailed,
                foreignHealthy: domesticFailed,
              ),
              locale: locale,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.text(
            domesticFailed
                ? texts.harmonyDomesticUnavailable
                : texts.harmonyForeignUnavailable,
          ),
          findsOneWidget,
        );
        final failedLabel = domesticFailed
            ? texts.harmonyDomesticCheck
            : texts.harmonyForeignCheck;
        final result = find.text('$failedLabel: ${texts.harmonyCheckFailed}');
        await tester.scrollUntilVisible(
          result,
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(result, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'cached settings do not imply that a healthy network is offline',
    (tester) async {
      final texts = await AppLocalizations.load(const Locale('en'));
      await tester.pumpWidget(
        scoped(
          api: SignedOutApi(),
          child: app(
            const SimpleConnectionPanel(
              phase: ConnectionPhase.connected,
              username: 'harmony',
              connectionRequested: true,
              domesticHealthy: true,
              foreignHealthy: true,
              usingCachedConfig: true,
            ),
            locale: const Locale('en'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(texts.harmonyConnected), findsOneWidget);
      expect(find.text('Using saved connection settings'), findsOneWidget);
      expect(find.textContaining('(offline)'), findsNothing);
      expect(find.text(texts.harmonyOffline), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('busy checking blocks retry, sign-out and duplicate actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      scoped(
        api: SignedOutApi(),
        child: app(
          SimpleConnectionPanel(
            phase: ConnectionPhase.checking,
            username: 'harmony',
            busy: true,
            connectionRequested: true,
            error: 'test error',
            onToggle: () {},
            onRetry: () {},
            onLogout: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<FilledButton>(primaryFilledButton).onPressed, isNull);
    for (final label in ['重试', '退出登录']) {
      final button = find.widgetWithText(TextButton, label);
      await tester.scrollUntilVisible(
        button,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<TextButton>(button).onPressed, isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'visible health strings follow locale changes on the same screen',
    (tester) async {
      final locale = ValueNotifier(const Locale('en'));
      addTearDown(locale.dispose);
      await tester.pumpWidget(
        scoped(
          api: SignedOutApi(),
          child: ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (context, value, child) => app(child!, locale: value),
            child: const SimpleConnectionPanel(
              phase: ConnectionPhase.degraded,
              username: 'harmony',
              connectionRequested: true,
              domesticHealthy: true,
              foreignHealthy: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connection partly available'), findsOneWidget);
      locale.value = const Locale('zh', 'CN');
      await tester.pumpAndSettle();
      expect(find.text('部分网络不可用'), findsOneWidget);
      expect(find.text('Connection partly available'), findsNothing);
      locale.value = const Locale('en');
      await tester.pumpAndSettle();
      expect(find.text('Connection partly available'), findsOneWidget);
      expect(find.text('部分网络不可用'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'status is a live region and reduced-motion recovery stays still',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        for (final phase in [
          ConnectionPhase.checking,
          ConnectionPhase.reconnecting,
        ]) {
          await tester.pumpWidget(
            scoped(
              api: SignedOutApi(),
              child: app(
                MediaQuery(
                  data: const MediaQueryData(disableAnimations: true),
                  child: SimpleConnectionPanel(
                    phase: phase,
                    username: 'harmony',
                    connectionRequested: true,
                    onToggle: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final status = phase == ConnectionPhase.checking
              ? '正在检查连接…'
              : '正在自动重连…';
          final liveRegion = find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.liveRegion == true &&
                widget.properties.label == status,
          );
          expect(liveRegion, findsOneWidget);
          expect(find.bySemanticsLabel(status), findsOneWidget);
          expect(
            tester
                .widget<CircularProgressIndicator>(
                  find.byType(CircularProgressIndicator),
                )
                .value,
            isNotNull,
          );
          expect(tester.binding.hasScheduledFrame, isFalse);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final change in ['logout', 'new session', 'recovery', 'recovered']) {
    testWidgets('late node sheet is ignored after $change', (tester) async {
      final initial = HarmonySimpleState(
        bootstrapping: false,
        connectionRequested: true,
        session: testSession('first-token'),
        health: HarmonyConnectionHealth.connected,
        domesticHealthy: true,
        foreignHealthy: true,
      );
      final controller = ControlledHarmonySimple(initial);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            harmonySimpleProvider.overrideWith(() => controller),
            harmonyAccountApiProvider.overrideWithValue(SignedOutApi()),
            profilesProvider.overrideWith(_EmptyProfiles.new),
            currentProfileProvider.overrideWithValue(
              const Profile(
                id: 7,
                currentGroupName: 'Main',
                autoUpdateDuration: Duration(hours: 24),
                selectedMap: {'Main': 'route-one'},
              ),
            ),
            groupsProvider.overrideWith(SheetGroups.new),
            initProvider.overrideWithValue(true),
            isStartProvider.overrideWithValue(true),
            totalTrafficProvider.overrideWithValue(const Traffic()),
            trafficsProvider.overrideWithValue(FixedList(0)),
          ],
          child: app(const SimpleDashboardView()),
        ),
      );
      await tester.pumpAndSettle();
      final switcher = find.byTooltip('切换节点');
      await tester.scrollUntilVisible(
        switcher,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(switcher);
      await tester.pumpAndSettle();
      expect(find.text('DIRECT'), findsNothing);
      expect(find.text('COMPATIBLE'), findsNothing);
      controller.setSnapshot(switch (change) {
        'logout' => const HarmonySimpleState(bootstrapping: false),
        'new session' => initial.copyWith(session: testSession('new-token')),
        _ => initial.copyWith(health: HarmonyConnectionHealth.reconnecting),
      });
      await tester.pump();
      if (change == 'recovered') {
        controller.setSnapshot(initial);
        await tester.pump();
      }
      await tester.tap(find.text('route-two'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.switches, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'an existing account error is relocalized without another login',
    (tester) async {
      final controller = ControlledHarmonySimple(
        const HarmonySimpleState(
          bootstrapping: false,
          errorCause: HarmonySimpleError.credentials,
        ),
      );
      final locale = ValueNotifier(const Locale('en'));
      addTearDown(locale.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            harmonySimpleProvider.overrideWith(() => controller),
            profilesProvider.overrideWith(_EmptyProfiles.new),
            initProvider.overrideWithValue(true),
            isStartProvider.overrideWithValue(false),
          ],
          child: ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (context, value, child) => app(child!, locale: value),
            child: const SimpleDashboardView(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Incorrect username or password.'));
      expect(find.text('Incorrect username or password.'), findsOneWidget);
      locale.value = const Locale('zh', 'CN');
      await tester.pumpAndSettle();
      expect(find.text('用户名或密码错误。'), findsOneWidget);
      expect(find.text('Incorrect username or password.'), findsNothing);
      expect(controller.switches, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('repeated health changes never leave a stale success label', (
    tester,
  ) async {
    final phase = ValueNotifier(ConnectionPhase.checking);
    addTearDown(phase.dispose);
    await tester.pumpWidget(
      scoped(
        api: SignedOutApi(),
        child: app(
          ValueListenableBuilder<ConnectionPhase>(
            valueListenable: phase,
            builder: (context, value, child) => SimpleConnectionPanel(
              phase: value,
              username: 'harmony',
              connectionRequested: true,
              onToggle: () {},
            ),
          ),
        ),
      ),
    );
    for (var cycle = 0; cycle < 3; cycle++) {
      for (final value in [
        ConnectionPhase.checking,
        ConnectionPhase.connected,
        ConnectionPhase.reconnecting,
        ConnectionPhase.degraded,
        ConnectionPhase.offline,
      ]) {
        phase.value = value;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.text('已连接'),
          value == ConnectionPhase.connected ? findsOneWidget : findsNothing,
        );
        expect(
          tester.widget<FilledButton>(primaryFilledButton).onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
