import { configUpsertSql } from '../src/config_write.mjs';
import { normalizeRoutingContent } from '../src/routing_policy.mjs';
import { executeSql, isMain, parseOptions, quoteSql, readPrivateJson, resolveConfig, runCli } from './operations.mjs';

const usage = 'Usage: npm run config -- PRIVATE_SECRETS_JSON [--remote|--local] [--scope=default|user|group] [--scope-key=ID] [--config PATH]';

export async function syncConfig(args, dependencies = {}) {
  const { values, positionals } = parseOptions(args, {
    scope: { type: 'string', default: 'default' },
    'scope-key': { type: 'string', default: '' },
  }, usage);
  const scope = values.scope;
  const scopeKey = values['scope-key'];
  if (!['default', 'user', 'group'].includes(scope)) throw new Error('scope must be default, user, or group');
  if (scope === 'default' && scopeKey) throw new Error('default scope must use an empty scope-key');
  if (scope !== 'default' && !scopeKey.trim()) throw new Error('user and group scopes require --scope-key');
  if (Buffer.byteLength(scopeKey) > 256 || /[\u0000-\u001f\u007f]/.test(scopeKey)) {
    throw new Error('scope-key is invalid or too long');
  }
  const configPath = await (dependencies.resolveConfig ?? resolveConfig)(values);
  const secrets = await (dependencies.readPrivateJson ?? readPrivateJson)(positionals[0]);
  let subscription;
  try {
    if (typeof secrets?.SUBSCRIPTION_URL !== 'string') throw new Error();
    subscription = new URL(secrets.SUBSCRIPTION_URL);
    if (subscription.protocol !== 'https:' || subscription.username || subscription.password) throw new Error();
  } catch {
    throw new Error('SUBSCRIPTION_URL must be an HTTPS URL without embedded login credentials.');
  }
  const chunks = [];
  let size = 0;
  try {
    const response = await (dependencies.fetch ?? fetch)(subscription, {
      headers: { 'User-Agent': 'XiaomaoAIProxy/1.0' },
      redirect: 'error',
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`Subscription returned HTTP ${response.status}`);
    if (!response.body) throw new Error('Subscription returned an empty body');
    const reader = response.body.getReader();
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 90_000) {
          await reader.cancel();
          throw new Error('Configuration exceeds the 90 KB SQL import limit');
        }
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
  } catch (error) {
    if (/^(Subscription returned (HTTP \d+|an empty body)|Configuration exceeds the 90 KB SQL import limit)$/.test(error.message)) throw error;
    throw new Error('Could not download the subscription. Check its URL, connectivity, and the 30-second timeout.');
  }
  let content = Buffer.concat(chunks).toString('utf8');
  let config;
  try {
    const parse = dependencies.parse ?? (await import('yaml')).parse;
    config = parse(content, { logLevel: 'error', prettyErrors: false });
  } catch {
    // YAML parser messages include source snippets, which can contain proxy credentials.
    throw new Error('Subscription is not valid YAML. Its contents were not logged.');
  }
  const providers = config?.['proxy-providers'];
  const hasProxies = Array.isArray(config?.proxies) && config.proxies.length > 0;
  const hasProviders = providers && typeof providers === 'object' && !Array.isArray(providers) && Object.keys(providers).length > 0;
  if (!config || typeof config !== 'object' || Array.isArray(config) || (!hasProxies && !hasProviders)) {
    throw new Error('Expected a Clash/Mihomo configuration with nonempty proxies or proxy-providers');
  }
  if (content.includes('\0')) throw new Error('Configuration must not contain NUL characters');
  content = normalizeRoutingContent(content);
  await dependencies.validateContent?.(content, config);
  const sql = configUpsertSql([scope, scopeKey, content, new Date().toISOString()].map(quoteSql));
  if (Buffer.byteLength(sql) > 99_000) throw new Error('Configuration exceeds the SQL import limit');
  await (dependencies.executeSql ?? executeSql)(sql, { ...values, config: configPath });
  (dependencies.log ?? console.log)(`Configuration synced (${size} bytes) for scope=${scope}${scopeKey ? ` key=${scopeKey}` : ''}.`);
}

if (isMain(import.meta.url)) await runCli(syncConfig);
