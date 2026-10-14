import { parse } from 'yaml';
import { configRowMeta } from './config_meta';
import { configUpsertSql } from './config_write.mjs';

export const SUBSCRIPTION_TIMEOUT_MS = 30_000;
export const SUBSCRIPTION_MAX_BYTES = 90_000;

declare global {
  interface Env { SUBSCRIPTION_URL?: string; }
  namespace Cloudflare { interface Env { SUBSCRIPTION_URL?: string; } }
}

export function validateSubscription(content: string): void {
  if (content.includes('\0')) throw new Error('invalid');
  const config = parse(content, { logLevel: 'silent', prettyErrors: false });
  if (!config || typeof config !== 'object' || Array.isArray(config) ||
      !Array.isArray(config.proxies) || !config.proxies.length ||
      !Array.isArray(config['proxy-groups']) || !config['proxy-groups'].length ||
      !Array.isArray(config.rules) || !config.rules.length ||
      Object.hasOwn(config, 'rule-providers')) throw new Error('invalid');
  const targets = new Set(['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE']);
  for (const entry of [...config.proxies, ...config['proxy-groups']]) {
    if (!entry || typeof entry.name !== 'string' || !entry.name.trim() || targets.has(entry.name)) {
      throw new Error('invalid');
    }
    targets.add(entry.name);
  }
  for (const rule of config.rules) {
    if (typeof rule !== 'string' || /\bRULE-SET\s*,/i.test(rule)) throw new Error('invalid');
    const parts = rule.split(',').map((part: string) => part.trim());
    const target = parts.at(-1) === 'no-resolve' ? parts.at(-2) : parts.at(-1);
    if (parts.length < 2 || !target || !targets.has(target)) throw new Error('invalid');
  }
}

export async function syncSubscription(env: Pick<Env, 'DB' | 'SUBSCRIPTION_URL'>): Promise<void> {
  let stage = 'download';
  const controller = new AbortController();
  // Covers both response headers and streaming body, even for stalled streams.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(new Error('timeout')); }, SUBSCRIPTION_TIMEOUT_MS);
  });
  try {
    const content = await Promise.race([timeout, (async () => {
      const url = new URL(env.SUBSCRIPTION_URL ?? '');
      if (url.protocol !== 'https:' || url.username || url.password) throw new Error('invalid');
      const response = await fetch(url, {
        headers: { 'User-Agent': 'XiaomaoAIProxy/1.0' },
        redirect: 'error', signal: controller.signal,
      });
      if (!response.ok || !response.body || Number(response.headers.get('Content-Length')) > SUBSCRIPTION_MAX_BYTES) {
        controller.abort();
        throw new Error('download');
      }
      const reader = response.body.getReader();
      const chunks: Uint8Array[] = [];
      let size = 0;
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > SUBSCRIPTION_MAX_BYTES) {
            void reader.cancel().catch(() => undefined);
            throw new Error('size');
          }
          chunks.push(value);
        }
      } finally { reader.releaseLock(); }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    })()]);
    clearTimeout(timer);
    stage = 'validation';
    validateSubscription(content);
    const row = { scope: 'default', scope_key: '', content };
    const { version } = await configRowMeta(row);
    stage = 'database';
    const result = await env.DB.prepare(configUpsertSql(['?', '?', '?', '?']))
      .bind(row.scope, row.scope_key, content, new Date().toISOString()).run();
    console.log(JSON.stringify({ event: 'subscription_sync', status: result.meta.changes ? 'updated' : 'unchanged', version }));
  } catch {
    // Never log source URLs, parser snippets, credentials, or raw exceptions.
    console.error(JSON.stringify({ event: 'subscription_sync_failed', stage }));
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}
