import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/harmony_simple.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/simple.dart';
import 'package:fl_clash/views/dashboard/widgets/simple_connection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class SignedOutApi extends HarmonyAccountApi {
  SignedOutApi() : super(http: Dio(BaseOptions(baseUrl: 'https://api.example.test')));

  int logins = 0;

  @override
  Future<HarmonySession?> restore() async => null;

  @override
  Future<HarmonySession> login(String username, String password) async {
    logins++;
    throw HarmonyAccountError.credentials;
  }
}

class IdleHarmonySimple extends HarmonySimple {
  @override
  HarmonySimpleState build() => const HarmonySimpleState(bootstrapping: false);

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> checkSession() async {}
}

Finder get primaryFilledButton => find.descendant(
  of: find.byType(SimpleConnectionPanel),
  matching: find.byType(FilledButton),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await AppLocalizations.load(const Locale('zh', 'CN'));
  });

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

  List<Override> dashboardOverrides(SignedOutApi api) => [
    harmonyAccountApiProvider.overrideWithValue(api),
    harmonySimpleProvider.overrideWith(IdleHarmonySimple.new),
    initProvider.overrideWithValue(true),
    isStartProvider.overrideWithValue(false),
  ];

  List<Override> connectionOverrides() => [
    totalTrafficProvider.overrideWithValue(const Traffic()),
    trafficsProvider.overrideWithValue(FixedList(0)),
  ];

  Future<void> renderLogin(WidgetTester tester, SignedOutApi api) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: dashboardOverrides(api),
        child: app(const SimpleDashboardView()),
      ),
    );
    await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      expect(api.logins, 0);
      expect(find.text('请填写此项。'), findsNWidgets(2));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(ListTile), findsNothing);
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
      tester.widget<EditableText>(find.byType(EditableText).last).controller.text,
      isEmpty,
    );
  });

  testWidgets(
    'connection phases expose one disabled action during transitions',
    (tester) async {
      for (final phase in ConnectionPhase.values) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: connectionOverrides(),
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
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reduced motion avoids continuously running animations', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: connectionOverrides(),
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
        ProviderScope(
          overrides: connectionOverrides(),
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
    },
  );
}
