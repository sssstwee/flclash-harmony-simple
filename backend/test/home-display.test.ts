import { env, exports } from 'cloudflare:workers';
import { afterEach, expect, test, vi } from 'vitest';
// @ts-expect-error The existing Pages entry point is JavaScript without declarations.
import gateway from '../gateway/public/_worker.js';
import { HOME_DISPLAY_KEY, parseHomeDisplay } from '../src/home_display.mjs';

afterEach(async () => {
  vi.restoreAllMocks();
  await env.CONFIGS!.delete(HOME_DISPLAY_KEY);
});

const get = (headers?: HeadersInit) => exports.default.fetch('https://example.com/v1/home', { headers });

test('homepage defaults are available before login without accessing accounts or private profiles', async () => {
  const db = vi.spyOn(env.DB, 'prepare');
  const response = await get();
  expect(response.status).toBe(200);
  const body = await response.json() as { texts: { homeTitle: string }; profile?: unknown };
  expect(body.texts.homeTitle).toBe('CC保镖');
  expect(body.profile).toBeUndefined();
  expect(response.headers.get('set-cookie')).toBeNull();
  expect(db).not.toHaveBeenCalled();
});

test('JSON changes refresh the ETag independently of route configuration', async () => {
  const doc = { schemaVersion: 1, texts: { homeTitle: '我的首页' }, home: { sections: ['connection', 'traffic'] } };
  await env.CONFIGS!.put(HOME_DISPLAY_KEY, JSON.stringify(doc));
  const first = await get();
  expect(await first.json()).toEqual(doc);
  const etag = first.headers.get('etag')!;
  expect((await get({ 'If-None-Match': etag })).status).toBe(304);
  doc.texts.homeTitle = '新的首页';
  await env.CONFIGS!.put(HOME_DISPLAY_KEY, JSON.stringify(doc));
  const changed = await get({ 'If-None-Match': etag });
  expect(changed.status).toBe(200);
  expect(changed.headers.get('etag')).not.toBe(etag);
  expect(await changed.json()).toEqual(doc);
  expect(await env.CONFIGS!.get('default')).toBeNull();
});

test.each([
  { schemaVersion: 2 },
  { schemaVersion: 1, profile: { proxies: [] } },
  { schemaVersion: 1, home: { sections: ['traffic'] } },
  { schemaVersion: 1, home: { sections: ['connection', 'connection'] } },
  { schemaVersion: 1, home: { sections: ['connection', 'html'] } },
  { schemaVersion: 1, home: { details: ['network', 'unknown'] } },
  { schemaVersion: 1, texts: { script: 'run()' } },
  { schemaVersion: 1, texts: { homeTitle: 'x'.repeat(257) } },
  { schemaVersion: 1, announcement: 'x'.repeat(4097) },
])('invalid UI settings are refused without exposing raw content %#', async doc => {
  const error = vi.spyOn(console, 'error').mockImplementation(() => {});
  expect(() => parseHomeDisplay(JSON.stringify(doc))).toThrow();
  await env.CONFIGS!.put(HOME_DISPLAY_KEY, JSON.stringify(doc));
  const response = await get();
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ code: 'SERVICE_UNAVAILABLE' });
  expect(JSON.stringify(error.mock.calls)).not.toContain(JSON.stringify(doc));
});

test('Pages gateway forwards homepage JSON while private config still requires login', async () => {
  const response = await gateway.fetch(new Request('https://example.com/v1/home'), {
    API: { fetch: (request: Request) => exports.default.fetch(request) },
  });
  expect(response.status).toBe(200);
  expect(response.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
  expect((await exports.default.fetch('https://example.com/v1/config')).status).toBe(401);
});
