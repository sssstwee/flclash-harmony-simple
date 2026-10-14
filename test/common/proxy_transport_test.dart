import 'package:fl_clash/common/proxy_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classifies hysteria2 as UDP-heavy and vless as TCP-friendly', () {
    expect(proxyTransportKind('hysteria2'), ProxyTransportKind.udpHeavy);
    expect(proxyTransportKind('vless'), ProxyTransportKind.tcpFriendly);
    expect(proxyTransportKind('anytls'), ProxyTransportKind.tcpFriendly);
  });

  test('uses shorter UDP probe timeouts when TCP is preferred', () {
    expect(
      probeTimeoutFor(ProxyTransportKind.udpHeavy, preferTcp: true),
      const Duration(seconds: 3),
    );
    expect(
      probeTimeoutFor(ProxyTransportKind.tcpFriendly),
      const Duration(seconds: 8),
    );
  });

  test('infers TCP preference when UDP probes fail but TCP succeeds', () {
    final kinds = {
      'hy2': ProxyTransportKind.udpHeavy,
      'tcp': ProxyTransportKind.tcpFriendly,
    };
    expect(inferPreferTcpFromDelays({'hy2': null, 'tcp': 42}, kinds), isTrue);
    expect(inferPreferTcpFromDelays({'hy2': 10, 'tcp': 42}, kinds), isFalse);
  });

  test('sorts manual candidates TCP-first when preferTcp is set', () {
    final ordered = sortByTransportPreference(
      ['hy2', 'vless', 'anytls'],
      (name) => switch (name) {
        'hy2' => ProxyTransportKind.udpHeavy,
        'vless' => ProxyTransportKind.tcpFriendly,
        _ => ProxyTransportKind.tcpFriendly,
      },
      preferTcp: true,
    );
    expect(ordered.first, isNot('hy2'));
    expect(ordered.last, 'hy2');
  });
}
