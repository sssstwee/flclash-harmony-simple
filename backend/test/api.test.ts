import { env, exports } from 'cloudflare:workers';
import { hashPassword } from 'better-auth/crypto';
import { beforeEach, expect, test } from 'vitest';
import { createExecutionContext } from 'cloudflare:test';
import { parse } from 'yaml';
import worker from '../src/index';

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

async function login(username = 'tester') {
  const response = await request('/api/auth/sign-in/username', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'cf-connecting-ip': '192.0.2.1' },
    body: JSON.stringify({ username, password }),
  });
  expect(response.status).toBe(200);
  expect(response.headers.get('Cache-Control')).toBe('no-store');
  const token = response.headers.get('set-auth-token');
  expect(token).toBeTruthy();
  await response.json();
  return token!;
}

async function seedConfig(
  scope: string,
  scopeKey: string,
  content = config,
  updatedAt = new Date().toISOString(),
) {
  await env.DB.prepare(
    'INSERT INTO proxy_config (scope, scope_key, content, updated_at) VALUES (?, ?, ?, ?)',
  ).bind(scope, scopeKey, content, updatedAt).run();
}

async function seedDefaultConfig(content = config) {
  await seedConfig('default', '', content);
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

test('login includes only the created session expiry and retains signed bearer authentication', async () => {
  const response = await request('/api/auth/sign-in/username', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'tester', password }),
  });
  expect(response.status).toBe(200);
  const token = response.headers.get('set-auth-token')!;
  expect(token).toBeTruthy();
  const body = await response.json() as { session: { expiresAt: string }; user: { username: string } };
  expect(body.user.username).toBe('tester');
  expect(Object.keys(body.session)).toEqual(['expiresAt']);
  expect(Date.parse(body.session.expiresAt)).toBeGreaterThan(Date.now());
  const inspected = await request('/api/auth/get-session', { headers: bearer(token) });
  const session = await inspected.json() as { session: { expiresAt: string } };
  expect(body.session.expiresAt).toBe(session.session.expiresAt);

  const invalid = await request('/api/auth/sign-in/username', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'tester', password: 'wrong-password' }),
  });
  expect(invalid.status).toBe(401);
  expect(invalid.headers.get('set-auth-token')).toBeNull();
  expect(await invalid.json()).not.toHaveProperty('session');
});

test('expired and tampered signed tokens cannot download settings', async () => {
  const token = await login();
  expect((await request('/v1/config', { headers: bearer(`${token}wrong`) })).status).toBe(401);
  await env.DB.prepare('UPDATE session SET expiresAt = ?').bind('2000-01-01T00:00:00.000Z').run();
  expect((await request('/v1/config', { headers: bearer(token) })).status).toBe(401);
});

