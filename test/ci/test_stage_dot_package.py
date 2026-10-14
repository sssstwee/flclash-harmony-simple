import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock
import zipfile

SCRIPT = Path(__file__).resolve().parents[2] / '.github/scripts/stage-dot-package.py'
SPEC = importlib.util.spec_from_file_location('stage_dot_package', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class StageDotPackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {
            'EXPECTED_SHA': 'a' * 40,
            'SOURCE_SHA': 'a' * 40,
            'GITHUB_REPOSITORY': 'sssstwee/flclash-harmony-simple',
            'GITHUB_REPOSITORY_ID': MODULE.REPOSITORY_ID,
            'SOURCE_REF': f'refs/heads/{MODULE.BRANCH}',
            'VALIDATION_RUN_ID': '111',
            'GITHUB_RUN_ID': '222',
            'VALIDATION_ATTEMPT': '1',
            'PACKAGE_ATTEMPT': '1',
            'GITHUB_RUN_ATTEMPT': '1',
            'FLUTTER_OHOS_SHA': 'b' * 40,
            'OHOS_GO_SHA': 'c' * 40,
        }
        self.raw = {
            'hap': self.root / 'ohos/entry/build/default/outputs/default/entry-default-unsigned.hap',
            'app': self.root / 'ohos/build/outputs/default/ohos-default-unsigned.app',
        }
        (self.root / 'dist').mkdir()
        for extension, raw in self.raw.items():
            raw.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(raw, 'w') as archive:
                archive.writestr('module.json', '{"test":"mock unsigned fixture"}')
            shutil.copyfile(raw, self.root / 'dist' / f'xiaomao-ai-proxy-0.8.94-ohos.{extension}')

    def run_stage(self):
        return MODULE.stage(self.root, self.env)

    def assert_rejected(self):
        with self.assertRaises((ValueError, OSError)):
            self.run_stage()
        self.assertFalse((self.root / 'dot-package').exists())
        self.assertEqual(list(self.root.glob('.dot-package-*')), [])

    def test_valid_packages_provenance_and_checksums(self):
        output = self.run_stage()
        names = {path.name for path in output.iterdir()}
        self.assertEqual(names, {
            'xiaomao-ai-proxy-aaaaaaaaaaaa-unsigned.hap',
            'xiaomao-ai-proxy-aaaaaaaaaaaa-unsigned.app',
            'BUILD-INFO.json', 'README.txt', 'SHA256SUMS',
        })
        info = json.loads((output / 'BUILD-INFO.json').read_text())
        self.assertEqual(info['commit'], 'a' * 40)
        self.assertEqual(info['validation_run_id'], '111')
        self.assertIn('--no-codesign', info['signing'])
        self.assertNotIn('CLASH_HARMONY_API_URL', info)
        checksums = (output / 'SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(checksums), 4)
        for line in checksums:
            expected, name = line.split('  ', 1)
            self.assertEqual(MODULE.digest(output / name), expected)
        for file in info['files']:
            self.assertEqual(file['sha256'], MODULE.digest(output / file['name']))
            self.assertEqual(file['bytes'], (output / file['name']).stat().st_size)
            self.assertEqual(file['sha256'], MODULE.digest(self.root / file['source_path']))

    def test_rejects_wrong_identity_and_incomplete_provenance(self):
        for key in list(self.env):
            with self.subTest(key=key):
                saved = self.env.pop(key)
                self.assert_rejected()
                self.env[key] = saved

    def test_accepts_renamed_repository_with_same_identity(self):
        self.env['GITHUB_REPOSITORY'] = 'sssstwee/xiaomao-ai-proxy'
        output = self.run_stage()
        info = json.loads((output / 'BUILD-INFO.json').read_text())
        self.assertEqual(info['repository'], self.env['GITHUB_REPOSITORY'])
        self.assertEqual(info['repository_id'], MODULE.REPOSITORY_ID)
        self.assertEqual(info['app_name'], '小猫AI代理')

    def test_rejects_recreated_repository(self):
        self.env['GITHUB_REPOSITORY_ID'] = '999999999'
        self.assert_rejected()

    def test_rejects_wrong_branch(self):
        self.env['SOURCE_REF'] = 'refs/heads/cursor/parallel'
        self.assert_rejected()

    def test_rejects_sha_mismatch(self):
        self.env['SOURCE_SHA'] = 'd' * 40
        self.assert_rejected()

    def test_rejects_same_validation_and_package_run(self):
        self.env['VALIDATION_RUN_ID'] = self.env['GITHUB_RUN_ID']
        self.assert_rejected()

    def test_accepts_same_run_later_attempt_with_explicit_source(self):
        self.env['VALIDATION_RUN_ID'] = self.env['GITHUB_RUN_ID']
        self.env['PACKAGE_ATTEMPT'] = '2'
        self.env['GITHUB_RUN_ATTEMPT'] = '2'
        self.env['GITHUB_SHA'] = 'f' * 40
        self.env['GITHUB_REF'] = 'refs/pull/4/merge'
        output = self.run_stage()
        info = json.loads((output / 'BUILD-INFO.json').read_text())
        self.assertEqual(info['commit'], 'a' * 40)
        self.assertEqual(info['validation_run_id'], info['package_run_id'])
        self.assertEqual(info['validation_attempt'], '1')
        self.assertEqual(info['package_attempt'], '2')

    def test_rejects_same_run_second_attempt_as_validation(self):
        self.env['VALIDATION_RUN_ID'] = self.env['GITHUB_RUN_ID']
        self.env['VALIDATION_ATTEMPT'] = '2'
        self.env['PACKAGE_ATTEMPT'] = '3'
        self.env['GITHUB_RUN_ATTEMPT'] = '3'
        self.assert_rejected()

    def test_rejects_attempt_mismatch(self):
        self.env['PACKAGE_ATTEMPT'] = '2'
        self.assert_rejected()

    def test_rejects_malformed_attempts(self):
        for key in ['VALIDATION_ATTEMPT', 'PACKAGE_ATTEMPT', 'GITHUB_RUN_ATTEMPT']:
            for value in ['0', '-1', '1.5', '2junk', '01']:
                with self.subTest(key=key, value=value):
                    original = self.env[key]
                    self.env[key] = value
                    self.assert_rejected()
                    self.env[key] = original

    def test_does_not_fallback_to_raw_github_merge_source(self):
        del self.env['SOURCE_SHA']
        self.env['GITHUB_SHA'] = 'a' * 40
        self.assert_rejected()

    def test_rejects_missing_unsigned_source(self):
        self.raw['hap'].unlink()
        self.assert_rejected()

    def test_rejects_signed_name_only(self):
        raw = self.raw['hap']
        raw.rename(raw.with_name('entry-default-signed.hap'))
        self.assert_rejected()

    def test_accepts_final_raw_outputs_without_distributor_directory(self):
        shutil.rmtree(self.root / 'dist')
        output = self.run_stage()
        for extension, raw in self.raw.items():
            staged = output / f'xiaomao-ai-proxy-aaaaaaaaaaaa-unsigned.{extension}'
            self.assertEqual(MODULE.digest(staged), MODULE.digest(raw))

    def test_ignores_unrelated_distributor_outputs(self):
        (self.root / 'dist/stale.hap').write_bytes(b'unrelated package')
        (self.root / 'dist/xiaomao-ai-proxy-0.8.94-ohos.app').write_bytes(b'stale app copy')
        output = self.run_stage()
        self.assertNotIn('stale.hap', {path.name for path in output.iterdir()})
        staged = output / 'xiaomao-ai-proxy-aaaaaaaaaaaa-unsigned.app'
        self.assertEqual(MODULE.digest(staged), MODULE.digest(self.raw['app']))

    def test_stages_final_regenerated_hap_instead_of_stale_distributor_copy(self):
        early_hap = self.root / 'dist/xiaomao-ai-proxy-0.8.94-ohos.hap'
        earlier_digest = MODULE.digest(early_hap)
        # The later APP target regenerates raw HAP; dist still holds target one's copy.
        with zipfile.ZipFile(self.raw['hap'], 'w') as archive:
            archive.writestr('module.json', '{"test":"final HAP after APP assembly"}')
        output = self.run_stage()
        staged = output / 'xiaomao-ai-proxy-aaaaaaaaaaaa-unsigned.hap'
        self.assertEqual(MODULE.digest(staged), MODULE.digest(self.raw['hap']))
        self.assertNotEqual(MODULE.digest(staged), earlier_digest)
        self.assertEqual(MODULE.digest(early_hap), earlier_digest)
        info = json.loads((output / 'BUILD-INFO.json').read_text())
        hap_info = next(file for file in info['files'] if file['name'].endswith('.hap'))
        self.assertEqual(hap_info['source_path'], self.raw['hap'].relative_to(self.root).as_posix())
        self.assertEqual(hap_info['sha256'], MODULE.digest(staged))

    def test_rejects_empty_package(self):
        self.raw['hap'].write_bytes(b'')
        self.assert_rejected()

    def test_rejects_non_zip_package(self):
        self.raw['hap'].write_bytes(b'not a package')
        self.assert_rejected()

    def test_rejects_empty_zip(self):
        with zipfile.ZipFile(self.raw['hap'], 'w'):
            pass
        self.assert_rejected()

    def test_rejects_symlink_input(self):
        source = self.raw['hap']
        source.unlink()
        source.symlink_to(self.root / 'dist/xiaomao-ai-proxy-0.8.94-ohos.hap')
        self.assert_rejected()

    def test_rejects_corrupt_raw_crc_despite_valid_distributor_copy(self):
        raw = self.raw['hap']
        data = raw.read_bytes()
        self.assertIn(b'mock unsigned fixture', data)
        raw.write_bytes(data.replace(b'mock unsigned fixture', b'bad! unsigned fixture', 1))
        self.assert_rejected()

    def test_rejects_invalid_final_app_despite_valid_distributor_copy(self):
        self.raw['app'].write_bytes(b'not a valid final APP archive')
        self.assert_rejected()

    def test_rejects_missing_final_app_despite_valid_distributor_copy(self):
        self.raw['app'].unlink()
        self.assert_rejected()

    def test_atomic_staging_removes_partial_output_after_copy_failure(self):
        with mock.patch.object(MODULE.shutil, 'copyfile', side_effect=OSError('copy failed')):
            self.assert_rejected()

    def test_refuses_to_overwrite_output(self):
        output = self.run_stage()
        original = (output / 'BUILD-INFO.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            self.run_stage()
        self.assertEqual((output / 'BUILD-INFO.json').read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
