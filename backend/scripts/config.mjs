import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { parse } from 'yaml';

const args = process.argv.slice(2);
const sourceFile = args.find(value => !value.startsWith('--'));
const scopeFlag = args.find(value => value.startsWith('--scope='));
const scopeKeyFlag = args.find(value => value.startsWith('--scope-key='));
const scope = scopeFlag?.slice('--scope='.length) ?? 'default';
const scopeKey = scopeKeyFlag?.slice('--scope-key='.length) ?? '';
if (!sourceFile) {
  throw new Error(
    'Usage: npm run config -- PRIVATE_SECRETS_JSON [--remote] [--scope=default|user|group] [--scope-key=ID]',
  );
}
if (!['default', 'user', 'group'].includes(scope)) {
  throw new Error('scope must be default, user, or group');
}
if (scope === 'default' && scopeKey) {
  throw new Error('default scope must use an empty scope-key');
}
if (scope !== 'default' && !scopeKey) {
  throw new Error('user and group scopes require --scope-key');
}
const { SUBSCRIPTION_URL } = JSON.parse(await readFile(sourceFile, 'utf8'));
const response = await fetch(SUBSCRIPTION_URL, {
  headers: { 'User-Agent': 'ClashHarmony/1.0' },
  signal: AbortSignal.timeout(30_000),
});
if (!response.ok) throw new Error(`Subscription returned HTTP ${response.status}`);
const reader = response.body.getReader();
const chunks = [];
let size = 0;
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
const content = Buffer.concat(chunks).toString('utf8');
const config = parse(content);
if (!config || (!Array.isArray(config.proxies) && !config['proxy-providers'])) {
  throw new Error('Expected a Clash/Mihomo configuration');
}
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const sql = `INSERT INTO proxy_config (scope,scope_key,content,updated_at) VALUES (${quote(scope)},${quote(scopeKey)},${quote(content)},${quote(new Date().toISOString())}) ON CONFLICT(scope,scope_key) DO UPDATE SET content=excluded.content,updated_at=excluded.updated_at;`;
if (Buffer.byteLength(sql) > 99_000) throw new Error('Configuration exceeds the SQL import limit');
const directory = await mkdtemp(join(tmpdir(), 'clash-harmony-config-'));
try {
  const file = join(directory, 'config.sql');
  await writeFile(file, sql, { mode: 0o600 });
  const result = spawnSync(
    process.execPath,
    [
      'node_modules/wrangler/bin/wrangler.js',
      'd1',
      'execute',
      'clash-harmony-auth',
      args.includes('--remote') ? '--remote' : '--local',
      '--file',
      file,
    ],
    { stdio: 'inherit' },
  );
  if (result.status !== 0) throw new Error('Configuration sync failed');
  console.log(
    `Configuration synced (${size} bytes) for scope=${scope}${scopeKey ? ` key=${scopeKey}` : ''}.`,
  );
} finally {
  await rm(directory, { recursive: true });
}
