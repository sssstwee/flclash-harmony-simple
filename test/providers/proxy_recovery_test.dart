import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

class _Core extends Mock implements CoreController {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const ChangeProxyParams(groupName: 'Main', proxyName: 'Node'),
    );
  });

  for (final closeConnections in [true, false]) {
    for (final preserveConnections in [true, false]) {
      test(
        'route change preserve=$preserveConnections close=$closeConnections',
        () async {
          final core = _Core();
          when(() => core.changeProxy(any())).thenAnswer((_) async => '');
          when(() => core.closeConnections()).thenAnswer((_) async {});
          when(() => core.resetConnections()).thenAnswer((_) async {});
          final container = ProviderContainer(
            overrides: [
              proxiesCoreControllerProvider.overrideWithValue(core),
              appSettingProvider.overrideWithBuild(
                (_, _) => AppSettingProps(closeConnections: closeConnections),
              ),
            ],
          );
          addTearDown(container.dispose);
          container.listen(checkIpNumProvider, (_, _) {});
          final before = container.read(checkIpNumProvider);

          await container.read(proxiesActionProvider.notifier).changeProxy(
            groupName: 'Main',
            proxyName: 'Node',
            preserveConnections: preserveConnections,
          );

          verify(() => core.changeProxy(
            const ChangeProxyParams(groupName: 'Main', proxyName: 'Node'),
          )).called(1);
          if (preserveConnections) {
            verifyNever(() => core.closeConnections());
            verifyNever(() => core.resetConnections());
          } else if (closeConnections) {
            verify(() => core.closeConnections()).called(1);
            verifyNever(() => core.resetConnections());
          } else {
            verifyNever(() => core.closeConnections());
            verify(() => core.resetConnections()).called(1);
          }
          expect(container.read(checkIpNumProvider), before + 1);
        },
      );
    }
  }

  test('failed route change cannot close or reset existing flows', () async {
    final core = _Core();
    when(() => core.changeProxy(any())).thenThrow(StateError('unavailable'));
    final container = ProviderContainer(
      overrides: [proxiesCoreControllerProvider.overrideWithValue(core)],
    );
    addTearDown(container.dispose);
    container.listen(checkIpNumProvider, (_, _) {});
    final before = container.read(checkIpNumProvider);

    await expectLater(
      container.read(proxiesActionProvider.notifier).changeProxy(
        groupName: 'Main',
        proxyName: 'Node',
        preserveConnections: true,
      ),
      throwsStateError,
    );

    verifyNever(() => core.closeConnections());
    verifyNever(() => core.resetConnections());
    expect(container.read(checkIpNumProvider), before);
  });

  test('native route error cannot record success or close existing flows', () async {
    final core = _Core();
    when(() => core.changeProxy(any())).thenAnswer((_) async => 'not found');
    final container = ProviderContainer(
      overrides: [proxiesCoreControllerProvider.overrideWithValue(core)],
    );
    addTearDown(container.dispose);
    container.listen(checkIpNumProvider, (_, _) {});
    final before = container.read(checkIpNumProvider);

    await expectLater(
      container.read(proxiesActionProvider.notifier).changeProxy(
        groupName: 'Main',
        proxyName: 'Node',
      ),
      throwsStateError,
    );

    verifyNever(() => core.closeConnections());
    verifyNever(() => core.resetConnections());
    expect(container.read(checkIpNumProvider), before);
  });

}
