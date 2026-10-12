import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> render(
    WidgetTester tester, {
    Profile? profile,
    bool running = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentProfileProvider.overrideWithValue(profile),
          isStartProvider.overrideWithValue(running),
        ],
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: [Locale('zh', 'CN')],
          home: SimpleDashboardView(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a new user sees import as the primary action', (tester) async {
    await render(tester);
    expect(find.text('Clash Harmony'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.text('导入订阅'),
      ),
      findsOneWidget,
    );
    expect(button.onPressed, isNotNull);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets(
    'a loaded subscription enables connect and a running proxy enables disconnect',
    (tester) async {
      const profile = Profile(
        id: 1,
        label: 'Example',
        autoUpdateDuration: Duration(days: 1),
      );
      await render(tester, profile: profile);
      expect(find.text('Example'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      expect(find.text('设置'), findsNothing);
      expect(find.text('DNS'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.text('连接'),
        ),
        findsOneWidget,
      );
      await render(tester, profile: profile, running: true);
      expect(find.text('代理已启动'), findsOneWidget);
      expect(find.text('断开'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget);
    },
  );

  testWidgets(
    'narrow folded display with large text stays scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await render(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(ListView), findsOneWidget);
      await tester.scrollUntilVisible(find.byType(FilledButton), 100);
      expect(tester.takeException(), isNull);
    },
  );
}
