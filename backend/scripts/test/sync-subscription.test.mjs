import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, rm, stat } from 'node:fs/promises';
import { dirname } from 'node:path';
import { test } from 'node:test';
import { syncSubscription } from '../sync-subscription.mjs';

const yaml = 'proxies: [{name: fixture}]\nproxy-groups: [{name: auto, type: select, proxies: [fixture]}]\n';
const deps = overrides => ({
  env: { SUBSCRIPTION_URL: 'https://example.org/fixture' },
  resolveConfig: async () => '/fixture/config.jsonc',
  fetch: async () => new Response(yaml),
  runD1: async () => [{ results: [{ content: 'old', updated_at: 'before' }] }],
  log: () => {},
  ...overrides,
});

test('dry run prints matching backend versions without mutation or backup', async () => {
  const logs = [];
  await syncSubscription(['--dry-run'], deps({
    log: line => logs.push(line),
    executeSql: async () => assert.fail('unexpected write'),
  }));
  const hash = value => createHash('sha256').update(JSON.stringify(['default', '', value])).digest('hex').slice(0, 16);
  assert.deepEqual(logs, [`old version: ${hash('old')}; new version: ${hash(yaml)}`]);
});

test('backup exists with private permissions before scoped write', async t => {
  let backup;
  t.after(async () => { if (backup) await rm(dirname(backup), { recursive: true }); });
  await syncSubscription(['--scope', 'user', '--key', "fixture'user"], deps({
    log: line => { if (line.startsWith('Backup: ')) backup = line.slice(8); },
    runD1: async (options, input) => {
      assert.match(input[1], /scope_key='fixture''user'/);
      assert.ok(!options.remote);
      return [{ results: [{ content: 'old' }] }];
    },
    executeSql: async sql => {
      assert.equal((await stat(backup)).mode & 0o777, 0o600);
      assert.equal(JSON.parse(await readFile(backup, 'utf8')).row.content, 'old');
      assert.match(sql, /fixture''user/);
    },
  }));
});

test('invalid YAML, missing groups, and rule providers/sets never reach storage', async () => {
  for (const content of ['[invalid', 'proxies: [x]', yaml + 'rule-providers: {}\n', yaml + 'rules: ["RULE-SET,test,DIRECT"]\n']) {
    await assert.rejects(syncSubscription([], deps({
      fetch: async () => new Response(content),
      runD1: async () => assert.fail('unexpected read'),
    })));
  }
});
