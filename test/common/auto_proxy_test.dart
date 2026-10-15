import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const mainGroup = Group(
  name: 'Cloud Main',
  type: GroupType.Selector,
  now: 'Configured',
  all: [
    Proxy(name: 'Configured', type: 'Hysteria2'),
    Proxy(name: 'Faster', type: 'Vless'),
    Proxy(name: 'DIRECT', type: 'Direct'),
  ],
);

void main() {
  test('reads the hosted catch-all and never invents an alternate group', () {
    const ads = Group(name: 'Ads', type: GroupType.Selector);
    expect(
      connectionGroup(
        [ads, mainGroup],
        ['DOMAIN,ads.test,Ads', 'MATCH, Cloud Main'],
      ),
      mainGroup,
    );
    expect(connectionGroup([mainGroup], ['FINAL,Cloud Main']), mainGroup);
    expect(connectionGroup([mainGroup], ['MATCH,DIRECT']), isNull);
    expect(connectionGroup([mainGroup], ['MATCH,Missing']), isNull);
    expect(connectionGroup([mainGroup], []), isNull);
  });

  for (final delay in [12, 0, -1, null]) {
    test('probes only the configured group with delay $delay', () async {
      final measured = <String>[];
      final available = await probeConfiguredRoute(mainGroup, (name) async {
        measured.add(name);
        return delay;
      });
      expect(available, delay != null && delay > 0);
      expect(measured, ['Cloud Main']);
      expect(mainGroup.now, 'Configured');
      expect(mainGroup.all.first.name, 'Configured');
    });
  }

  test('failed probe never falls back to a node or DIRECT', () async {
    final measured = <String>[];
    final available = await probeConfiguredRoute(mainGroup, (name) async {
      measured.add(name);
      throw StateError('unreachable');
    });
    expect(available, isFalse);
    expect(measured, ['Cloud Main']);
  });

  test('unresponsive health check has a bounded wait', () {
    fakeAsync((async) {
      bool? available;
      probeConfiguredRoute(
        mainGroup,
        (_) => Completer<int?>().future,
      ).then((value) => available = value);
      async.elapse(const Duration(seconds: 24));
      expect(available, isFalse);
    });
  });
}
