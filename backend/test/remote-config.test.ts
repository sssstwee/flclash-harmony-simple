import { env, exports } from 'cloudflare:workers';
import { hashPassword } from 'better-auth/crypto';
import { createHash } from 'node:crypto';
import { beforeEach, expect, test } from 'vitest';

const password = 'Test-password-42!';
const url = (path: string) => `${env.AUTH_ORIGIN}${path}`;
const request = (path: string, init?: RequestInit) => exports.default.fetch(url(path), init);
const bearer = (token: string) => ({ Authorization: `Bearer ${token}` });
const kv = () => env.CONFIGS!;

function envelope(version: string, data: unknown = { profile: { proxies: [] }, runtime: {} }) {
  const payload = JSON.stringify(data);
  return {
    schemaVersion: 1,
    version,
    minClientVersion: '0.8.94+2026101206',
    sha256: createHash('sha256').update(payload, 'utf8').digest('hex'),
    payload,
  };
}

beforeEach(async () => {
  await env.DB.batch(
    ['session', 'account', 'user', 'rateLimit', 'proxy_config', 'config_fetch_audit', 'config_api_rate_limit'].map(
      table => env.DB.prepare(`DELETE FROM "${table}"`),
    ),
  );
  for (const key of (await kv().list()).keys) await kv().delete(key.name);
  const hash = await hashPassword(password);
  const date = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare('INSERT INTO user (id,name,email,emailVerified,createdAt,updatedAt,username,displayUsername) VALUES (?,?,?,?,?,?,?,?)').bind('test-user', 'tester', 'tester@example.invalid', 0, date, date, 'tester', 'tester'),
    env.DB.prepare('INSERT INTO account (id,accountId,providerId,userId,password,createdAt,updatedAt) VALUES (?,?,?,?,?,?,?)').bind('test-account', 'test-user', 'credential', 'test-user', hash, date, date),
    env.DB.prepare('INSERT INTO proxy_config (scope, scope_key, content, updated_at) VALUES (?,?,?,?)').bind('default', '', 'proxies: []', date),
  ]);
});

async function login() {
  const response = await request('/api/auth/sign-in/username', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'cf-connecting-ip': '192.0.2.9' },
    body: JSON.stringify({ username: 'tester', password }),
  });
  expect(response.status).toBe(200);
  await response.json();
  return response.headers.get('set-auth-token')!;
}

test('without a KV document the legacy YAML response is unchanged', async () => {
  const token = await login();
  const response = await request('/v1/config', { headers: bearer(token) });
  expect(response.headers.get('Content-Type')).toContain('yaml');
  expect(await response.text()).toBe('proxies: []');
});

test('KV envelope is served with ETag, version and 304, and requires auth', async () => {
  const doc = envelope('2026-10-14.1');
  await kv().put('default', JSON.stringify(doc), { metadata: { updatedAt: 1760400000 } });
  expect((await request('/v1/config')).status).toBe(401);
  expect((await request('/v1/config/version')).status).toBe(401);
  const token = await login();
  const version = await request('/v1/config/version', { headers: bearer(token) });
  expect(await version.json()).toEqual({
    version: '2026-10-14.1', updated_at: 1760400000, min_check_seconds: 300,
    minClientVersion: doc.minClientVersion, sha256: doc.sha256,
  });
  const first = await request('/v1/config', { headers: bearer(token) });
  expect(first.status).toBe(200);
  expect(first.headers.get('Content-Type')).toContain('application/json');
  expect(first.headers.get('X-Config-Version')).toBe('2026-10-14.1');
  const etag = first.headers.get('ETag')!;
  expect(etag).toMatch(/^"[0-9a-f]{64}"$/);
  const body = await first.json() as typeof doc;
  expect(body).toEqual(doc);
  expect(createHash('sha256').update(body.payload).digest('hex')).toBe(body.sha256);
  const second = await request('/v1/config', { headers: { ...bearer(token), 'If-None-Match': etag } });
  expect(second.status).toBe(304);
  expect(second.headers.get('X-Config-Version')).toBe('2026-10-14.1');
  await kv().put('default', JSON.stringify(envelope('2026-10-14.2')));
  const third = await request('/v1/config', { headers: { ...bearer(token), 'If-None-Match': etag } });
  expect(third.status).toBe(200);
  expect(third.headers.get('ETag')).not.toBe(etag);
});

test('user key overrides group and default', async () => {
  await kv().put('default', JSON.stringify(envelope('d')));
  await kv().put('group:g1', JSON.stringify(envelope('g')));
  await env.DB.prepare('UPDATE user SET config_group = ? WHERE id = ?').bind('g1', 'test-user').run();
  const token = await login();
  expect((await (await request('/v1/config/version', { headers: bearer(token) })).json() as { version: string }).version).toBe('g');
  await kv().put('user:tester', JSON.stringify(envelope('u')));
  expect((await (await request('/v1/config/version', { headers: bearer(token) })).json() as { version: string }).version).toBe('u');
});

test('tampered or malformed envelopes are refused with 503', async () => {
  const token = await login();
  for (const bad of [
    { ...envelope('x'), sha256: '0'.repeat(64) },
    { ...envelope('x'), extra: true },
    { ...envelope('x'), minClientVersion: 'latest' },
  ]) {
    await kv().put('default', JSON.stringify(bad));
    expect((await request('/v1/config', { headers: bearer(token) })).status).toBe(503);
    expect((await request('/v1/config/version', { headers: bearer(token) })).status).toBe(503);
  }
});
