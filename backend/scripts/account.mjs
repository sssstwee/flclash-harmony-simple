import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, rename, rm, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { executeSql, isMain, parseOptions, quoteSql, resolveConfig, runCli, runD1 } from './operations.mjs';

const usage = 'Usage: npm run account -- USERNAME --print-password [--remote|--local] [--reset] [--out PATH] [--config PATH]';

export async function provisionAccount(args, dependencies = {}) {
  const { values, positionals } = parseOptions(args, {
    reset: { type: 'boolean' },
    'print-password': { type: 'boolean' },
    out: { type: 'string' },
  }, usage);
  const username = positionals[0].toLowerCase();
  if (!/^[a-z0-9_.]{3,30}$/.test(username)) throw new Error(usage);
  // There is no password store. Require consent to display it before changing D1.
  if (!values['print-password']) {
    throw new Error('--print-password is required: the generated password is displayed once and is never saved. No account was changed.');
  }
  if (values.out !== undefined && !values.out.trim()) throw new Error('--out requires a metadata file path');
  const config = await (dependencies.resolveConfig ?? resolveConfig)(values);
  const options = { ...values, config };
  const run = dependencies.runD1 ?? runD1;
  let userId = randomUUID();
  if (values.reset) {
    const statements = await run(options, ['--command',
      `SELECT user.id FROM user JOIN account ON account.userId=user.id WHERE user.username=${quoteSql(username)} AND account.providerId='credential';`,
    ]);
    const rows = statements.flatMap(statement => statement.results ?? []);
    if (rows.length !== 1 || typeof rows[0].id !== 'string') {
      throw new Error('Reset requires exactly one existing credential account. No password was changed.');
    }
    userId = rows[0].id;
  }

  const metadataPath = values.out === undefined
    ? join(homedir(), '.clash-harmony', 'accounts', `${username}.json`)
    : resolve(values.out);
  // Validate the output directory and prepare metadata before mutating the account.
  await mkdir(dirname(metadataPath), { recursive: true, mode: 0o700 });
  const temporary = await mkdtemp(join(dirname(metadataPath), '.account-'));
  const log = dependencies.log ?? console.log;
  try {
    const metadataFile = join(temporary, 'metadata.json');
    await writeFile(metadataFile, JSON.stringify({
      username, userId, updatedAt: new Date().toISOString(), remote: Boolean(values.remote),
    }, null, 2), { mode: 0o600, flag: 'wx' });
    const password = randomBytes(18).toString('base64url');
    const hashPassword = dependencies.hashPassword ?? (await import('better-auth/crypto')).hashPassword;
    const hash = await hashPassword(password);
    const date = quoteSql(new Date().toISOString());
    const id = quoteSql(userId);
    const name = quoteSql(username);
    const sql = values.reset
      ? `UPDATE account SET password=${quoteSql(hash)}, updatedAt=${date} WHERE providerId='credential' AND userId=${id};\nDELETE FROM session WHERE userId=${id};`
      : `INSERT INTO user (id,name,email,emailVerified,createdAt,updatedAt,username,displayUsername) VALUES (${id},${name},${quoteSql(`${username}@harmony.invalid`)},0,${date},${date},${name},${name});\nINSERT INTO account (id,accountId,providerId,userId,password,createdAt,updatedAt) VALUES (${quoteSql(randomUUID())},${id},'credential',${id},${quoteSql(hash)},${date},${date});`;
    await (dependencies.executeSql ?? executeSql)(sql, options, run);
    // Display first: a metadata filesystem failure must not discard an active password.
    log(`Generated password for ${username}: ${password}`);
    try {
      await rename(metadataFile, metadataPath);
    } catch {
      throw new Error('Account changed and its password was displayed, but metadata could not be saved. Keep the displayed password; do not rerun creation.');
    }
    log(`Account ready. User ID: ${userId}. Metadata: ${metadataPath} (password not stored).`);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

if (isMain(import.meta.url)) await runCli(provisionAccount);
