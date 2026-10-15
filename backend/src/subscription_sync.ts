import { parse } from 'yaml';

export const SUBSCRIPTION_MAX_BYTES = 90_000;

declare global {
  interface Env { SUBSCRIPTION_PUSH_TOKEN?: string; }
  namespace Cloudflare { interface Env { SUBSCRIPTION_PUSH_TOKEN?: string; } }
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
