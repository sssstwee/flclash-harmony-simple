import { parse, stringify } from 'yaml';
import { env } from 'cloudflare:workers';
import { createExecutionContext } from 'cloudflare:test';
import { beforeEach, expect, test, vi } from 'vitest';
import worker from '../src/index';
import { configRowMeta } from '../src/config_meta';
import { SUBSCRIPTION_MAX_BYTES } from '../src/subscription_sync';

const content = 'proxies:\n  - name: node\n    type: ss\nproxy-groups:\n  - name: auto\n    type: select\n    proxies: [node]\nrules:\n  - DOMAIN,example.org,auto\n  - MATCH,DIRECT\n';
const token = 'test-push-secret';
const current = () => env.DB.prepare("SELECT * FROM proxy_config WHERE scope='default' AND scope_key=''").first();
const backup = () => env.DB.prepare("SELECT * FROM proxy_config_backup WHERE scope='default' AND scope_key=''").first();
function push(body = content, query = '', authorization = 'Bearer ' + token, secret: string | undefined = token, headers = {}) {
  return worker.fetch(new Request('https://example.com/v1/admin/subscription' + query, {
    method: 'POST', headers: { Authorization: authorization, ...headers }, body,
  }) as Request<unknown, IncomingRequestCfProperties>, { ...env, SUBSCRIPTION_PUSH_TOKEN: secret }, createExecutionContext());
}
beforeEach(async () => {
  await env.DB.batch(['proxy_config', 'proxy_config_backup', 'subscription_push_rate_limit'].map(table => env.DB.prepare(`DELETE FROM ${table}`)));
});
test('push versions, unchanged timestamp/backup, changed backup', async () => {
  const version = (await configRowMeta({ scope: 'default', scope_key: '', content })).version;
  expect(await (await push()).json()).toEqual({ changed: true, oldVersion: null, newVersion: version });
  const first = await current();
  expect(first?.content).toBe(content);
  expect(await (await push()).json()).toEqual({ changed: false, oldVersion: version, newVersion: version });
  expect(await current()).toEqual(first);
  expect(await backup()).toBeNull();
  const next = content.replace('example.org', 'example.net');
  const result = await (await push(next)).json() as { changed: boolean; oldVersion: string };
  expect(result.changed).toBe(true);
  expect(result.oldVersion).toBe(version);
  expect(await backup()).toEqual(first);
  await push(next);
  expect(await backup()).toEqual(first);
});
test('requires configured secret and exact bearer token before DB access', async () => {
  for (const auth of ['', 'Bearer wrong', 'Basic ' + token, 'Bearer ' + token + 'x']) expect((await push(content, '', auth)).status).toBe(401);
  expect((await push(content, '', 'Bearer ' + token, '')).status).toBe(401);
  expect(await current()).toBeNull();
  expect(await env.DB.prepare('SELECT * FROM subscription_push_rate_limit').first()).toBeNull();
});
test.each(['bad: [', content + '\0', content + 'rule-providers: {}', content.replace('MATCH,DIRECT', 'MATCH,missing'), content.replace('MATCH,DIRECT', 'RULE-SET,remote,auto'), content.replace('proxies:', 'missing:')])('rejects invalid body without writes %#', async body => {
  expect((await push(body)).status).toBe(400);
  expect(await current()).toBeNull();
});
test('limits declared and streamed bytes', async () => {
  expect((await push('x'.repeat(SUBSCRIPTION_MAX_BYTES + 1))).status).toBe(413);
  expect((await push(content, '', undefined, token, { 'Content-Length': String(SUBSCRIPTION_MAX_BYTES + 1) })).status).toBe(413);
  expect(await current()).toBeNull();
});
test('validates scope and isolates scoped writes', async () => {
  for (const query of ['?scope=bad', '?key=x', '?scope=user', '?scope=group&key=%00', '?scope=user&key=' + 'a'.repeat(129), '?scope=user&scope=group&key=x', '?other=x']) {
    expect((await push(content, query)).status).toBe(400);
  }
  expect((await push(content, '?scope=group&key=team')).status).toBe(200);
  expect(await current()).toBeNull();
  expect((await env.DB.prepare("SELECT content FROM proxy_config WHERE scope='group' AND scope_key='team'").first())?.content).toBe(content);
});
test('atomic global quota across scopes resets next minute', async () => {
  const now = Date.now();
  const clock = vi.spyOn(Date, 'now').mockReturnValue(now);
  try {
    for (let i = 0; i < 10; i++) expect((await push()).status).toBe(200);
    expect((await push(content, '?scope=user&key=x')).status).toBe(429);
    clock.mockReturnValue(now + 60_000);
    expect((await push()).status).toBe(200);
  } finally { clock.mockRestore(); }
});
test('failed replacement rolls back config and backup without leaking secrets', async () => {
  await push();
  const first = await current();
  await env.DB.prepare("CREATE TRIGGER test_abort_sync AFTER UPDATE ON proxy_config BEGIN SELECT RAISE(ABORT, 'private data'); END").run();
  const log = vi.spyOn(console, 'error').mockImplementation(() => {});
  try {
    expect((await push(content.replace('example.org', 'example.net'))).status).toBe(503);
    expect(await current()).toEqual(first);
    expect(await backup()).toBeNull();
    expect(JSON.stringify(log.mock.calls)).not.toContain(token);
    expect(JSON.stringify(log.mock.calls)).not.toContain('private data');
    expect(JSON.stringify(log.mock.calls)).not.toContain(content);
  } finally {
    log.mockRestore();
    await env.DB.prepare('DROP TRIGGER test_abort_sync').run();
  }
});

