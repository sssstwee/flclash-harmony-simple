import { hashPassword } from 'better-auth/crypto';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const username = args.find(value => !value.startsWith('--'))?.toLowerCase();
if (!username || !/^[a-z0-9_.]{3,30}$/.test(username)) {
  throw new Error('Usage: npm run account -- USERNAME [--remote] [--reset]');
}
const password = randomBytes(18).toString('base64url');
const hash = await hashPassword(password);
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const date = quote(new Date().toISOString());
const id = quote(randomUUID());
const name = quote(username);
const sql = args.includes('--reset')
  ? `UPDATE account SET password=${quote(hash)}, updatedAt=${date} WHERE providerId='credential' AND userId=(SELECT id FROM user WHERE username=${name});\nDELETE FROM session WHERE userId=(SELECT id FROM user WHERE username=${name});`
  : `INSERT INTO user (id,name,email,emailVerified,createdAt,updatedAt,username,displayUsername) VALUES (${id},${name},${quote(`${username}@harmony.invalid`)},0,${date},${date},${name},${name});\nINSERT INTO account (id,accountId,providerId,userId,password,createdAt,updatedAt) VALUES (${quote(randomUUID())},${id},'credential',${id},${quote(hash)},${date},${date});`;
const temporary = await mkdtemp(join(tmpdir(), 'clash-harmony-account-'));
try {
  const sqlFile = join(temporary, 'account.sql');
  await writeFile(sqlFile, sql, { mode: 0o600 });
  const result = spawnSync(process.execPath, [
    'node_modules/wrangler/bin/wrangler.js', 'd1', 'execute', 'clash-harmony-auth',
    args.includes('--remote') ? '--remote' : '--local', '--file', sqlFile,
  ], { stdio: 'inherit' });
  if (result.status !== 0) throw new Error('Account provisioning failed');
  const directory = join(homedir(), 'Library', 'Application Support', 'ClashHarmony', 'accounts');
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const credentials = join(directory, `${username}.json`);
  await writeFile(credentials, JSON.stringify({ username, password }, null, 2), { mode: 0o600, flag: args.includes('--reset') ? 'w' : 'wx' });
  console.log(`Account ready. Credentials saved privately: ${credentials}`);
} finally {
  await rm(temporary, { recursive: true });
}