test('VPS push, storage and authenticated download preserve the exact source configuration', async () => {
  const token = await login();
  const source = config + '# VPS owns routing, group order and DNS.\nproxy-groups:\n  - name: Main\n    type: fallback\n    proxies: [example]\nrules: ["DOMAIN-SUFFIX,deepseek.com,DIRECT", "MATCH,Main"]\ndns:\n  nameserver-policy:\n    +.corp.test: [system://]\nharmony-runtime: {}\n';
  const pushed = await worker.fetch(new Request(url('/v1/admin/subscription'), {
    method: 'POST', headers: { Authorization: 'Bearer source-test-token' }, body: source,
  }) as Request<unknown, IncomingRequestCfProperties>, { ...env, SUBSCRIPTION_PUSH_TOKEN: 'source-test-token' }, createExecutionContext());
  expect(pushed.status).toBe(200);
  expect((await env.DB.prepare("SELECT content FROM proxy_config WHERE scope='default' AND scope_key=''").first())?.content).toBe(source);
  const response = await request('/v1/config', { headers: bearer(token) });
  expect(response.status).toBe(200);
  const body = await response.text();
  expect(body).toBe(source);
  const document = parse(body);
  expect(document['harmony-runtime']).toEqual({});
  expect(document.rules).toEqual(['DOMAIN-SUFFIX,deepseek.com,DIRECT', 'MATCH,Main']);
  expect(document['proxy-groups']).toEqual([{ name: 'Main', type: 'fallback', proxies: ['example'] }]);
  expect(document.dns['nameserver-policy']).toEqual({ '+.corp.test': ['system://'] });
  const version = response.headers.get('X-Config-Version');
  expect((await pushed.json() as { newVersion: string }).newVersion).toBe(version);
  const poll = await request('/v1/config/version', { headers: bearer(token) });
  expect((await poll.json() as { version: string }).version).toBe(version);
  const unchanged = await request('/v1/config', { headers: { ...bearer(token), 'If-None-Match': response.headers.get('ETag')! } });
  expect(unchanged.status).toBe(304);
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

test.each([
  { name: 'first use', initialCount: null, windowAge: 0, accepted: 30, requests: 40 },
  { name: 'near the cap', initialCount: 29, windowAge: 0, accepted: 1, requests: 20 },
  { name: 'expired window', initialCount: 30, windowAge: 60, accepted: 30, requests: 40 },
])('config admission is atomic under concurrent $name requests', async scenario => {
  const token = await login();
  await seedDefaultConfig();
  if (scenario.initialCount !== null) {
    await env.DB.prepare(
      'INSERT INTO config_api_rate_limit (user_id, window_start, request_count) VALUES (?, ?, ?)',
    ).bind('test-user', Math.floor(Date.now() / 1000) - scenario.windowAge, scenario.initialCount).run();
  }
  const statuses = await Promise.all(Array.from({ length: scenario.requests }, async () => {
    const response = await request('/v1/config', { headers: bearer(token) });
    await response.text();
    return response.status;
  }));
  expect(statuses.filter(status => status === 200)).toHaveLength(scenario.accepted);
  expect(statuses.filter(status => status === 429)).toHaveLength(scenario.requests - scenario.accepted);
  const counter = await env.DB.prepare(
    'SELECT request_count FROM config_api_rate_limit WHERE user_id = ?',
  ).bind('test-user').first<{ request_count: number }>();
  expect(counter?.request_count).toBe(30);
});

test('exhausting one user limit does not throttle another user', async () => {
  const token = await login();
  const date = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare('INSERT INTO user (id,name,email,emailVerified,createdAt,updatedAt,username,displayUsername) VALUES (?,?,?,?,?,?,?,?)').bind('other-user', 'other', 'other@example.invalid', 0, date, date, 'other', 'other'),
    env.DB.prepare("INSERT INTO account (id,accountId,providerId,userId,password,createdAt,updatedAt) SELECT 'other-account','other-user','credential','other-user',password,createdAt,updatedAt FROM account WHERE id = 'test-account'"),
    env.DB.prepare('INSERT INTO config_api_rate_limit (user_id, window_start, request_count) VALUES (?, ?, ?)').bind('test-user', Math.floor(Date.now() / 1000), 30),
  ]);
  const otherToken = await login('other');
  await seedDefaultConfig();
  expect((await request('/v1/config', { headers: bearer(token) })).status).toBe(429);
  expect((await request('/v1/config', { headers: bearer(otherToken) })).status).toBe(200);
});

test('returns 304 only for a matching representation ETag', async () => {
  const token = await login();
  await seedDefaultConfig();
  const first = await request('/v1/config', { headers: bearer(token) });
  const etag = first.headers.get('ETag');
  expect(etag).toMatch(/^"[a-f0-9]{64}"$/);
  expect(first.headers.get('Last-Modified')).toBeTruthy();
  const second = await request('/v1/config', {
    headers: { ...bearer(token), 'If-None-Match': etag! },
  });
  expect(second.status).toBe(304);
  expect(second.headers.get('ETag')).toBe(etag);
  expect(second.headers.get('Cache-Control')).toBe('private, no-store');
  expect(second.headers.get('X-Content-Type-Options')).toBe('nosniff');
  expect(await second.text()).toBe('');
});

test('weak, list and wildcard ETag validators work only after authentication', async () => {
  const token = await login();
  await seedDefaultConfig();
  const first = await request('/v1/config', { headers: bearer(token) });
  const etag = first.headers.get('ETag')!;
  for (const validator of [`W/${etag}`, `"unrelated", W/${etag}`, '*']) {
    expect((await request('/v1/config', {
      headers: { ...bearer(token), 'If-None-Match': validator },
    })).status).toBe(304);
  }
  expect((await request('/v1/config', {
    headers: { 'If-None-Match': etag },
  })).status).toBe(401);
  await env.DB.prepare('DELETE FROM session').run();
  expect((await request('/v1/config', {
    headers: { ...bearer(token), 'If-None-Match': etag },
  })).status).toBe(401);
});

