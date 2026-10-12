import 'dart:async';

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
}
