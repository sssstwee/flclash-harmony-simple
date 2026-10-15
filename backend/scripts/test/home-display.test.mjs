import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { publishHomeDisplay } from '../home-display.mjs';

test('publisher validates JSON and uploads only display data using the existing KV binding', async () => {
  let uploaded;
  await publishHomeDisplay(['homepage/home.json', '--remote'], {
    resolveConfig: async () => '/private/wrangler.jsonc',
    run: (_node, args) => {
      assert.ok(args.includes('ui:home'));
      assert.ok(args.includes('--remote'));
      assert.ok(args.includes('CONFIGS'));
      uploaded = args[args.indexOf('--path') + 1];
      return { status: 0 };
    },
    log() {},
  });
  await assert.rejects(readFile(uploaded), { code: 'ENOENT' });
});

test('publisher rejects invalid JSON before contacting Cloudflare', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cc-home-test-'));
  try {
    const path = join(directory, 'bad.json');
    await writeFile(path, JSON.stringify({ schemaVersion: 1, home: { sections: ['traffic'] } }));
    let contacted = false;
    await assert.rejects(publishHomeDisplay([path, '--remote'], {
      run: () => { contacted = true; return { status: 0 }; },
    }), /Invalid home display/);
    assert.equal(contacted, false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
