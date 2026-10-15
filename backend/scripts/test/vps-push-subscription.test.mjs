import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, chmod, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('push script reads private token file and keeps credential off curl argv', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'push-test-'));
  try {
    const tokenFile = join(directory, 'token');
    const capture = join(directory, 'capture');
    await writeFile(tokenFile, 'fixture-secret\n', { mode: 0o600 });
    await writeFile(join(directory, 'curl'), '#!/bin/bash\ncat > "$CAPTURE"\nprintf "%s\\n" "$@" > "$CAPTURE.args"\n', { mode: 0o700 });
    const env = {
      PATH: directory + ':' + process.env.PATH, CAPTURE: capture,
      SUBSCRIPTION_FILE: '/tmp/input.yaml', SUBSCRIPTION_PUSH_URL: 'https://example.org/v1/admin/subscription',
      SUBSCRIPTION_PUSH_TOKEN_FILE: tokenFile,
    };
    const run = () => spawnSync('bash', ['scripts/vps-push-subscription.sh'], { env, encoding: 'utf8' });
    const result = run();
    assert.equal(result.status, 0, result.stderr);
    assert.match(await readFile(capture, 'utf8'), /Authorization: Bearer fixture-secret/);
    assert.doesNotMatch(await readFile(capture + '.args', 'utf8'), /fixture-secret/);
    assert.doesNotMatch(result.stdout + result.stderr, /fixture-secret/);
    await chmod(tokenFile, 0o644);
    assert.notEqual(run().status, 0);
    await chmod(tokenFile, 0o600);
    env.SUBSCRIPTION_PUSH_URL = 'http://example.org/';
    assert.notEqual(run().status, 0);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
