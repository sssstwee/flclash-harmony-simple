/// The core and foreground recovery must measure the same URL: Mihomo keeps
/// independent health histories for each test URL.
const harmonyAutomaticTestUrl = 'https://www.gstatic.com/generate_204';
const harmonyAutomaticGroupIcon = 'flclash-internal://harmony-auto/v1';
const harmonyAutomaticInterval = 60;
const harmonyAutomaticTolerance = 50;
const _managedMarker = 'x-harmony-managed';
const _managedVersion = 1;
const _managedName = 'Harmony Auto';

// These are adapter type names (not YAML type names) in the pinned Mihomo core.
// Filtering is also applied after providers expand, including later updates.
const _excludedAutomaticTypes =
    'Direct|Compatible|Reject|RejectDrop|Pass|PassRule|Rematch|Dns|'
    'Selector|URLTest|Fallback|LoadBalance|Relay';

String _normalized(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp('[-_]'), '');

/// Accept both subscription YAML and runtime adapter type names. An unknown or
/// unresolved group is never assumed to be a working outbound proxy.
bool isHarmonyProxyLeaf(String name, String type) {
  if (const {
    'direct', 'compatible', 'reject', 'rejectdrop', 'pass', 'passrule',
    'rematch', 'dns', 'global', '',
  }.contains(_normalized(name))) {
    return false;
  }
  return const {
    'ss', 'shadowsocks', 'ssr', 'shadowsocksr', 'snell', 'socks5', 'http',
    'vmess', 'vless', 'trojan', 'hysteria', 'hysteria2', 'wireguard', 'tuic',
    'ssh', 'mieru', 'anytls', 'sudoku', 'masque', 'trusttunnel', 'shadowquic',
    'openvpn', 'tailscale', 'gostrelay',
  }.contains(_normalized(type));
}

List<Map<String, dynamic>> _groups(Map<String, dynamic> config) => [
  for (final group in (config['proxy-groups'] as List? ?? []))
    Map<String, dynamic>.from(group as Map),
];

/// Resolves the same collision-free name from the original subscription or an
/// already generated config. The marker is regenerated, never trusted for safety.
String effectiveHarmonyAutoGroupName(Map<String, dynamic> config) {
  final groups = _groups(config);
  for (final group in groups) {
    if (group[_managedMarker] == _managedVersion && group['name'] is String) {
      return group['name'] as String;
    }
  }
  final names = <String>{
    'GLOBAL', 'DIRECT', 'REJECT', 'COMPATIBLE',
    for (final group in groups) group['name'] as String,
    for (final proxy in (config['proxies'] as List? ?? []))
      (proxy as Map)['name'] as String,
    ...(config['proxy-providers'] as Map? ?? {}).keys.cast<String>(),
  };
  var name = _managedName;
  var suffix = 2;
  while (names.contains(name)) {
    name = '$_managedName ${suffix++}';
  }
  return name;
}

/// Adds continuous core-level failover even to selector-only subscriptions.
/// The app-owned group contains only real leaves and expanded providers, never
/// subscription selectors/automatic groups that could later resolve to DIRECT.
/// Original groups remain available to explicit per-service subscription rules.
String applyHarmonyAutomaticRouting(Map<String, dynamic> config) {
  final name = effectiveHarmonyAutoGroupName(config);
  final nodes = <String>{
    for (final proxy in (config['proxies'] as List? ?? []).cast<Map>())
      if (isHarmonyProxyLeaf('${proxy['name'] ?? ''}', '${proxy['type'] ?? ''}'))
        proxy['name'] as String,
  }.toList();
  final providers = Map<String, dynamic>.from(
    config['proxy-providers'] as Map? ?? {},
  );
  final providerNames = providers.keys.toList()..sort();
  for (final providerName in providerNames) {
    final provider = Map<String, dynamic>.from(providers[providerName] as Map);
    final health = Map<String, dynamic>.from(
      provider['health-check'] as Map? ?? {},
    );
    // The pinned core ignores registration when the URL equals a provider's
    // disabled primary check. Enabling that check closes the provider-only gap.
    health['enable'] = true;
    // Make this the primary check so earlier permissive subscription groups
    // cannot register the same URL first and override the strict 204 contract.
    health['url'] = harmonyAutomaticTestUrl;
    health['expected-status'] = '204';
    health['interval'] = harmonyAutomaticInterval;
    health['timeout'] = 5000;
    health['lazy'] = false;
    provider['health-check'] = health;
    providers[providerName] = provider;
  }
  if (providers.isNotEmpty) config['proxy-providers'] = providers;
  final groups = _groups(config)
      .where((group) => group[_managedMarker] != _managedVersion)
      .toList();
  for (final group in groups) {
    // Native recovery discovers ownership by this reserved icon. Imported
    // groups must not impersonate the regenerated group's identity.
    if (group['icon'] == harmonyAutomaticGroupIcon) group.remove('icon');
  }
  groups.add({
    'name': name,
    'type': 'url-test',
    _managedMarker: _managedVersion,
    'icon': harmonyAutomaticGroupIcon,
    'hidden': true,
    // An empty explicit list without `use` is rejected by the core parser.
    // REJECT is filtered out below, then reinstated as the safe empty fallback.
    'proxies': nodes.isEmpty && providerNames.isEmpty ? ['REJECT'] : nodes,
    if (providerNames.isNotEmpty) 'use': providerNames,
    'url': harmonyAutomaticTestUrl,
    'expected-status': '204',
    'interval': harmonyAutomaticInterval,
    'timeout': 5000,
    'tolerance': harmonyAutomaticTolerance,
    'lazy': false,
    'max-failed-times': 2,
    'exclude-type': _excludedAutomaticTypes,
    'empty-fallback': 'REJECT',
  });
  config['proxy-groups'] = groups;
  config['rules'] = defaultRoutingRules(config);
  applyDefaultDns(config);
  return name;
}

