import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.mjs';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const config = JSON.parse(readFileSync(new URL('./config.example.json', import.meta.url)));
const env = { AUTH_ORIGIN: 'https://auth.example.com', CONFIGS: {
  async get(key) { assert.equal(key, 'user:alice'); return config; },
} };
const request = (path, headers = {}) => new Request(`https://config.example.com${path}`, {
  headers: { Authorization: 'Bearer test-token', ...headers },
});

test('example payload hash is correct', () => {
  assert.equal(createHash('sha256').update(config.payload).digest('hex'), config.sha256);
});
test('unauthenticated requests are rejected without reading KV', async () => {
  const response = await worker.fetch(new Request('https://config.example.com/v1/config'), env);
  assert.equal(response.status, 401);
});
test('authorized version, download and conditional 304', async () => {
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    assert.equal(url.href, 'https://auth.example.com/api/auth/get-session');
    assert.equal(options.headers.Authorization, 'Bearer test-token');
    return Response.json({ user: { username: 'alice' } });
  };
  try {
    const version = await worker.fetch(request('/v1/config/version'), env);
    assert.deepEqual(await version.json(), { version: config.version, min_check_seconds: 300 });
    const download = await worker.fetch(request('/v1/config'), env);
    assert.deepEqual(await download.clone().json(), config);
    const response = await worker.fetch(request('/v1/config', { 'If-None-Match': download.headers.get('ETag') }), env);
    assert.equal(response.status, 304);
    assert.equal(await response.text(), '');
  } finally { globalThis.fetch = previousFetch; }
});
test('expired accounts cannot obtain cached payloads', async () => {
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(null, { status: 401 });
  try { assert.equal((await worker.fetch(request('/v1/config'), env)).status, 401); }
  finally { globalThis.fetch = previousFetch; }
});
