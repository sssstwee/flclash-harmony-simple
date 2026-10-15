import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parse, stringify } from 'yaml';
import { applyRoutingPolicy, normalizePushedAiContent, normalizeRoutingContent, routingPolicy } from '../../src/routing_policy.mjs';

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
    { name: routingPolicy.aiGroup, type: 'select', proxies: ['voyra-hy2-direct', 'voyra-warp', 'voyra-direct'] },
    { name: 'AI', type: 'select', proxies: ['voyra-anytls-direct', 'voyra-hy2-warp'] },
  ],
  rules: ['DOMAIN-SUFFIX,future-ai.example,AI', 'DOMAIN-SUFFIX,qq.com,Main', 'MATCH,Main'],
  dns: { 'nameserver-policy': { '+.corp.test': ['192.168.1.1'], '+.claude.com': 'https://1.1.1.1/dns-query#Main' } },
});
const aiGroup = config => config['proxy-groups'].find(group => group.name === routingPolicy.aiGroup);

test('AI groups preserve subscription members, order and options, excluding WARP case-insensitively', () => {
  const input = fixture();
  input['proxy-groups'][2].url = 'https://example.org/check';
  input['proxy-groups'][2].proxies.push('Custom-WaRp-node', 'DIRECT');
  const output = applyRoutingPolicy(input);
  assert.deepEqual(aiGroup(output), {
    ...input['proxy-groups'][2], proxies: ['voyra-hy2-direct', 'voyra-direct', 'DIRECT'],
  });
  assert.deepEqual(output['proxy-groups'][3].proxies, ['voyra-anytls-direct']);
  assert.deepEqual(output['proxy-groups'][1].proxies, ['voyra-warp']);
  assert.deepEqual(output['proxy-groups'][0].proxies, ['Child']);
  assert.ok(input['proxy-groups'][2].proxies.includes('voyra-warp'));
});

test('each empty AI group rejects normalization without adding available fallback nodes', () => {
  for (const members of [[], ['voyra-warp', 'Custom-WARP-node']]) {
    const config = fixture();
    config['proxy-groups'][3].proxies = members;
    assert.throws(() => normalizeRoutingContent(stringify(config)), /AI group "AI" has no members after removing WARP nodes/);
    assert.deepEqual(config['proxy-groups'][3].proxies, members);
  }
});

test('pushed rules retain priority without a CN boundary and recognize spaced CN rules', () => {
  for (const boundary of [null, 'GEOSITE, cn, DIRECT', 'geoip, CN, DIRECT, no-resolve']) {
    const config = fixture();
    const earlyAi = 'DOMAIN,early.example,AI';
    const exception = 'DOMAIN,private.example,DIRECT';
    const lateAi = 'DOMAIN-SUFFIX,late.example,AI';
    config.rules = [earlyAi, exception, 'GEOIP,US,Main', ...(boundary ? [boundary] : []), lateAi, 'MATCH,Main'];
    const output = parse(normalizePushedAiContent(stringify(config)));
    assert.deepEqual(output.rules, boundary
      ? [earlyAi, exception, 'GEOIP,US,Main', lateAi, boundary, 'MATCH,Main']
      : config.rules);
    assert.equal(normalizePushedAiContent(stringify(output)), stringify(output, { lineWidth: 0 }));
  }
});

test('AI groups retain dynamic sources and exclude WARP through Mihomo filters', () => {
  for (const membership of [{ use: ['remote'] }, { 'include-all': true }, { 'include-all-providers': true }, { 'include-all-proxies': true }]) {
    for (const proxies of [undefined, ['voyra-warp'], ['voyra-direct', 'voyra-warp']]) {
      const config = fixture();
      config['proxy-providers'] = { remote: { type: 'http', url: 'https://example.org/nodes' } };
      const group = { name: 'AI', type: 'select', ...membership, 'exclude-filter': 'expired`offline' };
      if (proxies) group.proxies = proxies;
      config['proxy-groups'][3] = group;
      const once = normalizePushedAiContent(stringify(config));
      const output = parse(once)['proxy-groups'][3];
      assert.deepEqual(output, {
        ...group,
        ...(proxies ? { proxies: proxies.filter(name => !/warp/i.test(name)) } : {}),
        'exclude-filter': 'expired`offline`(?i)warp',
      });
      assert.equal(normalizePushedAiContent(once), once);
      assert.deepEqual(applyRoutingPolicy(config)['proxy-groups'][3], output);
    }
  }
});

test('empty dynamic AI sources still reject when only WARP proxies remain', () => {
  const config = fixture();
  config.proxies = [{ name: 'only-WARP', type: 'vless' }];
  config['proxy-groups'][3] = { name: 'AI', type: 'select', 'include-all-proxies': true };
  assert.throws(() => normalizePushedAiContent(stringify(config)), /AI group "AI" has no members/);
});

test('missing AI groups reject; existing aliases do not gain a synthetic group', () => {
  const config = fixture();
  config['proxy-groups'].splice(2, 1);
  const output = applyRoutingPolicy(config);
  assert.equal(aiGroup(output), undefined);
  assert.deepEqual(output['proxy-groups'][2].proxies, ['voyra-anytls-direct']);
  assert.ok(output.rules.includes('DOMAIN-SUFFIX,claude.com,AI'));
  config['proxy-groups'].pop();
  assert.throws(() => applyRoutingPolicy(config), /Subscription requires an AI proxy group/);
});

test('private and domestic AI stay direct, while AI and development rules precede the China IP rule', () => {
  const output = applyRoutingPolicy(fixture());
  const beforeCnIp = rule => assert.ok(output.rules.indexOf(rule) < output.rules.indexOf('GEOIP,CN,DIRECT'));
  for (const domain of ['deepseek.com', 'kimi.com', 'doubao.com', 'qianwen.com']) assert.ok(output.rules.includes(`DOMAIN-SUFFIX,${domain},DIRECT`));
  assert.ok(output.rules.includes('IP-CIDR,100.64.0.0/10,DIRECT'));
  for (const domain of ['claude.com', 'githubcopilot.com', 'windsurf.com', 'codeium.com', 'replicate.com', 'cohere.com']) beforeCnIp(`DOMAIN-SUFFIX,${domain},${routingPolicy.aiGroup}`);
  for (const category of ['github', 'google', 'youtube']) beforeCnIp(`GEOSITE,${category},Main`);
  beforeCnIp('DOMAIN-SUFFIX,pypi.org,Main');
  assert.ok(output.rules.includes('DOMAIN-SUFFIX,future-ai.example,AI'));
  for (const rule of output.rules.filter(rule => /,(?:AI|🤖 AI优先原生)$/.test(rule))) {
    assert.ok(output.rules.indexOf(rule) < output.rules.indexOf('GEOSITE,cn,DIRECT'));
    beforeCnIp(rule);
  }
  assert.ok(output.rules.indexOf('GEOSITE,cn,DIRECT') < output.rules.indexOf('DOMAIN-SUFFIX,qq.com,Main'));
});

test('AI DNS follows its subscription group, domestic DNS is direct, and corporate DNS survives', () => {
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
