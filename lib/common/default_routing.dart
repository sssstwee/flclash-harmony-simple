/// Reuses the bundled Mihomo GeoSite/GeoIP databases for automatic split routing.
List<String> defaultRoutingRules(Map<String, dynamic> config) {
  final groups = {
    for (final group in (config['proxy-groups'] as List? ?? []).cast<Map>())
      group['name'] as String: group,
  };
  final nodes = {
    for (final proxy in (config['proxies'] as List? ?? []).cast<Map>())
      if (!['direct', 'reject', 'reject-drop', 'pass'].contains(proxy['type']))
        proxy['name'] as String,
  };
  final providers = (config['proxy-providers'] as Map? ?? {}).keys.toSet();

  bool hasProxy(String name, [Set<String> visited = const {}]) {
    if (['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'GLOBAL'].contains(name) ||
        visited.contains(name)) {
      return false;
    }
    if (nodes.contains(name)) return true;
    final group = groups[name];
    if (group == null || group['type'] == 'relay') return false;
    if ((group['use'] as List? ?? []).any(providers.contains) ||
        (group['include-all'] == true &&
            (nodes.isNotEmpty || providers.isNotEmpty)) ||
        (group['include-all-proxies'] == true && nodes.isNotEmpty) ||
        (group['include-all-providers'] == true && providers.isNotEmpty)) {
      return true;
    }
    return (group['proxies'] as List? ?? []).cast<String>().any(
      (proxy) => hasProxy(proxy, {...visited, name}),
    );
  }

  String? target;
  for (final rule in (config['rules'] as List? ?? []).cast<String>().reversed) {
    final parts = rule.split(',').map((part) => part.trim()).toList();
    if (parts.length >= 2 &&
        ['MATCH', 'FINAL'].contains(parts.first.toUpperCase()) &&
        groups.containsKey(parts[1]) &&
        hasProxy(parts[1])) {
      target = parts[1];
      break;
    }
  }
  if (target == null) {
    for (final name in groups.keys) {
      if (groups[name]?['hidden'] != true && hasProxy(name)) {
        target = name;
        break;
      }
    }
  }
  if (target == null) throw StateError('No usable proxy group in subscription');

  return [
    'GEOSITE,private,DIRECT',
    'GEOSITE,cn,DIRECT',
    'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,10.0.0.0/8,DIRECT',
    'IP-CIDR,172.16.0.0/12,DIRECT',
    'IP-CIDR,192.168.0.0/16,DIRECT',
    'IP-CIDR,169.254.0.0/16,DIRECT',
    'IP-CIDR,224.0.0.0/4,DIRECT,no-resolve',
    'IP-CIDR,255.255.255.255/32,DIRECT,no-resolve',
    'IP-CIDR6,::1/128,DIRECT,no-resolve',
    'IP-CIDR6,fc00::/7,DIRECT',
    'IP-CIDR6,fe80::/10,DIRECT',
    'IP-CIDR6,ff00::/8,DIRECT,no-resolve',
    'GEOIP,CN,DIRECT',
    'MATCH,$target',
  ];
}

void excludeDirectFromAutomaticGroups(Map<String, dynamic> config) {
  final direct = {
    'DIRECT',
    'REJECT',
    'REJECT-DROP',
    'PASS',
    for (final proxy in (config['proxies'] as List? ?? []).cast<Map>())
      if (['direct', 'reject', 'reject-drop', 'pass'].contains(proxy['type']))
        proxy['name'] as String,
  };
  config['proxy-groups'] = [
    for (final group in (config['proxy-groups'] as List? ?? []).cast<Map>())
      {
        ...group,
        if (['url-test', 'fallback', 'load-balance'].contains(group['type']) &&
            ((group['proxies'] as List? ?? []).any(
                  (name) => !direct.contains(name),
                ) ||
                (group['use'] as List? ?? []).isNotEmpty ||
                group['include-all'] == true ||
                group['include-all-proxies'] == true ||
                group['include-all-providers'] == true))
          'proxies': (group['proxies'] as List? ?? [])
              .where((name) => !direct.contains(name))
              .toList(),
      },
  ];
}

void applyDefaultDns(Map<String, dynamic> config) {
  final dns = Map<String, dynamic>.from(config['dns'] as Map? ?? {});
  const directDns = [
    'https://dns.alidns.com/dns-query',
    'https://doh.pub/dns-query',
  ];
  dns['nameserver-policy'] = {
    ...Map<String, dynamic>.from(dns['nameserver-policy'] as Map? ?? {}),
    'geosite:private': ['system://'],
    'geosite:cn': directDns,
  };
  dns['direct-nameserver'] = ['system://', ...directDns];
  dns['direct-nameserver-follow-policy'] = true;
  // Rule/whitelist filters have different syntax; leave their existing behavior.
  if ((dns['fake-ip-filter-mode'] ?? 'blacklist') == 'blacklist') {
    dns['fake-ip-filter'] = {
      ...(dns['fake-ip-filter'] as List? ?? []).cast<String>(),
      'geosite:private',
      'geosite:cn',
    }.toList();
  }
  config['dns'] = dns;
}
