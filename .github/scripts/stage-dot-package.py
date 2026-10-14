#!/usr/bin/env python3
"""Stage this dot branch's final unsigned HAP/APP build outputs, with provenance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import zipfile

REPOSITORY = 'sssstwee/flclash-harmony-simple'
BRANCH = 'dot/harmony-auto-adapt-20261014-0519'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def required(env, key, pattern):
    value = env.get(key, '')
    if not re.fullmatch(pattern, value):
        raise ValueError(f'Missing or invalid {key}')
    return value


def stage(root, env):
    root = Path(root)
    sha = required(env, 'EXPECTED_SHA', r'[a-f0-9]{40}')
    if env.get('SOURCE_SHA') != sha or env.get('GITHUB_REPOSITORY') != REPOSITORY:
        raise ValueError('Repository or run SHA does not match isolated packaging')
    if env.get('SOURCE_REF') != f'refs/heads/{BRANCH}':
        raise ValueError('Only the exact dot branch can stage packages')
    validation_run = required(env, 'VALIDATION_RUN_ID', r'[1-9][0-9]*')
    package_run = required(env, 'GITHUB_RUN_ID', r'[1-9][0-9]*')
    validation_attempt = required(env, 'VALIDATION_ATTEMPT', r'[1-9][0-9]*')
    package_attempt = required(env, 'PACKAGE_ATTEMPT', r'[1-9][0-9]*')
    actual_attempt = required(env, 'GITHUB_RUN_ATTEMPT', r'[1-9][0-9]*')
    if package_attempt != actual_attempt:
        raise ValueError('Package attempt does not match the current workflow attempt')
    if package_run == validation_run and (validation_attempt != '1' or int(package_attempt) <= 1):
        raise ValueError('Same-run packaging requires a validated first attempt and a later package attempt')
    flutter = required(env, 'FLUTTER_OHOS_SHA', r'[a-f0-9]{40}')
    ohos_go = required(env, 'OHOS_GO_SHA', r'[a-f0-9]{40}')
    destination = root / 'dot-package'
    if destination.exists() or destination.is_symlink():
        raise ValueError('Refusing to overwrite an existing package directory')
    pairs = [
        ('hap', root / 'ohos/entry/build/default/outputs/default/entry-default-unsigned.hap'),
        ('app', root / 'ohos/build/outputs/default/ohos-default-unsigned.app'),
    ]
    validated = []
    # APP assembly can regenerate HAP after the distributor copied its first HAP
    # into dist/. Collect the authoritative final unsigned outputs after both
    # targets finish, rather than comparing against that stale intermediate copy.
    for extension, raw in pairs:
        if raw.is_symlink() or not raw.is_file() or raw.stat().st_size == 0:
            raise ValueError(f'Expected a nonempty final unsigned {extension} output')
        try:
            with zipfile.ZipFile(raw) as archive:
                if not archive.namelist() or archive.testzip() is not None:
                    raise ValueError(f'Invalid {extension} archive contents')
        except zipfile.BadZipFile as error:
            raise ValueError(f'Invalid {extension} archive') from error
        checksum = digest(raw)
        validated.append((extension, raw, checksum))

    staging = Path(tempfile.mkdtemp(prefix='.dot-package-', dir=root))
    try:
        files = []
        for extension, source, checksum in validated:
            output = staging / f'dot-harmony-auto-adapt-{sha[:12]}-unsigned.{extension}'
            shutil.copyfile(source, output)
            if digest(output) != checksum:
                raise ValueError(f'{extension} changed while staging')
            files.append({
                'name': output.name,
                'source_path': source.relative_to(root).as_posix(),
                'sha256': checksum,
                'bytes': output.stat().st_size,
            })
        metadata = {
            'repository': REPOSITORY,
            'branch': BRANCH,
            'commit': sha,
            'signing': 'unsigned; --no-codesign; no signing credential used',
            'targets': ['hap', 'app'],
            'target_architecture': 'arm64-v8a',
            'validation_run_id': validation_run,
            'validation_attempt': validation_attempt,
            'package_run_id': package_run,
            'package_attempt': package_attempt,
            'flutter_ohos_sha': flutter,
            'ohos_go_sha': ohos_go,
            'files': files,
        }
        (staging / 'BUILD-INFO.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
        (staging / 'README.txt').write_text(
            'Unsigned HarmonyOS build. Not directly installable.\n'
            'No device, VPN, backend, signing or deployment changes were performed.\n'
            'Device compatibility and real-network recovery remain unverified.\n',
            encoding='utf-8',
        )
        with (staging / 'SHA256SUMS').open('w', encoding='utf-8') as stream:
            for output in sorted(staging.iterdir()):
                if output.name != 'SHA256SUMS':
                    stream.write(f'{digest(output)}  {output.name}\n')
        staging.rename(destination)
    except BaseException:
        shutil.rmtree(staging)
        raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('.'))
    args = parser.parse_args()
    try:
        output = stage(args.root, os.environ)
    except (ValueError, OSError) as error:
        parser.exit(1, f'Package staging failed: {error}\n')
    print(f'Staged verified unsigned packages in {output}')


if __name__ == '__main__':
    main()
