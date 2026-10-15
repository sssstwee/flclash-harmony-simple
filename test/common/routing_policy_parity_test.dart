import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/generated/routing_policy.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated policy is identical to the public source manifest', () {
    expect(
      routingPolicy,
      jsonDecode(File('backend/routing-policy.json').readAsStringSync()),
    );
  });

  test(
    'client and publisher produce identical rules, groups and DNS',
    () async {
      final source = <String, dynamic>{
        'proxies': [
          {'name': 'voyra-warp', 'type': 'vless'},
          {'name': 'voyra-hy2-direct', 'type': 'hysteria2'},
          {'name': 'Other', 'type': 'ss'},
          {'name': 'Local', 'type': 'direct'},
        ],
        'proxy-groups': [
          {
            'name': 'Main',
            'type': 'select',
            'proxies': ['Nested', 'Local', 'DIRECT'],
          },
          {
            'name': 'Nested',
            'type': 'select',
            'proxies': ['Other', 'DIRECT'],
          },
          {
            'name': 'AI',
            'type': 'select',
            'proxies': ['Main', 'DIRECT'],
          },
        ],
        'rules': [
          'DOMAIN-SUFFIX,qq.com,Main',
          'DOMAIN-SUFFIX,new-ai.example,AI',
          'MATCH,Main',
        ],
        'dns': {
          'nameserver-policy': {
            '+.claude.com': 'https://1.1.1.1/dns-query#Main',
            '+.corp.test': ['192.168.1.1'],
          },
        },
      };
      final client = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
      final rules = defaultRoutingRules(client);
      applyDefaultDns(client);
      client['rules'] = rules;
      final process = await Process.start('node', [
        '--input-type=module',
        '-e',
        '''
      import { applyRoutingPolicy } from './backend/src/routing_policy.mjs';
      let input = ''; for await (const chunk of process.stdin) input += chunk;
      process.stdout.write(JSON.stringify(applyRoutingPolicy(JSON.parse(input))));
    ''',
      ]);
      process.stdin.write(jsonEncode(source));
      await process.stdin.close();
      final output = await utf8.decoder.bind(process.stdout).join();
      final errors = await utf8.decoder.bind(process.stderr).join();
      expect(await process.exitCode, 0, reason: errors);
      final publisher = jsonDecode(output) as Map;
      for (final key in ['rules', 'proxy-groups', 'dns']) {
        expect(client[key], publisher[key], reason: key);
      }
    },
  );
}
