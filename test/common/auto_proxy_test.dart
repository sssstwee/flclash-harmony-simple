import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const fast = Proxy(name: 'fast', type: 'Shadowsocks');
const slow = Proxy(name: 'slow', type: 'Trojan');
const direct = Proxy(name: 'DIRECT', type: 'Direct');
const reject = Proxy(name: 'REJECT', type: 'Reject');

void main() {
  test(
    'probes at most six nodes and stops after the first usable batch',
    () async {
      final nodes = List.generate(
        7,
        (index) => Proxy(name: '$index', type: 'Trojan'),
      );
      final root = Group(name: 'Main', type: GroupType.Selector, all: nodes);
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
    },
  );

  test('uses the catch-all target rather than the first (ad-block) group', () {
    const ads = Group(name: 'Ads', type: GroupType.Selector, all: [reject]);
    const main = Group(name: 'Main', type: GroupType.Selector, all: [fast]);
    expect(
      connectionGroup([ads, main], ['DOMAIN,ads.example,Ads', 'MATCH, Main']),
      main,
    );
    expect(connectionGroup([main], ['MATCH,DIRECT']), isNull);
  });

  test('prefers a reachable automatic group over manual nodes', () async {
    const root = Group(
      name: 'Main',
      type: GroupType.Selector,
      all: [
        slow,
        Proxy(name: 'Auto', type: 'URLTest'),
      ],
    );
    const automatic = Group(
      name: 'Auto',
      type: GroupType.URLTest,
      all: [fast, slow],
    );
    final measured = <String>[];
    final result = await autoSelectProxy(root, [root, automatic], (name) async {
      measured.add(name);
      return 42;
    });
    expect(result?.selections, {'Main': 'Auto'});
    expect(measured, ['Auto']);
  });

  test(
    'falls back after an automatic group fails and never probes DIRECT/REJECT',
    () async {
      const root = Group(
        name: 'Main',
        type: GroupType.Selector,
        all: [
          direct,
          reject,
          Proxy(name: 'Auto', type: 'URLTest'),
          slow,
          fast,
        ],
      );
      const automatic = Group(name: 'Auto', type: GroupType.URLTest);
      final measured = <String>[];
      final result = await autoSelectProxy(root, [root, automatic], (
        name,
      ) async {
        measured.add(name);
        if (name == 'Auto') throw StateError('unavailable');
        return name == 'fast' ? 10 : 50;
      });
      expect(result?.name, 'fast');
      expect(result?.selections, {'Main': 'fast'});
      expect(measured, isNot(contains('DIRECT')));
      expect(measured, isNot(contains('REJECT')));
    },
  );

  test('retains the nested selector path while ignoring a cycle', () async {
    const root = Group(
      name: 'Main',
      type: GroupType.Selector,
      all: [Proxy(name: 'Region', type: 'Selector')],
    );
    const region = Group(
      name: 'Region',
      type: GroupType.Selector,
      all: [
        Proxy(name: 'Main', type: 'Selector'),
        fast,
      ],
    );
    final result = await autoSelectProxy(root, [root, region], (_) async => 10);
    expect(result?.selections, {'Main': 'Region', 'Region': 'fast'});
  });

  test(
    'returns no route when every candidate times out or is unavailable',
    () async {
      const root = Group(
        name: 'Main',
        type: GroupType.Selector,
        all: [fast, slow],
      );
      final result = await autoSelectProxy(root, [
        root,
      ], (name) async => name == 'fast' ? -1 : 0);
      expect(result, isNull);
    },
  );

  test(
    'manual-only probes finish at 24 seconds and never start a fourth batch',
    () {
      fakeAsync((async) {
        final root = Group(
          name: 'Main',
          type: GroupType.Selector,
          all: List.generate(
            30,
            (index) => Proxy(name: 'Node$index', type: 'Trojan'),
          ),
        );
        final measured = <String>[];
        var completed = false;
        Object? result = 'not completed';
        autoSelectProxy(root, [root], (name) {
          measured.add(name);
          return Completer<int?>().future;
        }).then((value) {
          completed = true;
          result = value;
        });
        async.flushMicrotasks();
        expect(measured, hasLength(6));
        async.elapse(const Duration(seconds: 8));
        expect(measured, hasLength(12));
        async.elapse(const Duration(seconds: 8));
        expect(measured, hasLength(18));
        async.elapse(const Duration(milliseconds: 7999));
        expect(completed, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(completed, isTrue);
        expect(result, isNull);
        expect(measured, hasLength(18));
        async.elapse(const Duration(minutes: 1));
        expect(measured, hasLength(18));
      });
    },
  );

  test(
    'automatic and manual probes share one deadline, including partial batches',
    () {
      fakeAsync((async) {
        final automatic = List.generate(
          13,
          (index) =>
              Group(name: 'Auto$index', type: GroupType.URLTest, all: [fast]),
        );
        final root = Group(
          name: 'Main',
          type: GroupType.Selector,
          all: [
            for (final group in automatic)
              Proxy(name: group.name, type: 'URLTest'),
            for (var index = 0; index < 20; index++)
              Proxy(name: 'Manual$index', type: 'Trojan'),
          ],
        );
        final measured = <String>[];
        final lateManual = Completer<int?>();
        var completed = false;
        Object? result = 'not completed';
        autoSelectProxy(root, [root, ...automatic], (name) {
          measured.add(name);
          if (name.startsWith('Auto')) {
            return Future<int?>.delayed(const Duration(seconds: 7), () => null);
          }
          return lateManual.future;
        }).then((value) {
          completed = true;
          result = value;
        });
        async.elapse(const Duration(seconds: 21));
        expect(
          measured.where((name) => name.startsWith('Auto')),
          hasLength(13),
        );
        expect(
          measured.where((name) => name.startsWith('Manual')),
          hasLength(6),
        );
        async.elapse(const Duration(milliseconds: 2999));
        expect(completed, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(completed, isTrue);
        expect(result, isNull);
        lateManual.complete(1);
        async.flushMicrotasks();
        expect(result, isNull);
        expect(measured, hasLength(19));
        async.elapse(const Duration(minutes: 1));
        expect(measured, hasLength(19));
      });
    },
  );

  test(
    'automatic-only probes also finish rather than leaving a pending future',
    () {
      fakeAsync((async) {
        final automatic = List.generate(
          30,
          (index) =>
              Group(name: 'Auto$index', type: GroupType.URLTest, all: [fast]),
        );
        final root = Group(
          name: 'Main',
          type: GroupType.Selector,
          all: [
            for (final group in automatic)
              Proxy(name: group.name, type: 'URLTest'),
          ],
        );
        var completed = false;
        final measured = <String>[];
        autoSelectProxy(root, [root, ...automatic], (name) {
          measured.add(name);
          return Completer<int?>().future;
        }).then((value) {
          expect(value, isNull);
          completed = true;
        });
        async.elapse(const Duration(seconds: 24));
        expect(completed, isTrue);
        expect(measured, hasLength(18));
      });
    },
  );

  test(
    'the same node on two selector routes has only one in-flight probe',
    () async {
      const root = Group(
        name: 'Main',
        type: GroupType.Selector,
        all: [
          fast,
          Proxy(name: 'Region', type: 'Selector'),
        ],
      );
      const region = Group(
        name: 'Region',
        type: GroupType.Selector,
        all: [fast],
      );
      var probes = 0;
      final pending = Completer<int?>();
      final selecting = autoSelectProxy(root, [root, region], (_) {
        probes++;
        return pending.future;
      });
      expect(probes, 1);
      pending.complete(10);
      final selected = await selecting;
      expect(selected?.name, 'fast');
      expect(selected?.selections, {'Main': 'fast'});
      expect(probes, 1);
    },
  );

  test(
    'DIRECT, REJECT, relay-only and cyclic routes cannot become a connection',
    () async {
      const root = Group(
        name: 'Main',
        type: GroupType.Selector,
        all: [
          direct,
          reject,
          Proxy(name: 'Relay', type: 'Relay'),
          Proxy(name: 'Main', type: 'Selector'),
        ],
      );
      const relay = Group(name: 'Relay', type: GroupType.Relay, all: [fast]);
      final selected = await autoSelectProxy(root, [root, relay], (_) {
        fail('Non-proxy routes must never be probed');
      });
      expect(selected, isNull);
    },
  );
}
