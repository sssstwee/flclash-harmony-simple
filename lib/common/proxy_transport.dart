/// Transport hints used to fail over quickly when UDP is blocked.
enum ProxyTransportKind { udpHeavy, tcpFriendly, unknown }

const _udpHeavyTypes = {'hysteria', 'hysteria2', 'tuic', 'wireguard'};

const _tcpFriendlyTypes = {
  'vless',
  'vmess',
  'trojan',
  'ss',
  'shadowsocks',
  'anytls',
  'socks',
  'socks5',
  'http',
  'snell',
};

ProxyTransportKind proxyTransportKind(String? type, [String? name]) {
  final normalized = (type ?? '').toLowerCase();
  if (_udpHeavyTypes.contains(normalized)) {
    return ProxyTransportKind.udpHeavy;
  }
  if (_tcpFriendlyTypes.contains(normalized)) {
    return ProxyTransportKind.tcpFriendly;
  }
  final label = (name ?? '').toLowerCase();
  if (label.contains('hysteria') || label.contains('hy2')) {
    return ProxyTransportKind.udpHeavy;
  }
  if (label.contains('reality') ||
      label.contains('anytls') ||
      label.contains('vless')) {
    return ProxyTransportKind.tcpFriendly;
  }
  return ProxyTransportKind.unknown;
}

Duration probeTimeoutFor(ProxyTransportKind kind, {bool preferTcp = false}) {
  return switch (kind) {
    ProxyTransportKind.udpHeavy when preferTcp => const Duration(seconds: 3),
    ProxyTransportKind.udpHeavy => const Duration(seconds: 5),
    ProxyTransportKind.tcpFriendly => const Duration(seconds: 8),
    ProxyTransportKind.unknown => const Duration(seconds: 6),
  };
}

/// Returns true when UDP-heavy probes failed but at least one TCP probe succeeded.
bool inferPreferTcpFromDelays(
  Map<String, int?> delays,
  Map<String, ProxyTransportKind> kinds,
) {
  var udpProbed = false;
  var udpOk = false;
  var tcpOk = false;
  for (final entry in delays.entries) {
    final kind = kinds[entry.key] ?? ProxyTransportKind.unknown;
    final delay = entry.value;
    final ok = delay != null && delay > 0;
    if (kind == ProxyTransportKind.udpHeavy) {
      udpProbed = true;
      if (ok) udpOk = true;
    } else if (kind == ProxyTransportKind.tcpFriendly && ok) {
      tcpOk = true;
    }
  }
  return udpProbed && !udpOk && tcpOk;
}

int transportSortKey(ProxyTransportKind kind, {required bool preferTcp}) {
  if (!preferTcp) return 0;
  return switch (kind) {
    ProxyTransportKind.tcpFriendly => 0,
    ProxyTransportKind.unknown => 1,
    ProxyTransportKind.udpHeavy => 2,
  };
}

List<T> sortByTransportPreference<T>(
  Iterable<T> items,
  ProxyTransportKind Function(T item) kindOf, {
  required bool preferTcp,
}) {
  if (!preferTcp) return items.toList();
  final list = items.toList();
  list.sort(
    (a, b) => transportSortKey(
      kindOf(a),
      preferTcp: preferTcp,
    ).compareTo(transportSortKey(kindOf(b), preferTcp: preferTcp)),
  );
  return list;
}

Map<String, String> proxyTypesFromConfig(Map<String, dynamic> config) {
  return {
    for (final proxy in (config['proxies'] as List? ?? []).cast<Map>())
      if (proxy['name'] is String && proxy['type'] is String)
        proxy['name'] as String: (proxy['type'] as String).toLowerCase(),
  };
}

Map<String, ProxyTransportKind> transportKindsFromConfig(
  Map<String, dynamic> config,
) {
  return {
    for (final entry in proxyTypesFromConfig(config).entries)
      entry.key: proxyTransportKind(entry.value, entry.key),
  };
}
