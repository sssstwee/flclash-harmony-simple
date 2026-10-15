import { createHash } from 'node:crypto';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { syncConfig } from './config.mjs';
import { executeSql, isMain, parseOptions, quoteSql, runCli, runD1 } from './operations.mjs';

const usage = 'Usage: npm run sync-subscription -- [--dry-run] [--local|--remote] [--scope default|user|group] [--key ID] [--config PATH]';
const version = (scope, key, content) => createHash('sha256')
  .update(JSON.stringify([scope, key, content])).digest('hex').slice(0, 16);

export function validateSubscription(content, config) {
  if (!Array.isArray(config?.['proxy-groups']) || !config['proxy-groups'].length ||
      !Array.isArray(config?.proxies) || !config.proxies.length) {
    throw new Error('Subscription requires nonempty proxy-groups and proxies');
  }
  if (Object.hasOwn(config, 'rule-providers') ||
      (Array.isArray(config.rules) && config.rules.some(rule => typeof rule === 'string' && /\bRULE-SET\s*,/i.test(rule)))) {
    throw new Error('Subscription must not contain rule-providers or RULE-SET');
  }
}

export async function syncSubscription(args, dependencies = {}) {
  const { values } = parseOptions(['environment', ...args], {
    'dry-run': { type: 'boolean', default: false },
    scope: { type: 'string', default: 'default' },
    key: { type: 'string', default: '' },
  }, usage);
  const log = dependencies.log ?? console.log;
  let content;
  const forwarded = ['environment', `--scope=${values.scope}`, `--scope-key=${values.key}`];
  for (const flag of ['remote', 'local']) if (values[flag]) forwarded.push(`--${flag}`);
  if (values.config) forwarded.push('--config', values.config);
  await syncConfig(forwarded, {
    ...dependencies,
    readPrivateJson: async () => ({ SUBSCRIPTION_URL: (dependencies.env ?? process.env).SUBSCRIPTION_URL }),
    validateContent: (raw, parsed) => {
      validateSubscription(raw, parsed);
      content = raw;
    },
    executeSql: async (sql, options) => {
      const result = await (dependencies.runD1 ?? runD1)(options, ['--command',
        `SELECT scope,scope_key,content,updated_at FROM proxy_config WHERE scope=${quoteSql(values.scope)} AND scope_key=${quoteSql(values.key)};`]);
      const rows = result.flatMap(statement => statement.results ?? []);
      if (rows.length > 1 || rows.some(row => typeof row.content !== 'string')) throw new Error('Unexpected current configuration result');
      const old = rows[0];
      const nextVersion = version(values.scope, values.key, content);
      log(`old version: ${old ? version(values.scope, values.key, old.content) : '(absent)'}; new version: ${nextVersion}`);
      if (values['dry-run']) return;
      const directory = await mkdtemp(join(tmpdir(), 'subscription-backup-'));
      const backup = join(directory, 'config.json');
      await writeFile(backup, JSON.stringify({ scope: values.scope, key: values.key, row: old ?? null }), { mode: 0o600, flag: 'wx' });
      log(`Backup: ${backup}`);
      await (dependencies.executeSql ?? executeSql)(sql, options);
      log(`New version: ${nextVersion}`);
    },
    log: () => {},
  });
}

if (isMain(import.meta.url)) await runCli(syncSubscription);
