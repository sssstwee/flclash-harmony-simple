import { hashPassword } from 'better-auth/crypto';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const username = args.find(value => !value.startsWith('--'))?.toLowerCase();
const outIndex = args.indexOf('--out');
const outPath = outIndex >= 0 ? args[outIndex + 1] : undefined;
if (!username || !/^[a-z0-9_.]{3,30}$/.test(username)) {
  throw new Error(
    'Usage: npm run account -- USERNAME [--remote] [--reset] [--print-password] [--out PATH]',
  );
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
  const result = spawnSync(
    process.execPath,
    [
      'node_modules/wrangler/bin/wrangler.js',
      'd1',
      'execute',
      'clash-harmony-auth',
      args.includes('--remote') ? '--remote' : '--local',
      '--file',
      sqlFile,
    ],
    { stdio: 'inherit' },
  );
  if (result.status !== 0) throw new Error('Account provisioning failed');

  if (outPath) {
    const directory = join(outPath, '..');
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await writeFile(
      outPath,
      JSON.stringify({ username, createdAt: new Date().toISOString() }, null, 2),
      { mode: 0o600, flag: 'w' },
    );
    console.log(`Account metadata written to ${outPath} (password not stored).`);
  } else {
    const defaultDir = join(homedir(), '.clash-harmony', 'accounts');
    await mkdir(defaultDir, { recursive: true, mode: 0o700 });
    const metaFile = join(defaultDir, `${username}.json`);
    await writeFile(
      metaFile,
      JSON.stringify({ username, createdAt: new Date().toISOString() }, null, 2),
      { mode: 0o600, flag: args.includes('--reset') ? 'w' : 'wx' },
    );
    console.log(`Account ready. Metadata: ${metaFile}`);
  }

  if (args.includes('--print-password')) {
    console.log(`Generated password for ${username}: ${password}`);
  } else {
    console.log('Use --print-password once to display the generated password.');
  }
} finally {
  await rm(temporary, { recursive: true });
}
