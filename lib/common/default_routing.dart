import 'generated/routing_policy.g.dart';

/// Built-in overseas categories inserted before the catch-all rule.
const builtinGeositeCategories = [('GEOSITE,category-ai-!cn', 'ai')];

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
      if (name != aiRoutingGroupName &&
          groups[name]?['hidden'] != true &&
          hasProxy(name)) {
        target = name;
        break;
      }
    }
  }
  if (target == null) throw StateError('No usable proxy group in subscription');

  configureAiRouting(config);
  excludeDirectFromAutomaticGroups(config);
  final aiTarget = routingPolicy['aiGroup'] as String;
  final preserved = <String>[];
  for (final rule in (config['rules'] as List? ?? []).cast<String>()) {
    final parts = rule.split(',').map((part) => part.trim()).toList();
    if (parts.length != 3 ||
        ![
          'DOMAIN',
          'DOMAIN-SUFFIX',
          'DOMAIN-KEYWORD',
          'DOMAIN-WILDCARD',
          'GEOSITE',
        ].contains(parts[0])) {
      continue;
    }
    if (hasProxy(parts[2]) || nameHintsAi(parts[2])) {
      preserved.add(
        '${parts[0]},${parts[1]},${nameHintsAi(parts[2]) ? aiTarget : target}',
      );
    }
  }
  return {
    ...policyList('privateRules'),
    for (final domain in policyList('domesticAiDomains'))
      'DOMAIN-SUFFIX,$domain,DIRECT',
    for (final rule in policyList('aiRules')) '$rule,$aiTarget',
    for (final rule in policyList('overseasRules')) '$rule,$target',
    'GEOSITE,cn,DIRECT',
    ...preserved,
    'GEOSITE,geolocation-!cn,$target',
    'GEOIP,CN,DIRECT',
    'MATCH,$target',
  }.toList();
}

/// Resolves a built-in category (e.g. AI) to a subscription group name.
String? resolveBuiltinCategoryGroup(
  Map<String, dynamic> config,
  String category,
  bool Function(String name) hasProxy,
) {
  if (category != 'ai') return null;
  return findAiServiceGroup(config, hasProxy);
}

List<String> policyList(String key) =>
    (routingPolicy[key] as List).cast<String>();
final aiRoutingGroupName = routingPolicy['aiGroup'] as String;

bool nameHintsAi(String name) => RegExp(
  r'🤖|智能|(?:^|[^a-z])ai(?:[^a-z]|$)|openai|chatgpt|claude|gemini|gpt',
  caseSensitive: false,
).hasMatch(name);

/// Explicit leaf allowlists: native first, WARP last, never a local/unknown route.
void configureAiRouting(Map<String, dynamic> config) {
  final nodes = {
    for (final node in (config['proxies'] as List? ?? []).cast<Map>())
      node['name'] as String: node,
  };
  final candidates =
      [...policyList('nativeProxies'), ...policyList('warpProxies')].where((
        name,
      ) {
        final node = nodes[name];
        return node != null &&
            ['vless', 'hysteria2', 'anytls'].contains(node['type']) &&
            (node['dialer-proxy'] == null || node['dialer-proxy'] == '');
      }).toList();
  Map<String, dynamic> group(String name) => candidates.isEmpty
      ? {
          'name': name,
          'type': 'select',
          'proxies': ['REJECT'],
        }
      : {
          'name': name,
          'type': 'fallback',
          'proxies': candidates,
          'url': 'https://api.openai.com/v1/models',
          'expected-status': 401,
          'interval': 90,
          'lazy': false,
          'timeout': 5000,
          'max-failed-times': 2,
        };
  config['proxy-groups'] = [
    for (final existing in (config['proxy-groups'] as List? ?? []).cast<Map>())
      if (existing['name'] != aiRoutingGroupName)
        if (nameHintsAi(existing['name'] as String))
          group(existing['name'] as String)
        else
          Map<String, dynamic>.from(existing),
    group(aiRoutingGroupName),
  ];
}

