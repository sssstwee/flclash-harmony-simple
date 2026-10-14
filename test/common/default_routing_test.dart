import 'dart:convert';

import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> subscription({String catchAll = 'MATCH,Main'}) => {
  'proxies': [
    {'name': 'Node', 'type': 'ss'},
  ],
  'proxy-groups': <Map<String, dynamic>>[
    {'name': 'Ads', 'type': 'select', 'proxies': ['REJECT', 'DIRECT']},
    {'name': 'Main', 'type': 'select', 'proxies': ['Node', 'DIRECT']},
    {'name': 'Video', 'type': 'select', 'proxies': ['Node']},
  ],
  'rules': [
    'DOMAIN-SUFFIX,work.example,Main',
    'DOMAIN,intranet.example,DIRECT',
    'DOMAIN-SUFFIX,video.example,Video',
    'RULE-SET,Company,Video',
    catchAll,
  ],
  'rule-providers': {
    'Company': {'type': 'http', 'behavior': 'domain', 'url': 'https://example.com/rules'},
  },
};

Map managed(Map<String, dynamic> config) => (config['proxy-groups'] as List)
    .cast<Map>()
    .singleWhere((group) => group['icon'] == harmonyAutomaticGroupIcon);

MakeRealProfileState profileState(Map<String, dynamic> config, {bool overrideDns = false, Mode mode = Mode.rule}) =>
    MakeRealProfileState(
      profilesPath: '/tmp/clash-harmony-test',
      profileId: 1,
      rawConfig: config,
      realPatchConfig: PatchClashConfig(mode: mode),
      overrideDns: overrideDns,
      appendSystemDns: false,
      proxyGroups: [],
      rules: [],
      addedRules: [Rule.parse('DOMAIN,old-custom.example,DIRECT')],
      defaultUA: 'Clash Harmony/test',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('selector-only subscriptions get continuous proxy-only core failover', () {
    final config = subscription();
    final originalGroups = jsonEncode(config['proxy-groups']);
    final name = effectiveHarmonyAutoGroupName(config);
    expect(applyHarmonyAutomaticRouting(config), name);
    final automatic = managed(config);
    expect(automatic['type'], 'url-test');
    expect(automatic['proxies'], ['Node']);
    expect(automatic['interval'], harmonyAutomaticInterval);
    expect(automatic['tolerance'], harmonyAutomaticTolerance);
    expect(automatic['timeout'], 5000);
    expect(automatic['lazy'], false);
    expect(automatic['url'], harmonyAutomaticTestUrl);
    expect(automatic['expected-status'], '204');
    expect(automatic['empty-fallback'], 'REJECT');
    expect(automatic['hidden'], true);
    expect(jsonEncode((config['proxy-groups'] as List).take(3).toList()), originalGroups);
    expect((config['rules'] as List).reversed.take(2).toList(), ['MATCH,REJECT', 'MATCH,$name']);
  });

  test('keeps LAN/domestic defaults and explicit subscription exceptions', () {
    final config = subscription();
    final before = jsonEncode(config);
    final rules = defaultRoutingRules(config);
    final name = effectiveHarmonyAutoGroupName(config);
    expect(rules.first, 'GEOSITE,private,DIRECT');
    expect(rules, contains('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'));
    expect(rules, contains('IP-CIDR6,fc00::/7,DIRECT,no-resolve'));
    expect(rules, contains('GEOSITE,cn,DIRECT'));
    expect(rules, contains('GEOIP,CN,DIRECT'));
    expect(rules, contains('DOMAIN-SUFFIX,work.example,$name'));
    expect(rules, contains('DOMAIN,intranet.example,DIRECT'));
    expect(rules, contains('DOMAIN-SUFFIX,video.example,Video'));
    expect(rules, contains('RULE-SET,Company,Video'));
    expect(rules.indexOf('DOMAIN,intranet.example,DIRECT'), lessThan(rules.indexOf('GEOSITE,cn,DIRECT')));
    expect(jsonEncode(config), before);
    applyHarmonyAutomaticRouting(config);
    expect(config['rule-providers']['Company']['behavior'], 'domain');
  });

  test('never inherits direct catch-all or activates rules after first catch-all', () {
    for (final target in ['DIRECT', 'COMPATIBLE', 'REJECT', 'Missing', 'Main']) {
      final config = subscription(catchAll: 'FINAL,$target');
      (config['rules'] as List).addAll(['DOMAIN,unreachable.example,DIRECT', 'MATCH,Video']);
      final rules = defaultRoutingRules(config);
      expect(rules.reversed.take(2).toList(), ['MATCH,REJECT', 'MATCH,${effectiveHarmonyAutoGroupName(config)}']);
      expect(rules, isNot(contains('DOMAIN,unreachable.example,DIRECT')));
      expect(rules.where((rule) => rule.startsWith('MATCH,')).length, 2);
    }
  });

  test('broad foreign direct rules use automatic while specific direct stays', () {
    final config = subscription();
    config['rules'] = [
      'DOMAIN,foreign-exception.example,DIRECT',
      'GEOSITE,geolocation-!cn,DIRECT',
      'GEOIP,!CN,Main',
      'IP-CIDR,0.0.0.0/0,COMPATIBLE',
      'MATCH,DIRECT',
    ];
    final name = effectiveHarmonyAutoGroupName(config);
    final rules = defaultRoutingRules(config);
    expect(rules, contains('DOMAIN,foreign-exception.example,DIRECT'));
    expect(rules, contains('GEOSITE,geolocation-!cn,$name'));
    expect(rules, contains('GEOIP,!CN,$name'));
    expect(rules, contains('IP-CIDR,0.0.0.0/0,$name'));
    expect(rules.indexOf('GEOSITE,cn,DIRECT'), lessThan(rules.indexOf('IP-CIDR,0.0.0.0/0,$name')));
  });

  test('explicit domestic routing preserves targets, flags and precedence', () {
    final config = subscription();
    config['rules'] = [
      'GEOIP,CN,Main,no-resolve',
      'GEOSITE,cn,Main',
      'DOMAIN,cn-service.example,Video',
      'MATCH,Main',
    ];
    applyHarmonyAutomaticRouting(config);
    final rules = (config['rules'] as List).cast<String>();
    final name = effectiveHarmonyAutoGroupName(config);
    expect(rules, contains('GEOIP,CN,Main,no-resolve'));
    expect(rules, contains('GEOSITE,cn,Main'));
    expect(rules, contains('DOMAIN,cn-service.example,Video'));
    expect(rules.indexOf('GEOIP,CN,Main,no-resolve'), lessThan(rules.indexOf('DOMAIN,cn-service.example,Video')));
    expect(rules, isNot(contains('GEOIP,CN,$name,no-resolve')));
    expect(rules, isNot(contains('GEOSITE,cn,$name')));
    expect(rules, isNot(contains('GEOSITE,cn,DIRECT')));
    expect(rules, isNot(contains('GEOIP,CN,DIRECT')));
    final once = jsonEncode(config);
    applyHarmonyAutomaticRouting(config);
    expect(jsonEncode(config), once);
  });

  test('missing domestic policy is filled without changing supplied CN tokens', () {
    final config = subscription();
    config['rules'] = [' geoip , cn , Main , no-resolve ', 'MATCH,Main'];
    final rules = defaultRoutingRules(config);
    expect(rules, contains(' geoip , cn , Main , no-resolve '));
    expect(rules, contains('GEOSITE,cn,DIRECT'));
    expect(rules, isNot(contains('GEOIP,CN,DIRECT')));
  });

  test('logical rule payload and parameters survive catch-all retargeting', () {
    final config = subscription();
    config['rules'] = [
      'AND,((DOMAIN,work.example),(NETWORK,TCP)),Main',
      'IP-CIDR,203.0.113.0/24,Main,no-resolve',
      'SUB-RULE,(NETWORK,UDP),Main',
      'MATCH,Main',
    ];
    final name = effectiveHarmonyAutoGroupName(config);
    final rules = defaultRoutingRules(config);
    expect(rules, contains('AND,((DOMAIN,work.example),(NETWORK,TCP)),$name'));
    expect(rules, contains('IP-CIDR,203.0.113.0/24,$name,no-resolve'));
    expect(rules, contains('SUB-RULE,(NETWORK,UDP),Main'));
  });

  test('nested selector/automatic, cycles and include-all cannot escape managed pool', () {
    final config = subscription();
    (config['proxies'] as List).addAll([
      {'name': 'Local', 'type': 'direct'},
      {'name': 'Compat', 'type': 'compatible'},
      {'name': 'Unrecognized', 'type': 'future-adapter'},
    ]);
    (config['proxy-groups'] as List).addAll([
      {'name': 'Outer', 'type': 'url-test', 'proxies': ['Main', 'DIRECT'], 'include-all': true},
      {'name': 'Cycle', 'type': 'fallback', 'proxies': ['Cycle', 'COMPATIBLE']},
    ]);
    config['rules'] = ['MATCH,Outer'];
    applyHarmonyAutomaticRouting(config);
    final automatic = managed(config);
    expect(automatic['proxies'], ['Node']);
    expect(automatic.containsKey('include-all'), false);
    for (final type in ['Direct', 'Compatible', 'Reject', 'Pass', 'Selector', 'URLTest', 'Fallback']) {
      expect((automatic['exclude-type'] as String).split('|'), contains(type));
    }
    expect(automatic['empty-fallback'], 'REJECT');
  });

  test('provider-only subscriptions schedule bounded strict checks and reject emptiness', () {
    final config = <String, dynamic>{
      'proxy-providers': {
        'Airport': {
          'type': 'http',
          'url': 'https://example.com/sub',
          'interval': 86400,
          'health-check': {
            'enable': false,
            'url': harmonyAutomaticTestUrl,
            'interval': 0,
            'expected-status': '*',
            'lazy': true,
          },
        },
      },
      'proxy-groups': [
        {'name': 'FromProvider', 'type': 'select', 'include-all-providers': true},
      ],
      'rules': ['MATCH,FromProvider'],
    };
    applyHarmonyAutomaticRouting(config);
    final automatic = managed(config);
    expect(automatic['proxies'], isEmpty);
    expect(automatic['use'], ['Airport']);
    expect(automatic['empty-fallback'], 'REJECT');
    final provider = config['proxy-providers']['Airport'];
    expect(provider['url'], 'https://example.com/sub');
    expect(provider['interval'], 86400);
    expect(provider['health-check'], {
      'enable': true,
      'url': harmonyAutomaticTestUrl,
      'interval': harmonyAutomaticInterval,
      'expected-status': '204',
      'lazy': false,
      'timeout': 5000,
    });
  });

  test('no available real nodes produces a parser-valid REJECT fallback', () {
    final config = <String, dynamic>{
      'proxies': [{'name': 'Local', 'type': 'direct'}],
      'rules': ['MATCH,DIRECT'],
    };
    applyHarmonyAutomaticRouting(config);
    expect(managed(config)['proxies'], ['REJECT']);
    expect(managed(config)['empty-fallback'], 'REJECT');
    expect((config['rules'] as List).reversed.take(2).toList(), ['MATCH,REJECT', 'MATCH,${managed(config)['name']}']);
  });

  test('unsupported overseas UDP reaches REJECT while supported routes stay first', () {
    final config = subscription();
    (config['proxies'] as List).add({'name': 'TCP-only', 'type': 'http'});
    applyHarmonyAutomaticRouting(config);
    final rules = (config['rules'] as List).cast<String>();
    final name = effectiveHarmonyAutoGroupName(config);
    // Pinned tunnel.match skips an unsupported-UDP MATCH and continues.
    String catchAll({required bool udp, required bool supportsUdp}) {
      for (final rule in rules.where((rule) => rule.startsWith('MATCH,'))) {
        final target = rule.substring('MATCH,'.length);
        if (target == name && udp && !supportsUdp) continue;
        return target;
      }
      return 'DIRECT';
    }
    expect(catchAll(udp: true, supportsUdp: false), 'REJECT');
    expect(catchAll(udp: true, supportsUdp: true), name);
    expect(catchAll(udp: false, supportsUdp: false), name);
    expect(rules.indexOf('GEOIP,CN,DIRECT'), lessThan(rules.indexOf('MATCH,$name')));
    expect(rules.indexOf('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'), lessThan(rules.indexOf('MATCH,$name')));
  });

  test('imported matching attributes cannot duplicate the reserved native identity', () {
    final config = subscription();
    final imported = <String, dynamic>{
      'name': 'Harmony Auto',
      'type': 'url-test',
      'icon': harmonyAutomaticGroupIcon,
      'proxies': ['Node'],
      'url': harmonyAutomaticTestUrl,
      'expected-status': '204',
      'empty-fallback': 'REJECT',
      'interval': 9999,
      'hidden': false,
    };
    (config['proxy-groups'] as List).add(imported);
    (config['proxy-groups'] as List)[0]['icon'] = 'https://example.com/ads.png';
    final name = effectiveHarmonyAutoGroupName(config);
    expect(name, 'Harmony Auto 2');
    applyHarmonyAutomaticRouting(config);
    final groups = (config['proxy-groups'] as List).cast<Map>();
    expect(groups.where((group) => group['icon'] == harmonyAutomaticGroupIcon), hasLength(1));
    expect(managed(config)['name'], name);
    final preserved = groups.singleWhere((group) => group['name'] == imported['name']);
    final expected = Map<String, dynamic>.from(imported)..remove('icon');
    expect(preserved, expected);
    expect(groups.first['icon'], 'https://example.com/ads.png');
    expect(imported['icon'], harmonyAutomaticGroupIcon);
    final once = jsonEncode(config);
    applyHarmonyAutomaticRouting(config);
    expect(jsonEncode(config), once);
    expect((config['proxy-groups'] as List).cast<Map>().where((group) => group['icon'] == harmonyAutomaticGroupIcon), hasLength(1));
  });

  test('generated naming avoids all collisions and is idempotent', () {
    final config = subscription();
    (config['proxy-groups'] as List).add({'name': 'Harmony Auto', 'type': 'select', 'proxies': ['Node']});
    (config['proxies'] as List).add({'name': 'Harmony Auto 2', 'type': 'trojan'});
    config['proxy-providers'] = {'Harmony Auto 3': {'type': 'inline', 'payload': []}};
    expect(effectiveHarmonyAutoGroupName(config), 'Harmony Auto 4');
    applyHarmonyAutomaticRouting(config);
    final once = jsonEncode(config);
    expect(effectiveHarmonyAutoGroupName(config), 'Harmony Auto 4');
    applyHarmonyAutomaticRouting(config);
    expect(jsonEncode(config), once);
  });

  test('preserves explicit private/domestic and proxy-server DNS policies', () {
    final config = <String, dynamic>{
      'dns': {
        'nameserver-policy': {
          '+.corp.example': ['192.168.2.1'],
          'geosite:private': ['192.168.2.1'],
          'geosite:cn': ['https://custom.example/dns-query'],
        },
        'proxy-server-nameserver-policy': {'+.proxy.example': ['1.1.1.1']},
        'direct-nameserver': ['192.168.2.1'],
        'direct-nameserver-follow-policy': false,
        'fake-ip-filter': ['*.lan'],
      },
    };
    applyDefaultDns(config);
    final once = jsonEncode(config);
    applyDefaultDns(config);
    expect(jsonEncode(config), once);
    final dns = config['dns'] as Map;
    expect(dns['nameserver-policy']['geosite:private'], ['192.168.2.1']);
    expect(dns['nameserver-policy']['geosite:cn'], ['https://custom.example/dns-query']);
    expect(dns['proxy-server-nameserver-policy']['+.proxy.example'], ['1.1.1.1']);
    expect(dns['direct-nameserver'], ['192.168.2.1']);
    expect(dns['direct-nameserver-follow-policy'], false);
    expect(dns['fake-ip-filter'], ['*.lan', 'geosite:private', 'geosite:cn']);
  });

  test('missing DNS receives direct/private defaults without changing filter syntax', () {
    final config = <String, dynamic>{};
    applyDefaultDns(config);
    expect(config['dns']['nameserver-policy']['geosite:private'], ['system://']);
    expect(config['dns']['nameserver-policy']['geosite:cn'], contains('https://doh.pub/dns-query'));
    for (final mode in ['rule', 'whitelist']) {
      final config = <String, dynamic>{'dns': {'fake-ip-filter-mode': mode, 'fake-ip-filter': ['Original']}};
      applyDefaultDns(config);
      expect(config['dns']['fake-ip-filter'], ['Original']);
    }
  });

  test('profile generation installs managed routing without changing other platforms', () async {
    final config = subscription(catchAll: 'MATCH,DIRECT');
    final before = jsonEncode(config);
    final state = profileState(config);
    final result = await makeRealProfileTask(state, isOhos: true);
    final yaml = loadYaml(result.a) as Map;
    final rules = yaml['rules'] as List;
    expect(rules.first, 'GEOSITE,private,DIRECT');
    expect(rules, contains('DOMAIN,intranet.example,DIRECT'));
    expect(rules, contains('RULE-SET,Company,Video'));
    expect(rules, isNot(contains('DOMAIN,old-custom.example,DIRECT')));
    expect(rules.reversed.take(2).toList(), ['MATCH,REJECT', 'MATCH,${effectiveHarmonyAutoGroupName(config)}']);
    expect(yaml['proxy-groups'].last['empty-fallback'], 'REJECT');
    final ordinary = await makeRealProfileTask(state, isOhos: false);
    final ordinaryYaml = loadYaml(ordinary.a) as Map;
    expect(ordinaryYaml['rules'], contains('MATCH,DIRECT'));
    expect(ordinaryYaml['rules'], contains('DOMAIN,old-custom.example,DIRECT'));
    expect((ordinaryYaml['proxy-groups'] as List).length, 3);
    expect(jsonEncode(config), before);
  });

  test('stale direct/global mode cannot bypass Harmony split routing', () async {
    for (final mode in [Mode.direct, Mode.global]) {
      final state = profileState(subscription(), mode: mode);
      final harmony = await makeRealProfileTask(state, isOhos: true);
      expect((loadYaml(harmony.a) as Map)['mode'], 'rule');
      final ordinary = await makeRealProfileTask(state, isOhos: false);
      expect((loadYaml(ordinary.a) as Map)['mode'], mode.name);
    }
  });

  test('DNS overrides cannot erase Harmony subscription resolver exceptions', () async {
    final config = subscription();
    config['dns'] = {
      'enable': true,
      'respect-rules': true,
      'nameserver': ['https://resolver.example/dns-query'],
      'default-nameserver': ['192.168.2.1'],
      'fallback': ['https://fallback.example/dns-query'],
      'fallback-filter': {'geoip': false, 'domain': ['+.foreign.example']},
      'use-hosts': false,
      'nameserver-policy': {'+.corp.example': ['192.168.2.1']},
      'proxy-server-nameserver': ['1.1.1.1'],
      'proxy-server-nameserver-policy': {'+.proxy.example': ['1.1.1.1']},
      'direct-nameserver': ['192.168.2.1'],
      'fake-ip-filter-mode': 'rule',
      'fake-ip-filter': ['DOMAIN,corp.example,real-ip', 'MATCH,fake-ip'],
    };
    final result = await makeRealProfileTask(profileState(config, overrideDns: true), isOhos: true);
    final dns = (loadYaml(result.a) as Map)['dns'] as Map;
    expect(dns['enable'], true);
    expect(dns['respect-rules'], true);
    expect(dns['nameserver'], ['https://resolver.example/dns-query']);
    expect(dns['default-nameserver'], ['192.168.2.1']);
    expect(dns['fallback'], ['https://fallback.example/dns-query']);
    expect(dns['fallback-filter'], {'geoip': false, 'domain': ['+.foreign.example']});
    expect(dns['use-hosts'], false);
    expect(dns['nameserver-policy']['+.corp.example'], ['192.168.2.1']);
    expect(dns['proxy-server-nameserver-policy']['+.proxy.example'], ['1.1.1.1']);
    expect(dns['proxy-server-nameserver'], ['1.1.1.1']);
    expect(dns['direct-nameserver'], ['192.168.2.1']);
    expect(dns['fake-ip-filter-mode'], 'rule');
    expect(dns['fake-ip-filter'], ['DOMAIN,corp.example,real-ip', 'MATCH,fake-ip']);
  });
}
