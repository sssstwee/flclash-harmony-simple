import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parse, stringify } from 'yaml';
import { applyRoutingPolicy, normalizeRoutingContent, routingPolicy } from '../../src/routing_policy.mjs';

const fixture = () => ({
  proxies: [
    { name: 'voyra-warp', type: 'vless' },
    { name: 'voyra-hy2-direct', type: 'hysteria2' },
    { name: 'voyra-direct', type: 'vless' },
    { name: 'voyra-anytls-direct', type: 'anytls' },
    { name: 'voyra-hy2-warp', type: 'hysteria2' },
    { name: 'local', type: 'direct' },
  ],
  'proxy-groups': [
    { name: 'Main', type: 'select', proxies: ['Child', 'DIRECT', 'local'] },
    { name: 'Child', type: 'select', proxies: ['DIRECT', 'voyra-warp'] },
    { name: 'AI', type: 'select', proxies: ['DIRECT', 'Main'] },
  ],
  rules: ['DOMAIN-SUFFIX,future-ai.example,AI', 'DOMAIN-SUFFIX,qq.com,Main', 'MATCH,Main'],
  dns: { 'nameserver-policy': { '+.corp.test': ['192.168.1.1'], '+.claude.com': 'https://1.1.1.1/dns-query#Main' } },
});
const aiGroup = config => config['proxy-groups'].find(group => group.name === routingPolicy.aiGroup);

test('AI prioritizes approved native leaves then WARP, without selectors, providers or local exits', () => {
  const input = fixture();
  const output = applyRoutingPolicy(input);
  assert.deepEqual(aiGroup(output).proxies, [...routingPolicy.nativeProxies, ...routingPolicy.warpProxies]);
  assert.equal(aiGroup(output).type, 'fallback');
  assert.equal(aiGroup(output).url, 'https://api.openai.com/v1/models');
  assert.equal(aiGroup(output)['expected-status'], 401);
  assert.deepEqual(output['proxy-groups'].find(group => group.name === 'Child').proxies, ['voyra-warp']);
  assert.deepEqual(output['proxy-groups'].find(group => group.name === 'Main').proxies, ['Child']);
  assert.deepEqual(input['proxy-groups'][0].proxies, ['Child', 'DIRECT', 'local']);
});

test('WARP is allowed when native is absent; absence of both types rejects instead of using Main', () => {
  const config = fixture();
  config.proxies = [{ name: 'voyra-warp', type: 'vless' }, { name: 'unknown', type: 'ss' }];
  assert.deepEqual(aiGroup(applyRoutingPolicy(config)).proxies, ['voyra-warp']);
  config.proxies = [{ name: 'unknown', type: 'ss' }];
  config['proxy-groups'] = [{ name: 'Main', type: 'select', proxies: ['unknown'] }];
  const output = applyRoutingPolicy(config);
  assert.deepEqual(aiGroup(output).proxies, ['REJECT']);
  assert.ok(output.rules.includes(`DOMAIN-SUFFIX,claude.com,${routingPolicy.aiGroup}`));
});

test('a trusted name cannot disguise a local exit or a chained proxy', () => {
  const config = fixture();
  config.proxies = [
    { name: 'voyra-direct', type: 'direct' },
    { name: 'voyra-anytls-direct', type: 'anytls', 'dialer-proxy': 'voyra-warp' },
    { name: 'unknown', type: 'ss' },
  ];
  config['proxy-groups'] = [{ name: 'Main', type: 'select', proxies: ['unknown'] }];
  assert.deepEqual(aiGroup(applyRoutingPolicy(config)).proxies, ['REJECT']);
});

test('private and domestic AI stay direct, while AI and development rules precede the China IP rule', () => {
  const output = applyRoutingPolicy(fixture());
  const beforeCnIp = rule => assert.ok(output.rules.indexOf(rule) < output.rules.indexOf('GEOIP,CN,DIRECT'));
  for (const domain of ['deepseek.com', 'kimi.com', 'doubao.com', 'qianwen.com']) assert.ok(output.rules.includes(`DOMAIN-SUFFIX,${domain},DIRECT`));
  assert.ok(output.rules.includes('IP-CIDR,100.64.0.0/10,DIRECT'));
  for (const domain of ['claude.com', 'githubcopilot.com', 'windsurf.com', 'codeium.com', 'replicate.com', 'cohere.com']) beforeCnIp(`DOMAIN-SUFFIX,${domain},${routingPolicy.aiGroup}`);
  for (const category of ['github', 'google', 'youtube']) beforeCnIp(`GEOSITE,${category},Main`);
  beforeCnIp('DOMAIN-SUFFIX,pypi.org,Main');
  assert.ok(output.rules.includes(`DOMAIN-SUFFIX,future-ai.example,${routingPolicy.aiGroup}`));
  assert.ok(output.rules.indexOf('GEOSITE,cn,DIRECT') < output.rules.indexOf('DOMAIN-SUFFIX,qq.com,Main'));
});

test('AI DNS follows its native-first group, domestic DNS is direct, and corporate DNS survives', () => {
  const output = applyRoutingPolicy(fixture());
  assert.equal(output.dns['nameserver-policy']['+.claude.com'], `https://1.1.1.1/dns-query#${routingPolicy.aiGroup}`);
  assert.deepEqual(output.dns['nameserver-policy']['+.deepseek.com'], ['https://dns.alidns.com/dns-query', 'https://doh.pub/dns-query']);
  assert.deepEqual(output.dns['nameserver-policy']['+.corp.test'], ['192.168.1.1']);
});

test('repeated sync is idempotent and legacy clients retain the full managed policy', () => {
  const once = normalizeRoutingContent(stringify(fixture()));
  assert.equal(normalizeRoutingContent(once), once);
  assert.deepEqual(parse(once)['harmony-runtime'], {});
  assert.deepEqual(applyRoutingPolicy(applyRoutingPolicy(fixture())), applyRoutingPolicy(fixture()));
});