test('date-only and mismatching ETag requests cannot reuse stale settings', async () => {
  const token = await login();
  await seedDefaultConfig();
  const first = await request('/v1/config', { headers: bearer(token) });
  const conditionalHeaders: Record<string, string>[] = [
    { 'If-Modified-Since': first.headers.get('Last-Modified')! },
    { 'If-Modified-Since': 'Thu, 01 Jan 2099 00:00:00 GMT' },
    { 'If-Modified-Since': 'not a date' },
    { 'If-None-Match': '"different"', 'If-Modified-Since': 'Thu, 01 Jan 2099 00:00:00 GMT' },
  ];
  for (const headers of conditionalHeaders) {
    expect((await request('/v1/config', { headers: { ...bearer(token), ...headers } })).status).toBe(200);
  }
});

test('same-second content edits invalidate the previous ETag', async () => {
  const token = await login();
  await seedConfig('default', '', config, '2026-01-01T00:00:00.100Z');
  const first = await request('/v1/config', { headers: bearer(token) });
  await env.DB.prepare('UPDATE proxy_config SET content = ?, updated_at = ?')
    .bind('proxies: []', '2026-01-01T00:00:00.900Z').run();
  const changed = await request('/v1/config', {
    headers: {
      ...bearer(token),
      'If-None-Match': first.headers.get('ETag')!,
      'If-Modified-Since': first.headers.get('Last-Modified')!,
    },
  });
  expect(changed.status).toBe(200);
  expect(changed.headers.get('Last-Modified')).toBe(first.headers.get('Last-Modified'));
  expect(changed.headers.get('ETag')).not.toBe(first.headers.get('ETag'));
  expect(await changed.text()).toBe('proxies: []');
});

test('removing a user override returns an older fallback instead of 304', async () => {
  const token = await login();
  await seedConfig('default', '', 'proxies: []', '2025-01-01T00:00:00.000Z');
  await seedConfig('user', 'test-user', config, '2026-01-01T00:00:00.000Z');
  const first = await request('/v1/config', { headers: bearer(token) });
  await env.DB.prepare('DELETE FROM proxy_config WHERE scope = ?').bind('user').run();
  const fallback = await request('/v1/config', {
    headers: {
      ...bearer(token),
      'If-None-Match': first.headers.get('ETag')!,
      'If-Modified-Since': first.headers.get('Last-Modified')!,
    },
  });
  expect(fallback.status).toBe(200);
  expect(await fallback.text()).toBe('proxies: []');
});

test('group changes resolve current membership and invalidate old validators', async () => {
  const token = await login();
  await seedConfig('default', '', 'proxies: []', '2024-01-01T00:00:00.000Z');
  await seedConfig('group', 'first', config, '2026-01-01T00:00:00.000Z');
  await seedConfig('group', 'second', 'proxies: [second]', '2025-01-01T00:00:00.000Z');
  await env.DB.prepare('UPDATE user SET config_group = ? WHERE id = ?').bind('first', 'test-user').run();
  const first = await request('/v1/config', { headers: bearer(token) });
  expect(await first.text()).toBe(config);
  await env.DB.prepare('UPDATE user SET config_group = ? WHERE id = ?').bind('second', 'test-user').run();
  const second = await request('/v1/config', {
    headers: {
      ...bearer(token),
      'If-None-Match': first.headers.get('ETag')!,
      'If-Modified-Since': first.headers.get('Last-Modified')!,
    },
  });
  expect(second.status).toBe(200);
  expect(await second.text()).toBe('proxies: [second]');
  await env.DB.prepare('UPDATE user SET config_group = NULL WHERE id = ?').bind('test-user').run();
  const fallback = await request('/v1/config', {
    headers: { ...bearer(token), 'If-None-Match': second.headers.get('ETag')! },
  });
  expect(fallback.status).toBe(200);
  expect(await fallback.text()).toBe('proxies: []');
});

test('a matching ETag never bypasses the per-user rate limit', async () => {
  const token = await login();
  await seedDefaultConfig();
  const first = await request('/v1/config', { headers: bearer(token) });
  await env.DB.prepare('UPDATE config_api_rate_limit SET request_count = 30').run();
  const limited = await request('/v1/config', {
    headers: { ...bearer(token), 'If-None-Match': first.headers.get('ETag')! },
  });
  expect(limited.status).toBe(429);
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
