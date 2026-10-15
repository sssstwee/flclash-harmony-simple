import { readFileSync, writeFileSync } from 'node:fs';

const source = new URL('../backend/routing-policy.json', import.meta.url);
const destination = new URL('../lib/common/generated/routing_policy.g.dart', import.meta.url);
const policy = JSON.parse(readFileSync(source, 'utf8'));
const quote = value => `'${value.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('$', '\\$')}'`;
const dart = value => {
  if (typeof value === 'string') return quote(value);
  if (Array.isArray(value)) return `[\n${value.map(item => `    ${dart(item)},`).join('\n')}\n  ]`;
  if (value && typeof value === 'object') return `{\n${Object.entries(value).map(([key, item]) => `  ${quote(key)}: ${dart(item)},`).join('\n')}\n}`;
  return JSON.stringify(value);
};
const generated = `// GENERATED CODE - DO NOT MODIFY BY HAND\n// Source: backend/routing-policy.json; node tool/generate_routing_policy.mjs\n\nconst routingPolicy = ${dart(policy)};\n`;
if (process.argv.includes('--check')) {
  if (readFileSync(destination, 'utf8') !== generated) throw new Error('Regenerate routing policy with node tool/generate_routing_policy.mjs');
} else {
  writeFileSync(destination, generated);
}
