import { access, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

export const backendDirectory = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function parseOptions(args, options, usage) {
  let parsed;
  try {
    parsed = parseArgs({
      args,
      options: {
        remote: { type: 'boolean' },
        local: { type: 'boolean' },
        config: { type: 'string' },
        ...options,
      },
      allowPositionals: true,
      strict: true,
    });
  } catch {
    throw new Error(usage);
  }
  if (parsed.positionals.length !== 1 || (parsed.values.remote && parsed.values.local)) {
    throw new Error(usage);
  }
  if (parsed.values.config !== undefined && !parsed.values.config.trim()) {
    throw new Error('--config must name a Wrangler configuration file');
  }
  return parsed;
}

export async function resolveConfig(options) {
  const config = options.config === undefined
    ? join(backendDirectory, options.remote ? 'wrangler.local.jsonc' : 'wrangler.jsonc')
    : resolve(options.config);
  try {
    await access(config);
  } catch {
    throw new Error(options.remote
      ? 'Remote operations require a private Wrangler config. Copy wrangler.local.jsonc.example to wrangler.local.jsonc and fill its placeholders, or pass --config PATH.'
      : 'Wrangler configuration file is unavailable. Check --config PATH.');
  }
  return config;
}

export const quoteSql = value => `'${String(value).replaceAll("'", "''")}'`;

// Capture output: Wrangler errors can echo SQL containing password hashes or proxy credentials.
export function runD1(options, input, run = spawnSync) {
  const result = run(process.execPath, [
    join(backendDirectory, 'node_modules/wrangler/bin/wrangler.js'),
    'd1', 'execute', 'DB',
    '--config', options.config,
    options.remote ? '--remote' : '--local',
    '--json',
    ...input,
  ], {
    cwd: backendDirectory,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 4 * 1024 * 1024,
    env: { ...process.env, WRANGLER_SEND_METRICS: 'false', WRANGLER_LOG: 'log', WRANGLER_WRITE_LOGS: 'false' },
  });
  if (result.error || result.status !== 0) {
    throw new Error('D1 operation failed. Wrangler output was suppressed to protect credentials. Check the selected config, authentication, and migrations before retrying.');
  }
  let data;
  try {
    data = JSON.parse(result.stdout);
  } catch {
    throw new Error('D1 returned an unreadable result. Verify database state before retrying.');
  }
  const statements = Array.isArray(data) ? data : [data];
  if (statements.some(statement => !statement || statement.success === false || statement.error)) {
    throw new Error('D1 reported a failed operation. Verify database state before retrying.');
  }
  return statements;
}

export async function executeSql(sql, options, run = runD1) {
  const directory = await mkdtemp(join(tmpdir(), 'clash-harmony-sql-'));
  try {
    const file = join(directory, 'operation.sql');
    await writeFile(file, sql, { mode: 0o600, flag: 'wx' });
    return await run(options, ['--file', file]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

export async function readPrivateJson(path) {
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch {
    throw new Error('Cannot read the private JSON file, or it contains invalid JSON.');
  }
}

export function isMain(url) {
  return process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === url;
}

export async function runCli(main) {
  try {
    await main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
