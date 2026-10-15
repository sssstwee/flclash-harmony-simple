import 'package:fl_clash/common/harmony_defaults.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'replaces old settings while preserving the active subscription and consent',
    () {
      const old = Config(
        currentProfileId: 17,
        themeProps: ThemeProps(themeMode: ThemeMode.light),
        appSettingProps: AppSettingProps(
          locale: 'en',
          autoCheckUpdate: false,
          autoRun: true,
          developerMode: true,
          disclaimerAccepted: true,
        ),
        vpnProps: VpnProps(enable: false, dnsHijacking: true),
        networkProps: NetworkProps(appendSystemDns: true),
        patchClashConfig: PatchClashConfig(
          mixedPort: 9999,
          mode: Mode.global,
          allowLan: true,
          externalController: ExternalControllerStatus.open,
          hosts: {'test.internal': '192.168.1.2'},
        ),
        excludeSSIDs: ['Home'],
        overrideDns: true,
      );
      final result = harmonyConfigDefaults(old);
      expect(result.currentProfileId, 17);
      expect(result.appSettingProps.disclaimerAccepted, isTrue);
      expect(result.appSettingProps.locale, isNull);
      expect(result.appSettingProps.autoRun, isFalse);
      expect(result.appSettingProps.autoCheckUpdate, isTrue);
      expect(result.appSettingProps.developerMode, isFalse);
      expect(result.themeProps.themeMode, ThemeMode.system);
      expect(result.vpnProps, defaultVpnProps);
      expect(result.networkProps, defaultNetworkProps);
      expect(result.overrideDns, isFalse);
      expect(result.patchClashConfig, harmonyPatchConfig);
      expect(result.patchClashConfig.mode, Mode.rule);
      expect(result.patchClashConfig.allowLan, isFalse);
      expect(
        result.patchClashConfig.externalController,
        ExternalControllerStatus.close,
      );
      expect(result.patchClashConfig.dns.nameserverPolicy, isEmpty);
      expect(result.excludeSSIDs, isEmpty);
      expect(harmonyConfigDefaults(result), result);
    },
  );

  test(
    'keeps subscription data while clearing legacy selections and scripts',
    () {
      const old = Profile(
        id: 17,
        label: 'Existing subscription',
        url: 'https://subscription.example/link',
        autoUpdate: false,
        autoUpdateDuration: Duration(days: 30),
        overwriteType: OverwriteType.script,
        scriptId: 12,
        selectedMap: {'Main': 'Node'},
      );
      final result = harmonyProfileDefaults(old);
      expect(result.id, old.id);
      expect(result.label, old.label);
      expect(result.url, old.url);
      expect(result.selectedMap, isEmpty);
      expect(result.autoUpdate, isTrue);
      expect(result.autoUpdateDuration, const Duration(days: 1));
      expect(result.overwriteType, OverwriteType.standard);
      expect(result.scriptId, isNull);
      expect(harmonyProfileDefaults(result), result);
    },
  );
}
