import 'package:fl_clash/common/compute.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const testUrl = 'https://www.gstatic.com/generate_204';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a provider leaf sharing its group name remains unresolved safely', () {
    const root = Group(
      name: 'Harmony Auto',
      type: GroupType.URLTest,
      now: 'Harmony Auto',
      testUrl: testUrl,
      all: [
        Proxy(name: 'Harmony Auto', type: 'URLTest'),
        Proxy(name: 'Other', type: 'Trojan'),
      ],
    );
    final selected = computeRealSelectedProxyState(
      root.name,
      groups: [root],
      selectedMap: {},
    );
    expect(
      selected,
      const SelectedProxyState(
        proxyName: 'Harmony Auto',
        group: true,
        testUrl: testUrl,
      ),
    );
  });

  test(
    'a two-group cycle keeps the repeated group state without recursion',
    () {
      const first = Group(
        name: 'First',
        type: GroupType.URLTest,
        now: 'Second',
        testUrl: 'https://first.example/generate_204',
      );
      const second = Group(
        name: 'Second',
        type: GroupType.Fallback,
        now: 'First',
        testUrl: testUrl,
      );
      final selected = computeRealSelectedProxyState(
        first.name,
        groups: [first, second],
        selectedMap: {},
      );
      expect(
        selected,
        const SelectedProxyState(
          proxyName: 'First',
          group: true,
          testUrl: testUrl,
        ),
      );
    },
  );

  test(
    'valid chains keep selector overrides and automatic selected leaves',
    () {
      const root = Group(
        name: 'Main',
        type: GroupType.Selector,
        now: 'Old',
        testUrl: 'https://selector.example/generate_204',
      );
      const automatic = Group(
        name: 'Auto',
        type: GroupType.URLTest,
        now: 'Working leaf',
        testUrl: testUrl,
      );
      final selected = computeRealSelectedProxyState(
        root.name,
        groups: [root, automatic],
        selectedMap: {'Main': 'Auto', 'Auto': 'Ignored fixed preference'},
      );
      expect(
        selected,
        const SelectedProxyState(
          proxyName: 'Working leaf',
          group: true,
          testUrl: testUrl,
        ),
      );
      expect(
        computeProxyDelayState(
          proxyName: root.name,
          testUrl: 'https://fallback.example/generate_204',
          groups: [root, automatic],
          selectedMap: {'Main': 'Auto'},
          delayMap: {
            testUrl: {'Working leaf': 12},
          },
        ),
        const DelayState(delay: 12, group: true),
      );
    },
  );

  test(
    'empty names and unselected groups preserve existing result semantics',
    () {
      const empty = SelectedProxyState(proxyName: '', testUrl: testUrl);
      expect(
        getRealSelectedProxyState(empty, groups: [], selectedMap: {}),
        empty,
      );
      expect(
        computeRealSelectedProxyState(
          'Unselected',
          groups: [const Group(name: 'Unselected', type: GroupType.Selector)],
          selectedMap: {},
        ),
        const SelectedProxyState(proxyName: 'Unselected', group: true),
      );
    },
  );

  test(
    'delay sorting a real colliding core snapshot cannot overflow',
    () async {
      const rootName = 'Harmony Auto';
      final groups = await toGroupsTask(
        ComputeGroupsState(
          proxiesData: ProxiesData(
            all: [rootName],
            proxies: <String, dynamic>{
              rootName: <String, dynamic>{
                'name': rootName,
                'type': 'URLTest',
                'now': rootName,
                'testUrl': testUrl,
                // Static core-map lookup resolves the colliding child as the
                // URLTest group itself, rather than the provider's real leaf.
                'all': <String>[rootName, 'Other'],
              },
              'Other': <String, dynamic>{'name': 'Other', 'type': 'Trojan'},
            },
          ),
          sortType: ProxiesSortType.delay,
          delayMap: {
            testUrl: {rootName: 80, 'Other': 10},
          },
          selectedMap: {},
          defaultTestUrl: testUrl,
        ),
      );
      expect(groups, hasLength(1));
      expect(groups.single.now, rootName);
      expect(groups.single.all.map((proxy) => proxy.name), ['Other', rootName]);
      expect(groups.single.all.last.type, 'URLTest');
      expect(
        computeRealSelectedProxyState(
          rootName,
          groups: groups,
          selectedMap: {},
        ).proxyName,
        rootName,
      );
    },
  );
}
