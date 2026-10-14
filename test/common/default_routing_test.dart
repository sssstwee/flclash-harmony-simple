import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> subscription({String catchAll = 'MATCH,Main'}) => {
  'proxies': [
    {'name': 'Node', 'type': 'ss'},
  ],
  'proxy-groups': <Map<String, dynamic>>[
    {
      'name': 'Ads',
      'type': 'select',
      'proxies': ['REJECT', 'DIRECT'],
    },
    {
      'name': 'Main',
      'type': 'select',
      'proxies': ['Node', 'DIRECT'],
    },
  ],
  'rules': [
    'DOMAIN-SUFFIX,qq.com,Main',
    'DOMAIN,www.google.com,DIRECT',
    catchAll,
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('routes AI geosite through a subscription AI group when present', () {
    final config = subscription();
    (config['proxy-groups'] as List<Map<String, dynamic>>).add({
      'name': '🤖AI服务',
      'type': 'fallback',
      'proxies': ['Node', 'DIRECT'],
    });
    final rules = defaultRoutingRules(config);
    expect(rules, contains('GEOSITE,category-ai-!cn,🤖AI服务'));
    expect(rules.last, 'MATCH,Main');
  });

  test('findAiServiceGroup does not treat Main as an AI group', () {
    final config = <String, dynamic>{
      'proxy-groups': [
        {
          'name': 'Main',
          'type': 'select',
          'proxies': ['Node'],
        },
      ],
      'proxies': [
        {'name': 'Node', 'type': 'vless'},
      ],
    };
    expect(findAiServiceGroup(config, (name) => name == 'Main'), isNull);
  });

  test('findAiServiceGroup prefers AI-labeled groups and warp members', () {
    final config = <String, dynamic>{
      'proxies': [
        {'name': 'HY2 WARP', 'type': 'hysteria2'},
        {'name': 'TCP Node', 'type': 'vless'},
      ],
      'proxy-groups': [
        {
          'name': 'Main',
          'type': 'select',
          'proxies': ['TCP Node', 'DIRECT'],
        },
        {
          'name': '🤖AI服务',
          'type': 'fallback',
          'proxies': ['HY2 WARP', 'TCP Node'],
        },
      ],
      'rules': ['MATCH,Main'],
    };
    bool hasProxy(String name) => name == 'Main' || name == '🤖AI服务';
    expect(findAiServiceGroup(config, hasProxy), '🤖AI服务');
  });

  test(
    'uses automatic domestic/LAN direct rules and an overseas catch-all',
    () {
      final config = subscription();
      final rules = defaultRoutingRules(config);
      expect(rules, contains('GEOSITE,cn,DIRECT'));
      expect(rules, contains('GEOIP,CN,DIRECT'));
      expect(rules, contains('IP-CIDR,192.168.0.0/16,DIRECT'));
      expect(rules, contains('IP-CIDR6,fc00::/7,DIRECT'));
      expect(rules.last, 'MATCH,Main');
      expect(rules, isNot(contains('DOMAIN-SUFFIX,qq.com,Main')));
      expect(rules, isNot(contains('DOMAIN,www.google.com,DIRECT')));
      expect(config['rules'], contains('DOMAIN,www.google.com,DIRECT'));
    },
  );

  test('falls back from DIRECT/REJECT catch-alls without selecting Ads', () {
    for (final target in ['DIRECT', 'REJECT', 'Ads', 'Missing']) {
      expect(
        defaultRoutingRules(subscription(catchAll: 'MATCH,$target')).last,
        'MATCH,Main',
      );
    }
    expect(
      defaultRoutingRules(subscription(catchAll: 'FINAL, Main')).last,
      'MATCH,Main',
    );
  });

  test('accepts provider groups before the provider nodes have loaded', () {
    final config = <String, dynamic>{
      'proxy-providers': {
        'Airport': {'type': 'http'},
      },
      'proxy-groups': [
        {
          'name': 'Auto',
          'type': 'url-test',
          'use': ['Airport'],
        },
      ],
      'rules': ['MATCH,DIRECT'],
    };
    expect(defaultRoutingRules(config).last, 'MATCH,Auto');
  });

  test(
    'automatic groups cannot select a direct route for overseas traffic',
    () {
      final config = subscription();
      (config['proxy-groups'] as List<Map<String, dynamic>>).add({
        'name': 'Auto',
        'type': 'url-test',
        'proxies': ['DIRECT', 'Node', 'REJECT'],
      });
      excludeDirectFromAutomaticGroups(config);
      final groups = config['proxy-groups'] as List;
      expect(groups.last['proxies'], ['Node']);
      expect(groups.first['proxies'], ['REJECT', 'DIRECT']);
      final directOnly = <String, dynamic>{
        'proxy-groups': [
          {
            'name': 'Unused',
            'type': 'url-test',
            'proxies': ['DIRECT'],
          },
        ],
      };
      excludeDirectFromAutomaticGroups(directOnly);
      expect(directOnly['proxy-groups'][0]['proxies'], ['DIRECT']);
    },
  );

  test('ignores cycles, relay and hidden groups during fallback', () {
    final config = subscription(catchAll: 'MATCH,DIRECT');
    (config['proxy-groups'] as List<Map<String, dynamic>>).insertAll(
      0,
      <Map<String, dynamic>>[
        {
          'name': 'Cycle',
          'type': 'select',
          'proxies': ['Cycle'],
        },
        {
          'name': 'Relay',
          'type': 'relay',
          'proxies': ['Node'],
        },
        {
          'name': 'Hidden',
          'type': 'select',
          'hidden': true,
          'proxies': ['Node'],
        },
      ],
    );
    expect(defaultRoutingRules(config).last, 'MATCH,Main');
    expect(() => defaultRoutingRules({}), throwsStateError);
  });

  test(
    'keeps unrelated DNS policies and adds direct/private DNS idempotently',
    () {
      final config = <String, dynamic>{
        'dns': {
          'nameserver-policy': {
            '+.corp.example': ['192.168.2.1'],
          },
          'fake-ip-filter': ['*.lan'],
        },
      };
      applyDefaultDns(config);
      applyDefaultDns(config);
      final dns = config['dns'] as Map;
      expect(dns['nameserver-policy']['+.corp.example'], ['192.168.2.1']);
      expect(dns['nameserver-policy']['geosite:private'], ['system://']);
      expect(
        dns['nameserver-policy']['geosite:cn'],
        contains('https://doh.pub/dns-query'),
      );
      expect(dns['fake-ip-filter'], containsAll(['*.lan', 'geosite:private', 'geosite:cn']));
      expect(dns['respect-rules'], isTrue);
      expect(
        dns['fake-ip-filter'],
        contains('connectivitycheck.platform.hicloud.com'),
      );
    },
  );

  test('retains rule and whitelist fake-IP filter syntax', () {
    for (final mode in ['rule', 'whitelist']) {
      final config = <String, dynamic>{
        'dns': {
          'fake-ip-filter-mode': mode,
          'fake-ip-filter': ['Original'],
        },
      };
      applyDefaultDns(config);
      expect(config['dns']['fake-ip-filter'], ['Original']);
    }
  });

  test(
    'generates split routing for existing profiles without stored edits',
    () async {
      final config = subscription(catchAll: 'MATCH,DIRECT');
      final state = MakeRealProfileState(
        profilesPath: '/tmp/clash-harmony-test',
        profileId: 1,
        rawConfig: config,
        realPatchConfig: const PatchClashConfig(),
        overrideDns: false,
        appendSystemDns: false,
        proxyGroups: [],
        rules: [],
        addedRules: [Rule.parse('DOMAIN,special.example,DIRECT')],
        defaultUA: 'Clash Harmony/test',
      );
      final result = await makeRealProfileTask(state, isOhos: true);
      final yaml = loadYaml(result.a) as Map;
      final rules = yaml['rules'] as List;
      expect(rules.first, 'GEOSITE,private,DIRECT');
      expect(rules, isNot(contains('DOMAIN,special.example,DIRECT')));
      expect(rules, contains('GEOSITE,cn,DIRECT'));
      expect(rules.last, 'MATCH,Main');
      expect(yaml['dns']['nameserver-policy']['geosite:private'], [
        'system://',
      ]);

      final ordinary = await makeRealProfileTask(state, isOhos: false);
      expect((loadYaml(ordinary.a) as Map)['rules'], contains('MATCH,DIRECT'));
      expect(config['rules'], contains('MATCH,DIRECT'));
    },
  );

  test(
    'ignores old custom rules on HarmonyOS and preserves other platforms',
    () async {
      final state = MakeRealProfileState(
        profilesPath: '/tmp/clash-harmony-test',
        profileId: 1,
        rawConfig: subscription(),
        realPatchConfig: const PatchClashConfig(),
        overrideDns: false,
        appendSystemDns: false,
        proxyGroups: [],
        rules: [Rule.parse('DOMAIN,custom.example,DIRECT')],
        addedRules: [],
        defaultUA: 'Clash Harmony/test',
      );
      final result = await makeRealProfileTask(state, isOhos: true);
      final rules = (loadYaml(result.a) as Map)['rules'] as List;
      expect(rules, contains('GEOSITE,cn,DIRECT'));
      expect(rules.last, 'MATCH,Main');
      expect(rules, isNot(contains('DOMAIN,custom.example,DIRECT')));
      final ordinary = await makeRealProfileTask(state, isOhos: false);
      expect((loadYaml(ordinary.a) as Map)['rules'], [
        'DOMAIN,custom.example,DIRECT',
      ]);
    },
  );
}
