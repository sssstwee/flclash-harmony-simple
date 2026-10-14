"""Check display branding without changing stable upgrade or runtime identities."""
import json
from pathlib import Path
import plistlib
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
BRAND = '小猫AI代理'


def read(path):
    return (ROOT / path).read_text(encoding='utf-8')


class BrandingTest(unittest.TestCase):
    def test_flutter_display_is_separate_from_runtime_identity(self):
        source = read('lib/common/constant.dart')
        self.assertIn(f"const appDisplayName = '{BRAND}';", source)
        self.assertIn("const appName = 'FlClash';", source)
        self.assertIn("const packageName = 'com.follow.clash';", source)
        for path in ['lib/application.dart', 'lib/views/about.dart',
                     'lib/views/dashboard/simple.dart', 'lib/common/tray.dart',
                     'lib/manager/window_manager.dart']:
            with self.subTest(path=path):
                self.assertIn('appDisplayName', read(path))
        self.assertIn("name: fl_clash\n", read('pubspec.yaml'))

    def test_harmony_launcher_widget_and_notification_brand(self):
        resource = json.loads(read('ohos/AppScope/resources/base/element/string.json'))
        names = {item['name']: item['value'] for item in resource['string']}
        self.assertEqual(names['app_name'], BRAND)
        self.assertIn('"bundleName": "com.follow.clash.simple"', read('ohos/AppScope/app.json5'))
        self.assertIn(f'currentProfileName: string = "{BRAND}"',
                      read('ohos/entry/src/main/ets/models/State.ets'))
        self.assertIn(f"this.title = '{BRAND}'",
                      read('ohos/entry/src/main/ets/widget/pages/WidgetCard.ets'))

    def test_android_display_and_vpn_name(self):
        namespace = '{http://schemas.android.com/apk/res/android}'
        for path in ['android/app/src/main/AndroidManifest.xml',
                     'android/app/src/debug/AndroidManifest.xml']:
            manifest = ET.fromstring(read(path))
            labels = [node.get(namespace + 'label') for node in manifest.iter()
                      if node.get(namespace + 'label') is not None]
            self.assertTrue(labels)
            self.assertTrue(all(label.startswith(BRAND) for label in labels))
        self.assertIn(f'setSession("{BRAND}")',
                      read('android/service/src/main/java/com/follow/clash/service/VpnService.kt'))

    def test_desktop_display_preserves_executable_identity(self):
        info = plistlib.loads((ROOT / 'macos/Runner/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleDisplayName'], BRAND)
        self.assertEqual(info['CFBundleName'], BRAND)
        self.assertEqual(info['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
        self.assertIn('PRODUCT_NAME = FlClash', read('macos/Runner/Configs/AppInfo.xcconfig'))
        self.assertIn(f'VALUE "FileDescription", "{BRAND}"', read('windows/runner/Runner.rc'))
        self.assertIn('VALUE "ProductName", "clash"', read('windows/runner/Runner.rc'))
        self.assertIn('/utf-8', read('windows/CMakeLists.txt'))
        self.assertIn('OriginalFilename", "FlClash.exe"', read('windows/runner/Runner.rc'))
        self.assertIn(f'window.Create(L"{BRAND}"', read('windows/runner/main.cpp'))
        self.assertIn(f'gtk_window_set_title(window, "{BRAND}")', read('linux/runner/my_application.cc'))
        for platform in ['appimage', 'deb', 'rpm']:
            self.assertIn(f'display_name: {BRAND}', read(f'linux/packaging/{platform}/make_config.yaml'))
        self.assertIn('package_name: FlClash', read('linux/packaging/deb/make_config.yaml'))
        self.assertIn('app_id: 728B3532-C74B-4870-9068-BE70FE12A3E6',
                      read('windows/packaging/exe/make_config.yaml'))

    def test_current_docs_and_artifact_brand(self):
        for path in ['README.md', 'README_SIMPLE.md', 'README_zh_CN.md', 'backend/README.md']:
            self.assertTrue(read(path).startswith(f'# {BRAND}'))
        self.assertTrue(read('.github/workflows/harmony-simple.yml').startswith(f'name: {BRAND}\n'))
        self.assertIn("app_name: 'FlClash'", read('distribute_options.yaml'))
        self.assertIn("'--artifact-name',\n      artifactNameTemplate", read('setup.dart'))
        self.assertIn('xiaomao-ai-proxy-{{build_name}}-{{platform}}', read('setup.dart'))
        self.assertIn("f'xiaomao-ai-proxy-{sha[:12]}-unsigned.{extension}'",
                      read('.github/scripts/stage-dot-package.py'))
        self.assertIn("appName: '小猫AI代理'", read('backend/src/auth.ts'))

    def test_old_product_label_absent_from_active_ui(self):
        for directory in ['lib', 'ohos', 'android', 'assets_source']:
            for path in (ROOT / directory).rglob('*'):
                if path.is_file() and path.suffix in {'.dart', '.ets', '.json', '.xml', '.svg'}:
                    content = path.read_text(encoding='utf-8')
                    if path == ROOT / 'lib/common/constant.dart':
                        content = content.replace(
                            "const legacyAppDisplayName = 'Clash Harmony';", '')
                    self.assertNotIn('Clash Harmony', content, str(path))


if __name__ == '__main__':
    unittest.main()