const _lanRules = [
  'GEOSITE,private,DIRECT',
  'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
  'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
  'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
  'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
  'IP-CIDR,169.254.0.0/16,DIRECT,no-resolve',
  'IP-CIDR,224.0.0.0/4,DIRECT,no-resolve',
  'IP-CIDR,255.255.255.255/32,DIRECT,no-resolve',
  'IP-CIDR6,::1/128,DIRECT,no-resolve',
  'IP-CIDR6,fc00::/7,DIRECT,no-resolve',
  'IP-CIDR6,fe80::/10,DIRECT,no-resolve',
  'IP-CIDR6,ff00::/8,DIRECT,no-resolve',
];
const _domesticRules = ['GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT'];

// Split only outside logical rule expressions, preserving their payload.
List<String> _ruleParts(String rule) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var index = 0; index < rule.length; index++) {
    if (rule[index] == '(') depth++;
    if (rule[index] == ')') depth--;
    if (rule[index] == ',' && depth == 0) {
      parts.add(rule.substring(start, index).trim());
      start = index + 1;
    }
  }
  parts.add(rule.substring(start).trim());
  return parts;
}

bool _isCatchAll(List<String> parts) =>
    parts.isNotEmpty && const {'MATCH', 'FINAL'}.contains(parts.first.toUpperCase());

/// LAN protection, subscription exceptions, domestic defaults, then automatic
/// overseas fallback. The first original catch-all terminates the subscription;
/// unreachable rules after it are not accidentally activated.
List<String> defaultRoutingRules(Map<String, dynamic> config) {
  final target = effectiveHarmonyAutoGroupName(config);
  final original = (config['rules'] as List? ?? []).cast<String>();
  String? originalTarget;
  for (final rule in original) {
    final parts = _ruleParts(rule);
    if (_isCatchAll(parts) && parts.length > 1) {
      originalTarget = parts[1];
      break;
    }
  }
  final groupNames = _groups(config).map((group) => group['name']).toSet();
  final exceptions = <String>[];
  final generalRules = <String>[];
  final domesticTypes = <String>{};
  for (final rule in original) {
    final parts = _ruleParts(rule);
    if (_isCatchAll(parts)) break;
    if (_lanRules.contains(rule)) continue;
    if (parts.length >= 3) {
      final type = parts[0].toUpperCase();
      final payload = parts[1].toLowerCase();
      if ((type == 'GEOSITE' || type == 'GEOIP') && payload == 'cn') {
        // Explicit domestic routing belongs to the subscription. Keep its
        // original target, flags and precedence, even if it names the old
        // catch-all group; only missing domestic policies receive our defaults.
        domesticTypes.add(type);
        exceptions.add(rule);
        continue;
      }
      final broadOverseas =
          (type == 'GEOSITE' && payload == 'geolocation-!cn') ||
          (type == 'GEOIP' && payload == '!cn') ||
          (type == 'IP-CIDR' && payload == '0.0.0.0/0') ||
          (type == 'IP-CIDR6' && payload == '::/0');
      if (type != 'SUB-RULE' &&
          ((parts[2] == originalTarget && groupNames.contains(originalTarget)) ||
              (broadOverseas && !const {
                'REJECT', 'REJECT-DROP',
              }.contains(parts[2].toUpperCase())))) {
        parts[2] = target;
        (broadOverseas ? generalRules : exceptions).add(parts.join(','));
        continue;
      }
      if (broadOverseas) {
        generalRules.add(rule);
        continue;
      }
    }
    exceptions.add(rule);
  }
  return [
    ..._lanRules,
    ...exceptions,
    for (final rule in _domesticRules)
      if (!domesticTypes.contains(rule.split(',').first)) rule,
    ...generalRules,
    'MATCH,$target',
    // Mihomo skips a matched adapter that cannot carry UDP. Never let an
    // unsupported overseas datagram fall through to the core's default DIRECT.
    'MATCH,REJECT',
  ];
}

/// Kept for callers of the previous helper. Safety is achieved by isolating the
/// app-managed group, without destructively changing subscription service groups.
void excludeDirectFromAutomaticGroups(Map<String, dynamic> config) {
  applyHarmonyAutomaticRouting(config);
}

void applyDefaultDns(Map<String, dynamic> config) {
  final dns = Map<String, dynamic>.from(config['dns'] as Map? ?? {});
  const directDns = [
    'https://dns.alidns.com/dns-query',
    'https://doh.pub/dns-query',
  ];
  final policy = Map<String, dynamic>.from(dns['nameserver-policy'] as Map? ?? {});
  // Subscription split-DNS, including its own domestic/private resolvers, wins.
  policy.putIfAbsent('geosite:private', () => ['system://']);
  policy.putIfAbsent('geosite:cn', () => directDns);
  dns['nameserver-policy'] = policy;
  dns.putIfAbsent('direct-nameserver', () => ['system://', ...directDns]);
  dns.putIfAbsent('direct-nameserver-follow-policy', () => true);
  if ((dns['fake-ip-filter-mode'] ?? 'blacklist') == 'blacklist') {
    dns['fake-ip-filter'] = {
      ...(dns['fake-ip-filter'] as List? ?? []).cast<String>(),
      'geosite:private',
      'geosite:cn',
    }.toList();
  }
  config['dns'] = dns;
}
