import { env, exports } from 'cloudflare:workers';
import { hashPassword } from 'better-auth/crypto';
import { beforeEach, expect, test } from 'vitest';

const password = 'Test-password-42!';
const config = 'proxies:\n  - name: example\n    type: ss\n    server: example.org\n    port: 443\n    cipher: aes-128-gcm\n    password: test\n';
const url = (path: string) => `${env.AUTH_ORIGIN}${path}`;
const request = (path: string, init?: RequestInit) => exports.default.fetch(url(path), init);
const bearer = (token: string) => ({ Authorization: `Bearer ${token}` });

beforeEach(async () => {
  await env.DB.batch(
    ['session', 'account', 'user', 'rateLimit', 'proxy_config', 'config_fetch_audit', 'config_api_rate_limit'].map(
      table => env.DB.prepare(`DELETE FROM "${table}"`),
    ),
  );

  const hash = await hashPassword(password);
  const date = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare('INSERT INTO user (id,name,email,emailVerified,createdAt,updatedAt,username,displayUsername) VALUES (?,?,?,?,?,?,?,?)').bind('test-user', 'tester', 'tester@example.invalid', 0, date, date, 'tester', 'tester'),
    env.DB.prepare('INSERT INTO account (id,accountId,providerId,userId,password,createdAt,updatedAt) VALUES (?,?,?,?,?,?,?)').bind('test-account', 'test-user', 'credential', 'test-user', hash, date, date),
  ]);
});

async function login() {
  const response = await request('/api/auth/sign-in/username', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'cf-connecting-ip': '192.0.2.1' },
    body: JSON.stringify({ username: 'tester', password }),
  });
  expect(response.status).toBe(200);
  const token = response.headers.get('set-auth-token');
  expect(token).toBeTruthy();
  await response.json();
  return token!;
}

async function seedDefaultConfig(content = config) {
  await env.DB.prepare(
    'INSERT INTO proxy_config (scope, scope_key, content, updated_at) VALUES (?, ?, ?, ?)',
  ).bind('default', '', content, new Date().toISOString()).run();
}

test('configuration requires authentication and public registration is disabled', async () => {
  expect((await request('/v1/config')).status).toBe(401);
  expect((await request('/v1/config', { headers: bearer('forged') })).status).toBe(401);
  expect((await request('/api/auth/sign-up/email', { method: 'POST' })).status).toBe(404);
});

test('login, protected configuration, session inspection and logout work end to end', async () => {
  const token = await login();
  const session = await request('/api/auth/get-session', { headers: bearer(token) });
  expect((await session.json() as { user: { username: string } }).user.username).toBe('tester');
  await seedDefaultConfig();
  const response = await request('/v1/config', { headers: bearer(token) });
  expect(response.status).toBe(200);
  expect(response.headers.get('Cache-Control')).toBe('private, no-store');
  expect(await response.text()).toBe(config);
  const logout = await request('/api/auth/sign-out', {
    method: 'POST', headers: { ...bearer(token), 'Content-Type': 'application/json' }, body: '{}',
  });
  expect(logout.status).toBe(200);
  await logout.json();
  expect((await request('/v1/config', { headers: bearer(token) })).status).toBe(401);
});

test('expired and tampered signed tokens cannot download settings', async () => {
  const token = await login();
  expect((await request('/v1/config', { headers: bearer(`${token}wrong`) })).status).toBe(401);
  await env.DB.prepare('UPDATE session SET expiresAt = ?').bind('2000-01-01T00:00:00.000Z').run();
  expect((await request('/v1/config', { headers: bearer(token) })).status).toBe(401);
});

test('wrong passwords fail and repeated attempts are throttled in D1', async () => {
  const statuses: number[] = [];
  for (let attempt = 0; attempt < 6; attempt++) {
    const response = await request('/api/auth/sign-in/username', {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'cf-connecting-ip': '192.0.2.2' },
      body: JSON.stringify({ username: 'tester', password: 'incorrect-password' }),
    });
    statuses.push(response.status); await response.text();
  }
  expect(statuses.slice(0, 5)).toEqual([401, 401, 401, 401, 401]);
  expect(statuses[5]).toBe(429);
});

test('missing settings return a retryable error and oversized auth input is refused', async () => {
  const token = await login();

  const response = await request('/v1/config', { headers: bearer(token) });
  expect(response.status).toBe(503);
  expect(await response.text()).not.toContain('private subscription');
  expect((await request('/api/auth/sign-in/username', { method: 'POST', body: 'x'.repeat(5000) })).status).toBe(413);
});

test('rejects oversized auth bodies even when Content-Length lies', async () => {
  const response = await request('/api/auth/sign-in/username', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': '10' },
    body: 'x'.repeat(5000),
  });
  expect(response.status).toBe(413);
});

test('config downloads are rate limited per user', async () => {
  const token = await login();
  await seedDefaultConfig();
  const statuses: number[] = [];
  for (let i = 0; i < 31; i++) {
    statuses.push((await request('/v1/config', { headers: bearer(token) })).status);
  }
  expect(statuses.filter(status => status === 200).length).toBe(30);
  expect(statuses.at(-1)).toBe(429);
});

test('returns 304 when configuration is unchanged', async () => {
  const token = await login();
  await seedDefaultConfig();
  const first = await request('/v1/config', { headers: bearer(token) });
  const lastModified = first.headers.get('Last-Modified');
  expect(lastModified).toBeTruthy();
  const second = await request('/v1/config', {
    headers: { ...bearer(token), 'If-Modified-Since': lastModified! },
  });
  expect(second.status).toBe(304);
});

test('config exposes ETag and version endpoint', async () => {
  const token = await login();
  await seedDefaultConfig();
  const config = await request('/v1/config', { headers: bearer(token) });
  expect(config.status).toBe(200);
  const etag = config.headers.get('ETag');
  const version = config.headers.get('X-Config-Version');
  expect(etag).toMatch(/^"[0-9a-f]{64}"$/);
  expect(version).toHaveLength(16);
  const unchanged = await request('/v1/config', {
    headers: { ...bearer(token), 'If-None-Match': etag! },
  });
  expect(unchanged.status).toBe(304);
  const versionResponse = await request('/v1/config/version', { headers: bearer(token) });
  expect(versionResponse.status).toBe(200);
  expect(versionResponse.headers.get('Cache-Control')).toBe('no-cache');
  const body = await versionResponse.json() as {
    version: string;
    updated_at: number;
    min_check_seconds: number;
  };
  expect(body.version).toBe(version);
  expect(body.min_check_seconds).toBeGreaterThan(0);
  expect(typeof body.updated_at).toBe('number');
});

test('prefers per-user configuration with default fallback and logs fetches', async () => {
  const token = await login();
  await seedDefaultConfig('proxies: []');
  await env.DB.prepare(
    'INSERT INTO proxy_config (scope, scope_key, content, updated_at) VALUES (?, ?, ?, ?)',
  ).bind('user', 'test-user', config, new Date().toISOString()).run();
  const response = await request('/v1/config', { headers: bearer(token) });
  expect(response.status).toBe(200);
  expect(await response.text()).toBe(config);
  const audit = await env.DB.prepare('SELECT scope, scope_key FROM config_fetch_audit').first<{ scope: string; scope_key: string }>();
  expect(audit?.scope).toBe('user');
  expect(audit?.scope_key).toBe('test-user');
});

test('wrong HTTP method on config returns 404', async () => {
  const token = await login();
  expect((await request('/v1/config', { method: 'POST', headers: bearer(token) })).status).toBe(404);
});