/// A WARP label alone is not an AI routing policy.
String? findAiServiceGroup(
  Map<String, dynamic> config,
  bool Function(String name) hasProxy,
) {
  final groups = (config['proxy-groups'] as List? ?? []).cast<Map>();
  if (groups.any((group) => group['name'] == aiRoutingGroupName)) {
    return aiRoutingGroupName;
  }
  for (final group in groups) {
    final name = group['name'] as String?;
    if (name != null && nameHintsAi(name) && hasProxy(name)) return name;
  }
  return null;
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
  final groups = {
    for (final group in (config['proxy-groups'] as List? ?? []).cast<Map>())
      group['name'] as String: group,
  };
  final nodes = {
    for (final proxy in (config['proxies'] as List? ?? []).cast<Map>())
      if (!direct.contains(proxy['name'])) proxy['name'] as String,
  };
  final providers = (config['proxy-providers'] as Map? ?? {}).keys.toSet();
  bool proxyRoute(String name, [Set<String> visited = const {}]) {
    if (direct.contains(name) || name == 'GLOBAL' || visited.contains(name)) {
      return false;
    }
    if (nodes.contains(name)) return true;
    final group = groups[name];
    if (group == null || group['type'] == 'relay') return false;
    return (group['use'] as List? ?? []).any(providers.contains) ||
        (group['include-all'] == true &&
            (nodes.isNotEmpty || providers.isNotEmpty)) ||
        (group['include-all-proxies'] == true && nodes.isNotEmpty) ||
        (group['include-all-providers'] == true && providers.isNotEmpty) ||
        (group['proxies'] as List? ?? []).cast<String>().any(
          (child) => proxyRoute(child, {...visited, name}),
        );
  }

  config['proxy-groups'] = [
    for (final group in groups.values)
      {
        ...group,
        if (proxyRoute(group['name'] as String) && group['proxies'] is List)
          'proxies': (group['proxies'] as List)
              .cast<String>()
              .where(proxyRoute)
              .toList(),
      },
  ];
}

void applyDefaultDns(Map<String, dynamic> config) {
  final dns = Map<String, dynamic>.from(config['dns'] as Map? ?? {});
  final directDns = policyList('directDns');
  final policy = Map<String, dynamic>.from(
    dns['nameserver-policy'] as Map? ?? {},
  );
  if ((config['proxy-groups'] as List? ?? []).cast<Map>().any(
    (group) => group['name'] == aiRoutingGroupName,
  )) {
    final rules = defaultRoutingRules(config);
    for (final rule in rules) {
      final parts = rule.split(',');
      if (parts.length != 3 || parts[2] != aiRoutingGroupName) continue;
      final key = switch (parts[0]) {
        'DOMAIN' => parts[1],
        'DOMAIN-SUFFIX' => '+.${parts[1]}',
        'GEOSITE' => 'geosite:${parts[1]}',
        _ => null,
      };
      if (key != null) {
        policy[key] = 'https://1.1.1.1/dns-query#$aiRoutingGroupName';
      }
    }
    final lastRule = rules.last.split(',');
    final target = lastRule[1];
    dns['nameserver'] = [
      'https://1.1.1.1/dns-query#$target',
      'https://dns.google/dns-query#$target',
    ];
    dns['proxy-server-nameserver'] = ['223.5.5.5', '119.29.29.29'];
  }
  for (final domain in policyList('domesticAiDomains')) {
    policy['+.$domain'] = directDns;
  }
  policy['geosite:private'] = ['system://'];
  policy['geosite:cn'] = directDns;
  dns['enable'] = true;
  dns['nameserver-policy'] = policy;
  dns['direct-nameserver'] = ['system://', ...directDns];
  dns['direct-nameserver-follow-policy'] = true;
  dns['respect-rules'] = true;
  // Rule/whitelist filters have different syntax; leave their existing behavior.
  if ((dns['fake-ip-filter-mode'] ?? 'blacklist') == 'blacklist') {
    dns['fake-ip-filter'] = {
      ...(dns['fake-ip-filter'] as List? ?? []).cast<String>(),
      'geosite:private',
      'geosite:cn',
      ...policyList('connectivityFakeIpFilters'),
    }.toList();
  }
  config['dns'] = dns;
}