test('push filters WARP and places AI rules before CN; empty AI replacement leaves data intact', async () => {
  const ai = content.replace('proxies: [node]', 'proxies: [node]\n  - name: AI\n    type: select\n    proxies: [node, Custom-WaRp]')
    .replace('rules:\n', 'rules:\n  - GEOSITE,cn,DIRECT\n  - GEOIP,CN,DIRECT\n  - DOMAIN,ai.example,AI\n');
  expect((await push(ai)).status).toBe(200);
  const first = await current();
  const document = parse(first?.content as string);
  expect(document['proxy-groups'][1]).toEqual({ name: 'AI', type: 'select', proxies: ['node'] });
  expect(document.rules.indexOf('DOMAIN,ai.example,AI')).toBeLessThan(document.rules.indexOf('GEOSITE,cn,DIRECT'));
  const response = await push(ai.replace('[node, Custom-WaRp]', '[Custom-WaRp]'));
  expect(response.status).toBe(400);
  expect(JSON.stringify(await response.json())).toContain('AI_GROUP_EMPTY_AFTER_WARP_REMOVAL');
  expect(await current()).toEqual(first);
  expect(await backup()).toBeNull();
});

test.each([null, 'GEOSITE, cn, DIRECT', 'geoip, CN, DIRECT, no-resolve'])('push accepts provider-only AI membership and retains rule exceptions: %s', async boundary => {
  const document = parse(content);
  document['proxy-providers'] = { remote: { type: 'http', url: 'https://example.org/nodes' } };
  document['proxy-groups'].push({ name: 'AI', type: 'select', use: ['remote'], 'exclude-filter': 'expired' });
  const exception = 'DOMAIN,private.example,DIRECT';
  const ai = 'DOMAIN-SUFFIX,example.org,AI';
  document.rules = [exception, ...(boundary ? [boundary] : []), ai, 'MATCH,auto'];
  expect((await push(stringify(document))).status).toBe(200);
  const stored = parse((await current())?.content as string);
  expect(stored['proxy-groups'][1]).toEqual({
    name: 'AI', type: 'select', use: ['remote'], 'exclude-filter': 'expired`(?i)warp',
  });
  expect(stored.rules).toEqual([exception, ai, ...(boundary ? [boundary] : []), 'MATCH,auto']);
  expect((await (await push(stringify(document))).json() as { changed: boolean }).changed).toBe(false);
  expect(await backup()).toBeNull();
});
