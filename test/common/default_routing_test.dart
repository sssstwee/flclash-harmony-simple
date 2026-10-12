import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> subscription({String catchAll = 'MATCH,Main'}) => {
  'proxies': [
    {'name': 'Node', 'type': 'ss'},
  ],
  'proxy-groups': [
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
    'DOMAIN,foreign.example,DIRECT',
    catchAll,
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      expect(rules, isNot(contains('DOMAIN,foreign.example,DIRECT')));
      expect(config['rules'], contains('DOMAIN,foreign.example,DIRECT'));
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

  test('ignores cycles, relay and hidden groups during fallback', () {
    final config = subscription(catchAll: 'MATCH,DIRECT');
    (config['proxy-groups'] as List).insertAll(0, [
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
    ]);
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
      expect(dns['fake-ip-filter'], ['*.lan', 'geosite:private', 'geosite:cn']);
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
      final result = await makeRealProfileTask(state, useDefaultRouting: true);
      final yaml = loadYaml(result.a) as Map;
      final rules = yaml['rules'] as List;
      expect(rules.first, 'DOMAIN,special.example,DIRECT');
      expect(rules, contains('GEOSITE,cn,DIRECT'));
      expect(rules.last, 'MATCH,Main');
      expect(yaml['dns']['nameserver-policy']['geosite:private'], [
        'system://',
      ]);

      final ordinary = await makeRealProfileTask(
        state,
        useDefaultRouting: false,
      );
      expect((loadYaml(ordinary.a) as Map)['rules'], contains('MATCH,DIRECT'));
      expect(config['rules'], contains('MATCH,DIRECT'));
    },
  );

  test('keeps explicit custom overwrite rules', () async {
    final state = MakeRealProfileState(
      profilesPath: '/tmp/clash-harmony-test',
      profileId: 1,
      rawConfig: subscription(),
      realPatchConfig: const PatchClashConfig(),
      overrideDns: false,
      appendSystemDns: false,
      proxyGroups: [],
      rules: [Rule.parse('MATCH,DIRECT')],
      addedRules: [],
      defaultUA: 'Clash Harmony/test',
    );
    final result = await makeRealProfileTask(state, useDefaultRouting: true);
    expect((loadYaml(result.a) as Map)['rules'], ['MATCH,DIRECT']);
  });
}
