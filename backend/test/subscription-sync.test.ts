import { env } from 'cloudflare:workers';
import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import worker from '../src/index';
import { configRowMeta } from '../src/config_meta';
import { SUBSCRIPTION_MAX_BYTES, SUBSCRIPTION_TIMEOUT_MS, syncSubscription, validateSubscription } from '../src/subscription_sync';
const content = 'proxies:\n  - name: node\nproxy-groups:\n  - name: auto\nrules:\n  - DOMAIN,example.org,auto\n  - MATCH,DIRECT\n';
const syncEnv = () => ({ ...env, SUBSCRIPTION_URL: 'https://example.invalid/private-token' });
const current = () => env.DB.prepare("SELECT * FROM proxy_config WHERE scope='default' AND scope_key=''").first();
const backup = () => env.DB.prepare("SELECT * FROM proxy_config_backup WHERE scope='default' AND scope_key=''").first();
const response = (body: string) => vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body)));
let log: ReturnType<typeof vi.spyOn>;
let error: ReturnType<typeof vi.spyOn>;
beforeEach(async () => {
  await env.DB.batch(['proxy_config', 'proxy_config_backup'].map(table => env.DB.prepare(`DELETE FROM ${table}`)));
  log = vi.spyOn(console, 'log').mockImplementation(() => {});
  error = vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });
test('scheduled insert, exact version, unchanged skip, atomic backup and rollback', async () => {
  response(content);
  const ctx = createExecutionContext();
  await worker.scheduled({ cron: '*/5 * * * *' } as ScheduledController, syncEnv(), ctx);
  await waitOnExecutionContext(ctx);
  const first = await current();
  expect(first?.content).toBe(content);
  expect(await backup()).toBeNull();
  const { version } = await configRowMeta({ scope: 'default', scope_key: '', content });
  expect(log).toHaveBeenLastCalledWith(JSON.stringify({ event: 'subscription_sync', status: 'updated', version }));
  response(content); await syncSubscription(syncEnv());
  expect(await current()).toEqual(first); expect(await backup()).toBeNull();
  const next = content.replace('example.org', 'example.net');
  response(next); await syncSubscription(syncEnv());
  expect((await current())?.content).toBe(next); expect(await backup()).toEqual(first);
  response(next); await syncSubscription(syncEnv()); expect(await backup()).toEqual(first);
  await env.DB.prepare("UPDATE proxy_config SET content=(SELECT content FROM proxy_config_backup WHERE scope='default' AND scope_key='') WHERE scope='default' AND scope_key=''").run();
  expect((await current())?.content).toBe(content); expect((await backup())?.content).toBe(next);
});
test.each(['bad: [', content.replace('proxies:', 'missing:'), content.replace('proxy-groups:', 'missing:'), content.replace('rules:', 'missing:'), content.replace('rules:', 'rules: []\nunused:'), content + 'rule-providers: {}\n', content.replace('DOMAIN,example.org,auto', 'RULE-SET,remote,auto'), content.replace('MATCH,DIRECT', 'MATCH,missing'), content.replace('MATCH,DIRECT', 'IP-CIDR,192.0.2.0/24,missing,no-resolve'), content + '\0'])('rejects invalid subscription %# without changing data', async invalid => {
  response(content); await syncSubscription(syncEnv()); const first = await current();
  response(invalid); await syncSubscription(syncEnv());
  expect(await current()).toEqual(first); expect(await backup()).toBeNull();
  expect(error).toHaveBeenCalled();
});
test('accepts node and builtin rule targets with no-resolve', () => {
  expect(() => validateSubscription(content + '  - IP-CIDR,192.0.2.0/24,node,no-resolve\n')).not.toThrow();
});
test('HTTP, size, network and missing secret failures preserve config and redact logs', async () => {
  response(content); await syncSubscription(syncEnv()); const first = await current();
  for (const value of [new Response('bad', { status: 503 }), new Response('x'.repeat(SUBSCRIPTION_MAX_BYTES + 1)), new Response('small', { headers: { 'Content-Length': `${SUBSCRIPTION_MAX_BYTES + 1}` } })]) {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(value)); await syncSubscription(syncEnv()); expect(await current()).toEqual(first);
  }
  vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error(syncEnv().SUBSCRIPTION_URL)));
  await syncSubscription(syncEnv()); await syncSubscription({ ...env, SUBSCRIPTION_URL: undefined });
  expect(await current()).toEqual(first);
  expect(JSON.stringify(error.mock.calls)).not.toContain('private-token');
});
test.each(['headers', 'body'])('timeout covers stalled %s', async stage => {
  vi.useFakeTimers();
  vi.stubGlobal('fetch', vi.fn().mockImplementation(() => stage === 'headers' ? new Promise(() => {}) : Promise.resolve(new Response(new ReadableStream({ start() {} })))));
  const pending = syncSubscription(syncEnv()); await vi.advanceTimersByTimeAsync(SUBSCRIPTION_TIMEOUT_MS); await pending;
  vi.useRealTimers(); expect(await current()).toBeNull(); expect(error).toHaveBeenCalled();
});
test('failed replacement is atomic and preserves other scopes', async () => {
  response(content); await syncSubscription(syncEnv()); const first = await current();
  await env.DB.prepare("INSERT INTO proxy_config VALUES ('user','someone','private','2026-01-01')").run();
  await env.DB.prepare("CREATE TRIGGER test_abort_sync AFTER UPDATE ON proxy_config BEGIN SELECT RAISE(ABORT, 'test failure'); END").run();
  try {
    response(content.replace('example.org', 'example.net')); await syncSubscription(syncEnv());
    expect(await current()).toEqual(first); expect(await backup()).toBeNull();
    expect(error).toHaveBeenCalled();
    expect((await env.DB.prepare("SELECT content FROM proxy_config WHERE scope='user'").first())?.content).toBe('private');
  } finally { await env.DB.prepare('DROP TRIGGER test_abort_sync').run(); }
});
