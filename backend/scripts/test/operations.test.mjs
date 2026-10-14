import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { provisionAccount } from '../account.mjs';
import { syncConfig } from '../config.mjs';
import { executeSql, parseOptions, readPrivateJson, resolveConfig, runD1 } from '../operations.mjs';

async function workspace(t) {
  const directory = await mkdtemp(join(tmpdir(), 'harmony-operations-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

function accountDependencies(overrides = {}) {
  return {
    resolveConfig: async () => '/private/wrangler.local.jsonc',
    hashPassword: async password => `hash:${password}`,
    executeSql: async () => {},
    log: () => {},
    ...overrides,
  };
}

function configDependencies(overrides = {}) {
  return {
    resolveConfig: async () => '/private/wrangler.local.jsonc',
    readPrivateJson: async () => ({ SUBSCRIPTION_URL: 'https://example.org/private?token=fixture' }),
    fetch: async () => new Response("proxies:\n  - name: 'fixture'\n"),
    parse: (content, options) => {
      assert.deepEqual(options, { logLevel: 'error', prettyErrors: false });
      return { proxies: [{ name: 'fixture' }] };
    },
    executeSql: async () => {},
    log: () => {},
    ...overrides,
  };
}

test('account requires explicit password display before any side effects', async () => {
  let called = false;
  await assert.rejects(provisionAccount(['tester'], accountDependencies({
    resolveConfig: async () => { called = true; },
  })), /--print-password is required/);
  assert.equal(called, false);
});

test('strict options reject unknown, conflicting, extra or missing arguments', async () => {
  for (const args of [
    ['tester', '--print-password', '--remtoe'], ['tester', '--print-password', '--remote', '--local'],
    ['tester', 'extra', '--print-password'], ['tester', '--print-password', '--out'],
    ['tester', '--print-password', '--config='],
  ]) await assert.rejects(provisionAccount(args, accountDependencies()));
  const parsed = parseOptions(['--config', '/path/with spaces/config.jsonc', 'tester'], {}, 'usage');
  assert.deepEqual(parsed.positionals, ['tester']);
  assert.equal(parsed.values.config, '/path/with spaces/config.jsonc');
});

test('account selects remote config and displays the exact hashed password once', async t => {
  const directory = await workspace(t);
  const output = join(directory, 'account.json');
  let hashed;
  let sql;
  const logs = [];
  await provisionAccount(['--out', output, 'Tester', '--remote', '--print-password'], accountDependencies({
    hashPassword: async password => { hashed = password; return 'fixture-hash'; },
    executeSql: async (value, options) => {
      sql = value;
      assert.equal(options.remote, true);
      assert.equal(options.config, '/private/wrangler.local.jsonc');
    },
    log: value => logs.push(value),
  }));
  assert.match(sql, /INSERT INTO user/);
  assert.ok(sql.includes('fixture-hash'));
  assert.ok(!sql.includes(hashed));
  assert.equal(logs.filter(value => value.includes(hashed)).length, 1);
  const metadata = await readFile(output, 'utf8');
  assert.ok(!metadata.includes(hashed));
  assert.ok(JSON.parse(metadata).userId);
  assert.equal((await stat(output)).mode & 0o777, 0o600);
});

test('unwritable metadata parent prevents account mutation', async t => {
  const directory = await workspace(t);
  const file = join(directory, 'file');
  await writeFile(file, 'not a directory');
  let mutated = false;
  await assert.rejects(provisionAccount(['tester', '--print-password', '--out', join(file, 'metadata')], accountDependencies({
    executeSql: async () => { mutated = true; },
  })));
  assert.equal(mutated, false);
});

test('metadata finalization failure cannot discard a provisioned password', async t => {
  const directory = await workspace(t);
  const output = join(directory, 'directory');
  await mkdir(output);
  const logs = [];
  await assert.rejects(provisionAccount(['tester', '--print-password', '--out', output], accountDependencies({
    log: value => logs.push(value),
  })), /Account changed and its password was displayed/);
  assert.match(logs[0], /^Generated password for tester: /);
});

test('reset refuses missing credentials and revokes sessions for the verified user', async t => {
  const directory = await workspace(t);
  const args = ['tester', '--reset', '--print-password', '--out', join(directory, 'metadata.json')];
  let mutations = 0;
  await assert.rejects(provisionAccount(args, accountDependencies({
    runD1: async () => [{ success: true, results: [] }],
    executeSql: async () => { mutations++; },
  })), /exactly one existing/);
  assert.equal(mutations, 0);
  await provisionAccount(args, accountDependencies({
    runD1: async (options, input) => {
      assert.equal(input[0], '--command');
      assert.match(input[1], /account.providerId='credential'/);
      return [{ success: true, results: [{ id: "fixture'user" }] }];
    },
    executeSql: async sql => {
      assert.match(sql, /DELETE FROM session WHERE userId='fixture''user'/);
      assert.match(sql, /UPDATE account SET password=/);
    },
  }));
});

test('Wrangler is bound to selected config and its failures never echo captured secrets', () => {
  const options = { remote: true, config: '/private/wrangler.local.jsonc' };
  const result = runD1(options, ['--file', '/temporary/private.sql'], (command, args, spawnOptions) => {
    assert.equal(command, process.execPath);
    assert.ok(args.includes('--remote'));
    assert.equal(args[args.indexOf('--config') + 1], options.config);
    assert.equal(args[args.indexOf('execute') + 1], 'DB');
    assert.deepEqual(spawnOptions.stdio, ['ignore', 'pipe', 'pipe']);
    assert.equal(spawnOptions.env.WRANGLER_LOG, 'log');
    assert.equal(spawnOptions.env.WRANGLER_WRITE_LOGS, 'false');
    return { status: 0, stdout: '[{"success":true,"results":[]}]' };
  });
  assert.equal(result[0].success, true);
  for (const response of [
    { status: 1, stdout: 'sensitive-fixture', stderr: 'sensitive-fixture' },
    { status: 0, stdout: 'sensitive-fixture' },
    { status: 0, stdout: '[{"success":false,"error":"sensitive-fixture"}]' },
  ]) {
    assert.throws(() => runD1(options, [], () => response), error => !error.message.includes('sensitive-fixture'));
  }
});

test('private SQL files have restrictive permissions and are cleaned up on failure', async () => {
  let path;
  await assert.rejects(executeSql('fixture SQL', {}, async (options, input) => {
    path = input[1];
    assert.equal((await stat(path)).mode & 0o777, 0o600);
    assert.equal(await readFile(path, 'utf8'), 'fixture SQL');
    throw new Error('fixture failure');
  }), /fixture failure/);
  await assert.rejects(stat(path), { code: 'ENOENT' });
});

test('config selection never silently falls back when private config is missing', async t => {
  const directory = await workspace(t);
  await assert.rejects(resolveConfig({ remote: true, config: join(directory, 'missing.jsonc') }), /private Wrangler config/);
  const path = join(directory, 'explicit.jsonc');
  await writeFile(path, '{}');
  assert.equal(await resolveConfig({ remote: true, config: path }), path);
  assert.match(await resolveConfig({}), /wrangler\.jsonc$/);
});

test('private JSON, YAML and transport parse errors redact source snippets', async t => {
  const directory = await workspace(t);
  const path = join(directory, 'invalid.json');
  await writeFile(path, '{"SUBSCRIPTION_URL":"sensitive-fixture" invalid}');
  await assert.rejects(readPrivateJson(path), error => !error.message.includes('sensitive-fixture'));
  for (const deps of [
    { parse: () => { throw new Error('sensitive-fixture'); } },
    { fetch: async () => { throw new Error('https://example.org/sensitive-fixture'); } },
    { readPrivateJson: async () => ({ SUBSCRIPTION_URL: 'invalid-sensitive-fixture' }) },
  ]) await assert.rejects(syncConfig(['private.json'], configDependencies(deps)), error => !error.message.includes('sensitive-fixture'));
});

test('HTTP subscriptions are rejected before any request or database mutation', async () => {
  let requests = 0;
  let mutations = 0;
  const logs = [];
  await assert.rejects(syncConfig(['private.json'], configDependencies({
    readPrivateJson: async () => ({ SUBSCRIPTION_URL: 'http://example.org/private?token=sensitive-fixture' }),
    fetch: async () => { requests++; },
    executeSql: async () => { mutations++; },
    log: value => logs.push(value),
  })), { message: 'SUBSCRIPTION_URL must be an HTTPS URL without embedded login credentials.' });
  assert.equal(requests, 0);
  assert.equal(mutations, 0);
  assert.deepEqual(logs, []);
});

test('subscription redirects fail without importing or exposing URLs and credentials', async () => {
  let requests = 0;
  let mutations = 0;
  let redirectMode;
  const logs = [];
  await assert.rejects(syncConfig(['private.json'], configDependencies({
    fetch: async (url, options) => {
      requests++;
      redirectMode = options.redirect;
      throw new TypeError(`Redirect from ${url} to http://other.example.org/private?token=sensitive-fixture`);
    },
    executeSql: async () => { mutations++; },
    log: value => logs.push(value),
  })), { message: 'Could not download the subscription. Check its URL, connectivity, and the 30-second timeout.' });
  assert.equal(requests, 1);
  assert.equal(redirectMode, 'error');
  assert.equal(mutations, 0);
  assert.deepEqual(logs, []);
});

test('configuration import validates scope, source shape and SQL byte budget before mutation', async () => {
  let mutations = 0;
  const base = { executeSql: async () => { mutations++; } };
  for (const args of [
    ['private.json', '--scope=user'], ['private.json', '--scope=other'],
    ['private.json', '--scope-key=unexpected'], ['private.json', '--scope=group', '--scope-key=  '],
  ]) await assert.rejects(syncConfig(args, configDependencies(base)));
  for (const config of [null, [], { proxies: [] }, { 'proxy-providers': 'invalid' }, { 'proxy-providers': [] }]) {
    await assert.rejects(syncConfig(['private.json'], configDependencies({ ...base, parse: () => config })), /Expected a Clash/);
  }
  await assert.rejects(syncConfig(['private.json'], configDependencies({
    ...base, fetch: async () => new Response('x'.repeat(90_001)),
  })), /90 KB/);
  await assert.rejects(syncConfig(['private.json'], configDependencies({
    ...base, fetch: async () => new Response("'".repeat(60_000)),
  })), /SQL import limit/);
  assert.equal(mutations, 0);
});

test('valid configuration is quoted and forwarded to the selected database scope', async () => {
  await syncConfig(['private.json', '--remote', '--scope=user', "--scope-key=fixture'user"], configDependencies({
    fetch: async (url, options) => {
      assert.equal(url.protocol, 'https:');
      assert.equal(options.redirect, 'error');
      return new Response("proxies:\n  - name: 'fixture'\n");
    },
    executeSql: async (sql, options) => {
      assert.ok(sql.includes("fixture''user"));
      assert.ok(sql.includes("''fixture''"));
      assert.equal(options.config, '/private/wrangler.local.jsonc');
      assert.equal(options.remote, true);
    },
  }));
});
