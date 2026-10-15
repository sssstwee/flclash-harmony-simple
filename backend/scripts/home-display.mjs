import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HOME_DISPLAY_KEY, parseHomeDisplay } from '../src/home_display.mjs';
import { backendDirectory, isMain, parseOptions, resolveConfig, runCli } from './operations.mjs';

export async function publishHomeDisplay(args, dependencies = {}) {
  const { values, positionals } = parseOptions(args, {}, 'Usage: npm run home:publish -- HOME_JSON [--remote|--local] [--config PATH]');
  const content = JSON.stringify(parseHomeDisplay(await readFile(positionals[0], 'utf8')));
  const config = await (dependencies.resolveConfig ?? resolveConfig)(values);
  const directory = await mkdtemp(join(tmpdir(), 'cc-home-display-'));
  try {
    const path = join(directory, 'home.json');
    await writeFile(path, content);
    const result = (dependencies.run ?? spawnSync)(process.execPath, [
      join(backendDirectory, 'node_modules/wrangler/bin/wrangler.js'),
      'kv', 'key', 'put', HOME_DISPLAY_KEY, '--path', path,
      '--binding', 'CONFIGS', '--config', config, values.remote ? '--remote' : '--local',
    ], { cwd: backendDirectory, stdio: 'pipe', encoding: 'utf8' });
    if (result.error || result.status !== 0) throw new Error('Home display publish failed; verify Cloudflare access and the CONFIGS binding');
    (dependencies.log ?? console.log)(`Home display published (${Buffer.byteLength(content)} bytes, ${values.remote ? 'remote' : 'local'}).`);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

if (isMain(import.meta.url)) await runCli(publishHomeDisplay);
