import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> subscription({String catchAll = 'MATCH,Main'}) => {
  'proxies': <Map<String, dynamic>>[
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
    expect(rules, contains('GEOSITE,category-ai-!cn,$aiRoutingGroupName'));
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

  test('findAiServiceGroup recognizes explicit AI labels', () {
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

  test('a WARP label alone does not establish an AI service group', () {
    final config = subscription();
    (config['proxy-groups'] as List).add({
      'name': 'Special',
      'type': 'select',
      'proxies': ['WARP'],
    });
    expect(findAiServiceGroup(config, (_) => true), isNull);
  });

  test(
    'AI prefers approved native leaves, then WARP, never local or arbitrary groups',
    () {
      final config = subscription();
      (config['proxies'] as List).addAll(<Map<String, dynamic>>[
        {'name': 'voyra-warp', 'type': 'vless'},
        {'name': 'voyra-hy2-direct', 'type': 'hysteria2'},
        {'name': 'voyra-direct', 'type': 'vless'},
        {'name': 'voyra-anytls-direct', 'type': 'anytls'},
        {'name': 'voyra-hy2-warp', 'type': 'hysteria2'},
      ]);
      final rules = defaultRoutingRules(config);
      final group = (config['proxy-groups'] as List).cast<Map>().firstWhere(
        (g) => g['name'] == aiRoutingGroupName,
      );
      expect(group['type'], 'fallback');
      expect(group['proxies'], [
        'voyra-direct',
        'voyra-anytls-direct',
        'voyra-hy2-direct',
        'voyra-warp',
        'voyra-hy2-warp',
      ]);
      expect(group['url'], 'https://api.openai.com/v1/models');
      expect(group['expected-status'], 401);
      expect(rules, contains('DOMAIN-SUFFIX,claude.com,$aiRoutingGroupName'));
      for (final prefix in [
        'GEOSITE,google',
        'GEOSITE,youtube',
        'GEOSITE,github',
        'DOMAIN-SUFFIX,pypi.org',
      ]) {
        expect(
          rules.indexOf('$prefix,Main'),
          lessThan(rules.indexOf('GEOIP,CN,DIRECT')),
        );
      }
    },
  );

  test(
    'unapproved or chained AI exits reject, while an approved WARP exit is allowed',
    () {
      final config = subscription();
      (config['proxies'] as List).addAll(<Map<String, dynamic>>[
        {'name': 'voyra-direct', 'type': 'direct'},
        {
          'name': 'voyra-anytls-direct',
          'type': 'anytls',
          'dialer-proxy': 'Node',
        },
      ]);
      defaultRoutingRules(config);
      Map ai() => (config['proxy-groups'] as List).cast<Map>().firstWhere(
        (g) => g['name'] == aiRoutingGroupName,
      );
      expect(ai()['proxies'], ['REJECT']);
      (config['proxies'] as List).add({'name': 'voyra-warp', 'type': 'vless'});
      defaultRoutingRules(config);
      expect(ai()['proxies'], ['voyra-warp']);
    },
  );

  test(
    'server AI supplements survive and nested direct-only groups cannot leak overseas requests',
    () {
      final config = subscription();
      (config['proxy-groups'] as List).addAll(<Map<String, dynamic>>[
        {
          'name': 'AI',
          'type': 'select',
          'proxies': ['DIRECT', 'Node'],
        },
        {
          'name': 'LocalOnly',
          'type': 'select',
          'proxies': ['DIRECT'],
        },
      ]);
      (config['proxy-groups'] as List).cast<Map>().firstWhere(
        (g) => g['name'] == 'Main',
      )['proxies'] = [
        'LocalOnly',
        'Node',
        'DIRECT',
      ];
      (config['rules'] as List).insert(0, 'DOMAIN-SUFFIX,future-ai.example,AI');
      final rules = defaultRoutingRules(config);
      expect(
        rules,
        contains('DOMAIN-SUFFIX,future-ai.example,$aiRoutingGroupName'),
      );
      expect(rules, contains('IP-CIDR,100.64.0.0/10,DIRECT'));
      expect(rules, contains('DOMAIN-SUFFIX,deepseek.com,DIRECT'));
      expect(rules, contains('DOMAIN-SUFFIX,kimi.com,DIRECT'));
      expect(
        (config['proxy-groups'] as List).cast<Map>().firstWhere(
          (g) => g['name'] == 'Main',
        )['proxies'],
        ['Node'],
      );
      applyDefaultDns(config);
      expect(
        config['dns']['nameserver-policy']['+.claude.com'],
        'https://1.1.1.1/dns-query#$aiRoutingGroupName',
      );
      expect(
        config['dns']['nameserver-policy']['+.deepseek.com'],
        contains('https://doh.pub/dns-query'),
      );
    },
  );

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
      expect(
        rules.indexOf('GEOSITE,cn,DIRECT'),
        lessThan(rules.indexOf('DOMAIN-SUFFIX,qq.com,Main')),
      );
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
      expect(
        dns['fake-ip-filter'],
        containsAll(['*.lan', 'geosite:private', 'geosite:cn']),
      );
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
    'versioned runtime configs cannot bypass AI and overseas routing guards',
    () async {
      final config = subscription(catchAll: 'MATCH,DIRECT');
      config['harmony-runtime'] = <String, dynamic>{};
      (config['proxies'] as List).add({'name': 'voyra-warp', 'type': 'vless'});
      (config['rules'] as List).insert(0, 'DOMAIN-SUFFIX,claude.com,DIRECT');
      final state = MakeRealProfileState(
        profilesPath: '/tmp/clash-harmony-test',
        profileId: 1,
        rawConfig: config,
        realPatchConfig: const PatchClashConfig(),
        overrideDns: false,
        appendSystemDns: false,
        proxyGroups: [],
        rules: [],
        addedRules: [],
        defaultUA: 'Clash Harmony/test',
      );
      final result = await makeRealProfileTask(state, isOhos: true);
      final yaml = loadYaml(result.a) as Map;
      expect(yaml['rules'].last, 'MATCH,Main');
      expect(
        yaml['rules'],
        contains('DOMAIN-SUFFIX,claude.com,$aiRoutingGroupName'),
      );
      final ai = (yaml['proxy-groups'] as List).cast<Map>().firstWhere(
        (group) => group['name'] == aiRoutingGroupName,
      );
      expect(ai['proxies'], ['voyra-warp']);
      expect(
        yaml['dns']['nameserver-policy']['+.claude.com'],
        'https://1.1.1.1/dns-query#$aiRoutingGroupName',
      );
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
