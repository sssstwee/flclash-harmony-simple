import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const scannerSource = fileURLToPath(new URL('../../../.github/scripts/check-no-secrets.sh', import.meta.url));

function git(directory, ...args) {
  const result = spawnSync('git', args, { cwd: directory, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'harmony-scanner-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  git(directory, 'init', '--quiet');
  await mkdir(join(directory, '.github/scripts'), { recursive: true });
  await copyFile(scannerSource, join(directory, '.github/scripts/check-no-secrets.sh'));
  git(directory, 'add', '.');
  return directory;
}

async function stage(directory, path, content) {
  await mkdir(dirname(join(directory, path)), { recursive: true });
  await writeFile(join(directory, path), content);
  git(directory, 'add', '--force', '--', path);
}

function scan(directory) {
  const result = spawnSync('bash', ['.github/scripts/check-no-secrets.sh'], { cwd: directory, encoding: 'utf8' });
  return { ...result, output: `${result.stdout}${result.stderr}` };
}

test('scanner accepts placeholders and ignores untracked private local files', async t => {
  const directory = await fixture(t);
  await stage(directory, 'backend/wrangler.jsonc', '{"database_id":"00000000-0000-0000-0000-000000000000"}');
  await stage(directory, 'backend/wrangler.local.jsonc.example', '{"database_id":"YOUR-D1-DATABASE-UUID"}');
  await writeFile(join(directory, 'private.secrets.json'), 'tokenfor' + 'sell');
  assert.equal(scan(directory).status, 0);
});

test('scanner checks hidden files and never echoes matching secret lines', async t => {
  const directory = await fixture(t);
  const secret = 'tokenfor' + 'sell';
  await stage(directory, '.github/workflows/hidden.yml', `sensitive-companion-value ${secret}`);
  const result = scan(directory);
  assert.equal(result.status, 1);
  assert.ok(result.output.includes('.github/workflows/hidden.yml'));
  assert.ok(!result.output.includes(secret));
  assert.ok(!result.output.includes('sensitive-companion-value'));
});

test('scanner checks force-added ignored files and staged content rather than sanitized working copy', async t => {
  const directory = await fixture(t);
  await stage(directory, '.gitignore', 'ignored.txt\n');
  await stage(directory, 'ignored.txt', 'tokenfor' + 'sell');
  await writeFile(join(directory, 'ignored.txt'), 'clean working tree copy');
  const result = scan(directory);
  assert.equal(result.status, 1);
  assert.ok(result.output.includes('ignored.txt'));
});

test('scanner rejects tracked private config even without a recognizable secret', async t => {
  const directory = await fixture(t);
  await stage(directory, 'backend/.dev.vars', 'SOME_PRIVATE_VALUE=fixture');
  const result = scan(directory);
  assert.equal(result.status, 1);
  assert.ok(result.output.includes('private configuration file'));
  assert.ok(!result.output.includes('SOME_PRIVATE_VALUE'));
});

test('scanner detects uppercase compact D1 identifiers and examples with real IDs', async t => {
  for (const name of ['backend/wrangler.jsonc', 'backend/wrangler.local.jsonc.example']) {
    const directory = await fixture(t);
    const uuid = ['AAAAAAAA', 'BBBB', 'CCCC', 'DDDD', 'EEEEEEEEEEEE'].join('-');
    await stage(directory, name, `{"database_id":"${uuid}"}`);
    const result = scan(directory);
    assert.equal(result.status, 1);
    assert.ok(result.output.includes('non-placeholder D1'));
    assert.ok(!result.output.includes(uuid));
  }
});

test('scanner detects nested deployment hosts and handles unusual tracked filenames', async t => {
  const directory = await fixture(t);
  const hostname = ['https://worker', 'account', 'workers', 'dev'].join('.');
  await stage(directory, 'path with spaces\nand newline.txt', hostname);
  const result = scan(directory);
  assert.equal(result.status, 1);
  assert.ok(result.output.includes('deployment-specific'));
  assert.ok(!result.output.includes(hostname));
});

test('scanner rejects proxy URIs in sources but permits test fixtures', async t => {
  const directory = await fixture(t);
  const uri = ['trojan', '//fixture@example.org:443'].join(':');
  await stage(directory, 'backend/test/fixture.txt', uri);
  assert.equal(scan(directory).status, 0);
  await stage(directory, 'lib/leak.txt', uri);
  const result = scan(directory);
  assert.equal(result.status, 1);
  assert.ok(result.output.includes('proxy URI'));
  assert.ok(!result.output.includes(uri));
});

test('scanner fails closed outside a Git checkout', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'harmony-scanner-nongit-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, '.github/scripts'), { recursive: true });
  await copyFile(scannerSource, join(directory, '.github/scripts/check-no-secrets.sh'));
  assert.equal(scan(directory).status, 1);
});
