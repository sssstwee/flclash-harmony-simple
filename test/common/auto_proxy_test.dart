import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const fast = Proxy(name: 'fast', type: 'Shadowsocks');
const slow = Proxy(name: 'slow', type: 'Trojan');
const direct = Proxy(name: 'DIRECT', type: 'Direct');
const reject = Proxy(name: 'REJECT', type: 'Reject');
const compatible = Proxy(name: 'COMPATIBLE', type: 'Compatible');

void main() {
  test('manual probes have six-way fanout and stop at first usable batch', () async {
    final root = Group(
      name: 'Main',
      type: GroupType.Selector,
      all: List.generate(7, (index) => Proxy(name: '$index', type: 'Trojan')),
    );
    final probes = <String, Completer<int?>>{};
    final pending = autoSelectProxy(root, [root], (name) {
      final probe = Completer<int?>();
      probes[name] = probe;
      return probe.future;
    });
    expect(probes.length, 6);
    for (final entry in probes.entries) {
      entry.value.complete(entry.key == '2' ? 5 : 100);
    }
    final result = await pending;
    expect(result?.name, '2');
    expect(probes, isNot(contains('6')));
  });

  test('first catch-all wins and an explicit direct catch-all stays unselected', () {
    const ads = Group(name: 'Ads', type: GroupType.Selector, all: [reject]);
    const main = Group(name: 'Main', type: GroupType.Selector, all: [fast]);
    expect(connectionGroup([ads, main], ['DOMAIN,ads.example,Ads', 'MATCH, Main']), main);
    expect(connectionGroup([main], ['MATCH,DIRECT', 'MATCH,Main']), isNull);
  });

  test('warms safe automatic leaves and proves actual group before accepting', () async {
    const root = Group(name: 'Main', type: GroupType.Selector, all: [slow, Proxy(name: 'Auto', type: 'URLTest')]);
    const automatic = Group(name: 'Auto', type: GroupType.URLTest, all: [fast, slow]);
    final measured = <String>[];
    final result = await autoSelectProxy(root, [root, automatic], (name) async {
      measured.add(name);
      return 42;
    });
    expect(measured, ['fast', 'slow', 'Auto']);
    expect(result?.name, 'Auto');
    expect(result?.selections, {'Main': 'Auto'});
  });

  test('managed automatic root is never pinned to a leaf', () async {
    const root = Group(
      name: 'Harmony Auto',
      icon: harmonyAutomaticGroupIcon,
      type: GroupType.URLTest,
      all: [fast, slow],
    );
    final result = await autoSelectProxy(root, [root], (_) async => 10);
    expect(result?.name, root.name);
    expect(result?.selections, isEmpty);
  });

  test('a live leaf does not prove a failed automatic route', () async {
    const root = Group(name: 'Auto', type: GroupType.URLTest, all: [fast]);
    final measured = <String>[];
    final result = await autoSelectProxy(root, [root], (name) async {
      measured.add(name);
      return name == 'fast' ? 10 : -1;
    });
    expect(result, isNull);
    expect(measured, ['fast', 'Auto']);
  });

  test('native refresh can skip duplicate leaf warm-up', () async {
    const root = Group(name: 'Auto', type: GroupType.URLTest, all: [fast]);
    final measured = <String>[];
    final result = await autoSelectProxy(root, [root], (name) async {
      measured.add(name);
      return 10;
    }, warmAutomatic: false);
    expect(measured, ['Auto']);
    expect(result?.selections, isEmpty);
  });

  test('empty automatic providers and all sentinel routes are never probed', () async {
    for (final nodes in <List<Proxy>>[
      [], [direct], [reject], [compatible],
      [const Proxy(name: 'Alias', type: 'Direct')],
      [const Proxy(name: 'Alias', type: 'Pass')],
      [const Proxy(name: 'Alias', type: 'PassRule')],
      [const Proxy(name: 'Alias', type: 'Dns')],
      [const Proxy(name: 'Alias', type: 'Rematch')],
      [const Proxy(name: 'Alias', type: 'Unknown')],
      [const Proxy(name: 'Missing', type: 'URLTest')],
    ]) {
      final root = Group(name: 'Auto', type: GroupType.URLTest, all: nodes);
      final result = await autoSelectProxy(root, [root], (_) {
        fail('Empty or non-proxy automatic routes must not be measured');
      });
      expect(result, isNull);
    }
  });

  test('one unsafe nested automatic branch rejects the whole automatic route', () async {
    const root = Group(name: 'Main', type: GroupType.Selector, all: [Proxy(name: 'Auto', type: 'URLTest'), fast]);
    const automatic = Group(name: 'Auto', type: GroupType.URLTest, all: [Proxy(name: 'Nested', type: 'Selector'), slow]);
    const nested = Group(name: 'Nested', type: GroupType.Selector, all: [direct, fast]);
    final measured = <String>[];
    final result = await autoSelectProxy(root, [root, automatic, nested], (name) async {
      measured.add(name);
      return 10;
    });
    expect(result?.selections, {'Main': 'fast'});
    expect(measured, ['fast']);
    expect(isSafeProxyRoute(const Proxy(name: 'Auto', type: 'URLTest'), [root, automatic, nested]), false);
  });

  test('fully safe nested automatic groups are recursively validated and warmed', () async {
    const root = Group(name: 'Auto', type: GroupType.URLTest, all: [Proxy(name: 'Region', type: 'Fallback')]);
    const region = Group(name: 'Region', type: GroupType.Fallback, all: [fast]);
    final measured = <String>[];
    final result = await autoSelectProxy(root, [root, region], (name) async {
      measured.add(name);
      return 10;
    });
    expect(result?.name, 'Auto');
    expect(result?.selections, isEmpty);
    expect(measured, ['fast', 'Auto']);
  });

  test('selector paths can safely choose real leaves while ignoring cycles', () async {
    const root = Group(name: 'Main', type: GroupType.Selector, all: [Proxy(name: 'Region', type: 'Selector')]);
    const region = Group(name: 'Region', type: GroupType.Selector, all: [Proxy(name: 'Main', type: 'Selector'), compatible, fast]);
    final result = await autoSelectProxy(root, [root, region], (_) async => 10);
    expect(result?.selections, {'Main': 'Region', 'Region': 'fast'});
  });

  test('automatic cycles, relay and missing groups fail closed', () async {
    const root = Group(name: 'Auto', type: GroupType.URLTest, all: [Proxy(name: 'Nested', type: 'Fallback')]);
    const nested = Group(name: 'Nested', type: GroupType.Fallback, all: [Proxy(name: 'Auto', type: 'URLTest'), fast]);
    const relay = Group(name: 'Relay', type: GroupType.Relay, all: [fast]);
    for (final group in [root, relay]) {
      expect(await autoSelectProxy(group, [root, nested, relay], (_) {
        fail('Unsafe routes must not be probed');
      }), isNull);
    }
  });

  test('safe-route filtering checks both alias types and special names', () {
    expect(isSafeProxyRoute(fast, []), true);
    for (final proxy in [
      direct, reject, compatible,
      const Proxy(name: 'Direct', type: 'Trojan'),
      const Proxy(name: 'CustomDirect', type: 'Direct'),
      const Proxy(name: 'Unresolved', type: 'Selector'),
      const Proxy(name: 'Unknown', type: 'Unknown'),
    ]) {
      expect(isSafeProxyRoute(proxy, []), false, reason: proxy.name);
    }
  });

  test('manual results reject null, zero, failure and synchronous exceptions', () async {
    const root = Group(name: 'Main', type: GroupType.Selector, all: [fast, slow]);
    for (final measure in <Future<int?> Function(String)>[
      (_) async => null,
      (_) async => 0,
      (_) async => -1,
      (_) => throw StateError('offline'),
    ]) {
      expect(await autoSelectProxy(root, [root], measure), isNull);
    }
  });

  test('duplicate leaf routes share one in-flight probe', () async {
    const root = Group(name: 'Main', type: GroupType.Selector, all: [fast, Proxy(name: 'Region', type: 'Selector')]);
    const region = Group(name: 'Region', type: GroupType.Selector, all: [fast]);
    var probes = 0;
    final pending = Completer<int?>();
    final selecting = autoSelectProxy(root, [root, region], (_) {
      probes++;
      return pending.future;
    });
    expect(probes, 1);
    pending.complete(10);
    expect((await selecting)?.selections, {'Main': 'fast'});
  });

  test('all manual work shares 24 seconds and late results start no more probes', () {
    fakeAsync((async) {
      final root = Group(name: 'Main', type: GroupType.Selector, all: List.generate(30, (index) => Proxy(name: 'Node$index', type: 'Trojan')));
      final measured = <String>[];
      final pending = Completer<int?>();
      var completed = false;
      autoSelectProxy(root, [root], (name) {
        measured.add(name);
        return pending.future;
      }).then((value) {
        expect(value, isNull);
        completed = true;
      });
      async.elapse(const Duration(seconds: 24));
      expect(completed, true);
      expect(measured, hasLength(18));
      pending.complete(1);
      async.elapse(const Duration(minutes: 1));
      expect(measured, hasLength(18));
    });
  });

  test('automatic warm-up and final route check share one deadline', () {
    fakeAsync((async) {
      final root = Group(name: 'Auto', type: GroupType.URLTest, all: List.generate(18, (index) => Proxy(name: 'Node$index', type: 'Trojan')));
      final measured = <String>[];
      var completed = false;
      autoSelectProxy(root, [root], (name) {
        measured.add(name);
        if (name == 'Auto') return Completer<int?>().future;
        return Future<int?>.delayed(const Duration(seconds: 7), () => name == 'Node12' ? 10 : null);
      }).then((value) {
        expect(value, isNull);
        completed = true;
      });
      async.elapse(const Duration(seconds: 21));
      expect(measured, hasLength(19));
      expect(measured.last, 'Auto');
      expect(completed, false);
      async.elapse(const Duration(seconds: 3));
      expect(completed, true);
      async.elapse(const Duration(minutes: 1));
      expect(measured, hasLength(19));
    });
  });

  test('automatic and manual fallback share the same global deadline', () {
    fakeAsync((async) {
      const automatic = Group(name: 'Auto', type: GroupType.URLTest, all: [fast]);
      final root = Group(
        name: 'Main',
        type: GroupType.Selector,
        all: [
          const Proxy(name: 'Auto', type: 'URLTest'),
          ...List.generate(18, (index) => Proxy(name: 'Manual$index', type: 'Trojan')),
        ],
      );
      final measured = <String>[];
      var completed = false;
      autoSelectProxy(root, [root, automatic], (name) {
        measured.add(name);
        if (name == 'fast' || name == 'Auto') {
          return Future<int?>.delayed(const Duration(seconds: 7), () => name == 'fast' ? 10 : null);
        }
        return Completer<int?>().future;
      }).then((value) {
        expect(value, isNull);
        completed = true;
      });
      async.elapse(const Duration(seconds: 14));
      expect(measured, hasLength(8));
      async.elapse(const Duration(seconds: 8));
      expect(measured, hasLength(14));
      expect(completed, false);
      async.elapse(const Duration(seconds: 2));
      expect(completed, true);
      async.elapse(const Duration(minutes: 1));
      expect(measured, hasLength(14));
    });
  });

  test('cancellation finishes immediately and prevents late selections or new probes', () {
    fakeAsync((async) {
      const root = Group(name: 'Auto', type: GroupType.URLTest, all: [fast]);
      final cancelled = Completer<void>();
      final leaf = Completer<int?>();
      final measured = <String>[];
      var completed = false;
      autoSelectProxy(root, [root], (name) {
        measured.add(name);
        return leaf.future;
      }, cancelled: cancelled.future).then((value) {
        expect(value, isNull);
        completed = true;
      });
      async.flushMicrotasks();
      expect(measured, ['fast']);
      cancelled.complete();
      async.flushMicrotasks();
      expect(completed, true);
      leaf.complete(10);
      async.elapse(const Duration(minutes: 1));
      expect(measured, ['fast']);
    });
  });

  test('an already cancelled token starts no core probes', () async {
    const root = Group(name: 'Auto', type: GroupType.URLTest, all: [fast]);
    final cancelled = Completer<void>()..complete();
    expect(await autoSelectProxy(root, [root], (_) {
      fail('Already cancelled work cannot probe');
    }, cancelled: cancelled.future), isNull);
  });

  test('superseded results cannot trigger a later batch or become selected', () async {
    const root = Group(name: 'Auto', type: GroupType.URLTest, all: [fast]);
    var current = true;
    final leaf = Completer<int?>();
    final measured = <String>[];
    final pending = autoSelectProxy(root, [root], (name) {
      measured.add(name);
      return leaf.future;
    }, isCurrent: () => current);
    current = false;
    leaf.complete(10);
    expect(await pending, isNull);
    expect(measured, ['fast']);
    expect(await autoSelectProxy(root, [root], (_) {
      fail('Already superseded work cannot probe');
    }, isCurrent: () => false), isNull);
  });
}
