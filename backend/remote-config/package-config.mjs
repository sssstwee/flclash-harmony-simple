// node package-config.mjs payload.example.json 2026-10-14.2 0.8.94+2026101206 > config.json
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
const [path, version, minClientVersion] = process.argv.slice(2);
if (!path || !version || !minClientVersion) throw new Error('payload path, version and minimum client version required');
const payload = JSON.stringify(JSON.parse(readFileSync(path, 'utf8')));
process.stdout.write(JSON.stringify({ schemaVersion: 1, version, minClientVersion,
  sha256: createHash('sha256').update(payload, 'utf8').digest('hex'), payload }, null, 2));
