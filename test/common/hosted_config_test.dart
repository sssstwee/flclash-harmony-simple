import 'dart:convert';

import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> hostedConfig() => {
  'mode': 'rule',
  'tcp-concurrent': false,
  'unified-delay': false,
  'ipv6': true,
  'keep-alive-interval': 45,
  'hosts': {'office.internal': '192.168.8.2'},
  'proxies': [
    {'name': 'new-native', 'type': 'vless'},
    {'name': 'backup', 'type': 'anytls'},
  ],
  'proxy-groups': [
    {
      'name': 'Cloud AI',
      'type': 'fallback',
      'proxies': ['backup', 'new-native'],
      'url': 'https://ai.example.test/models',
      'expected-status': 401,
    },
    {
      'name': 'Cloud Main',
      'type': 'select',
      'proxies': ['new-native', 'backup'],
    },
  ],
  'dns': {
    'enable': true,
    'respect-rules': true,
    'nameserver': ['https://dns.example.test/dns-query#Cloud Main'],
    'nameserver-policy': {
      '+.new-ai.example': 'https://1.1.1.1/dns-query#Cloud AI',
      'geosite:private': ['system://'],
    },
    'fake-ip-filter': ['+.new-ai.example'],
  },
  'rules': [
    'GEOSITE,private,DIRECT',
    'DOMAIN-SUFFIX,new-ai.example,Cloud AI',
    'DOMAIN-SUFFIX,domestic.example,DIRECT',
    'MATCH,Cloud Main',
  ],
};

MakeRealProfileState stateFor(Map<String, dynamic> config) =>
    MakeRealProfileState(
      profilesPath: '/tmp/clash-harmony-test',
      profileId: 1,
      rawConfig: config,
      realPatchConfig: const PatchClashConfig(
        hosts: {'office.internal': '127.0.0.1'},
      ),
      overrideDns: true,
      appendSystemDns: true,
      proxyGroups: [
        const ProxyGroup(
          id: 1,
          name: 'Local group',
          type: GroupType.Selector,
          proxies: ['DIRECT'],
        ),
      ],
      rules: [Rule.parse('DOMAIN,local.example,DIRECT')],
      addedRules: [Rule.parse('DOMAIN,new-ai.example,DIRECT')],
      defaultUA: 'Clash Harmony/test',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final withRuntime in [false, true]) {
    test('preserves hosted policy with runtime marker $withRuntime', () async {
      final config = hostedConfig();
      if (withRuntime) config['harmony-runtime'] = <String, dynamic>{};
      final expected = jsonDecode(jsonEncode(config)) as Map;
      final result = await makeRealProfileTask(stateFor(config), isOhos: true);
      final actual = loadYaml(result.a) as Map;
      for (final key in [
        'rules',
        'proxy-groups',
        'proxies',
        'dns',
        'hosts',
        'mode',
        'tcp-concurrent',
        'unified-delay',
        'ipv6',
        'keep-alive-interval',
      ]) {
        expect(actual[key], expected[key], reason: 'Cloud field: $key');
      }
      expect(config, expected);
    });
  }

  test(
    'new cloud domains, group order and DNS apply without client policy',
    () async {
      final config = hostedConfig();
      config['rules'].insert(1, 'DOMAIN,brand-new.example,Cloud AI');
      config['proxy-groups'][0]['proxies'] = ['new-native', 'backup'];
      config['dns']['nameserver-policy']['+.brand-new.example'] =
          'https://8.8.8.8/dns-query#Cloud AI';
      final result = await makeRealProfileTask(stateFor(config), isOhos: true);
      final actual = loadYaml(result.a) as Map;
      expect(actual['rules'], config['rules']);
      expect(actual['proxy-groups'], config['proxy-groups']);
      expect(actual['dns'], config['dns']);
    },
  );

  test(
    'missing hosted rules fail instead of creating a direct fallback',
    () async {
      for (final rules in [null, <String>[]]) {
        final config = hostedConfig()..['rules'] = rules;
        await expectLater(
          makeRealProfileTask(stateFor(config), isOhos: true),
          throwsFormatException,
        );
      }
    },
  );

  test('desktop local overrides retain their existing behavior', () async {
    final result = await makeRealProfileTask(
      stateFor(hostedConfig()),
      isOhos: false,
    );
    final actual = loadYaml(result.a) as Map;
    expect(actual['rules'], ['DOMAIN,local.example,DIRECT']);
    expect(actual['proxy-groups'][0]['name'], 'Local group');
    expect(actual['hosts']['office.internal'], '127.0.0.1');
    expect(actual['dns']['nameserver'], contains('system://'));
  });
}
