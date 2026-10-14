#!/usr/bin/env bash
# Scan the Git index, including hidden files and force-added ignored files.
# Report paths and rule names only; never print matching secret values or lines.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
command -v git >/dev/null || { echo 'check-no-secrets: git is required' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'check-no-secrets: python3 is required' >&2; exit 1; }

python3 - <<'PY'
import hashlib
import pathlib
import re
import subprocess
import sys


def fail(message):
    print(f'check-no-secrets: {message}', file=sys.stderr)
    raise SystemExit(1)


def git(*args):
    result = subprocess.run(['git', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        fail('could not read the Git index; scan did not complete')
    return result.stdout


root = pathlib.Path(git('rev-parse', '--show-toplevel').decode().strip()).resolve()
if root != pathlib.Path.cwd().resolve():
    fail('run this script from its own Git checkout')

entries = git('ls-files', '--stage', '-z').split(b'\0')
files = []
for entry in entries:
    if not entry:
        continue
    info, path = entry.split(b'\t', 1)
    mode, oid, stage = info.split()
    if stage != b'0':
        fail('unmerged files prevent a complete scan')
    # Gitlinks refer to another repository. Large upstream geodata is not source text.
    if mode == b'160000' or path.rsplit(b'/', 1)[-1] in (b'GEOSITE.dat', b'GEOIP.dat'):
        continue
    if path == b'.github/scripts/check-no-secrets.sh':
        continue
    files.append((oid, path))

uuid = re.compile(rb'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', re.I)
host = re.compile(rb'https?://(?:[a-z0-9-]+\.)+(?:workers|pages)\.dev\b', re.I)
database_id = re.compile(rb'[\"\']?database_id[\"\']?\s*[:=]\s*[\"\']([^\"\']+)[\"\']', re.I)
proxy_uri = re.compile(rb'(?:ss|vmess|trojan)://', re.I)
leaked_d1_hash = '1c446b78d3d383b101f11be506a5817e398b263157e402093ac02ccc0b198f21'
issues = []
reader = subprocess.Popen(['git', 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
try:
    for oid, raw_path in files:
        reader.stdin.write(oid + b'\n')
        reader.stdin.flush()
        header = reader.stdout.readline().split()
        if len(header) != 3 or header[1] != b'blob':
            fail('could not read a tracked file; scan did not complete')
        size = int(header[2])
        content = reader.stdout.read(size)
        if len(content) != size or reader.stdout.read(1) != b'\n':
            fail('incomplete tracked file; scan did not complete')
        path = raw_path.decode('utf-8', 'backslashreplace')
        name = path.rsplit('/', 1)[-1]
        reasons = []
        # A tracked private config is a leak risk even if it happens to match no pattern.
        is_example = name.endswith(('.example', '.example.json'))
        if not is_example and (
            path in ('env.json', 'env.local.json', 'backend/wrangler.local.jsonc')
            or (path.startswith('backend/') and name.startswith(('.env', '.dev.vars')))
            or name.endswith('.secrets.json')
            or (name.startswith('private-config') and name.endswith('.json'))
        ):
            reasons.append('private configuration file must not be tracked')
        if b'tokenforsell' in content.lower():
            reasons.append('known leaked hostname fragment')
        if host.search(content):
            reasons.append('deployment-specific Workers/Pages URL')
        if name.startswith('wrangler') and name.endswith(('.json', '.jsonc', '.toml', '.json.example', '.jsonc.example', '.toml.example')):
            for match in database_id.finditer(content):
                if match[1].lower() not in (b'00000000-0000-0000-0000-000000000000', b'your-d1-database-uuid'):
                    reasons.append('non-placeholder D1 database identifier')
                    break
        if any(hashlib.sha256(value.lower()).hexdigest() == leaked_d1_hash for value in uuid.findall(content)):
            reasons.append('rotated D1 database identifier fingerprint')
        # Test fixtures may contain protocol examples; all other tracked files are checked.
        is_test = path.startswith(('test/', 'backend/test/', 'backend/scripts/test/'))
        if not is_test and proxy_uri.search(content):
            reasons.append('proxy URI outside test fixtures')
        issues.extend((path, reason) for reason in reasons)
    reader.stdin.close()
    if reader.wait() != 0:
        fail('Git object reader failed; scan did not complete')
finally:
    if reader.poll() is None:
        reader.kill()
        reader.wait()

if issues:
    for path, reason in issues:
        print(f'check-no-secrets: {path!r}: {reason}', file=sys.stderr)
    raise SystemExit(1)
print(f'check-no-secrets: OK ({len(files)} tracked files checked)')
PY
