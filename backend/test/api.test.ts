import { env, exports } from 'cloudflare:workers';
import { hashPassword } from 'better-auth/crypto';
import { beforeEach, expect, test } from 'vitest';

const password = 'Test-password-42!';
const config = 'proxies:\n  - name: example\n    type: ss\n    server: example.org\n    port: 443\n    cipher: aes-128-gcm\n    password: test\n';
const url = (path: string) => `${env.AUTH_ORIGIN}${path}`;
const request = (path: string, init?: RequestInit) => exports.default.fetch(url(path), init);
const bearer = (token: string) => ({ Authorization: `Bearer ${token}` });

beforeEach(async () => {
  await env.DB.batch(['session', 'account', 'user', 'rateLimit', 'proxy_config'].map(table => env.DB.prepare(`DELETE FROM "${table}"`)));

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

test('configuration requires authentication and public registration is disabled', async () => {
  expect((await request('/v1/config')).status).toBe(401);
  expect((await request('/v1/config', { headers: bearer('forged') })).status).toBe(401);
  expect((await request('/api/auth/sign-up/email', { method: 'POST' })).status).toBe(404);
});

test('login, protected configuration, session inspection and logout work end to end', async () => {
  const token = await login();
  const session = await request('/api/auth/get-session', { headers: bearer(token) });
  expect((await session.json() as { user: { username: string } }).user.username).toBe('tester');
  await env.DB.prepare('INSERT INTO proxy_config VALUES (1,?,?)').bind(config, new Date().toISOString()).run();
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
