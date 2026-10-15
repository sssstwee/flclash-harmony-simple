import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/material.dart';

const harmonyPatchConfig = PatchClashConfig(
  findProcessMode: FindProcessMode.off,
  dns: Dns(nameserverPolicy: {}),
);

/// Keeps subscriptions while replacing settings with the one-button defaults.
Config harmonyConfigDefaults(Config config) => config.copyWith(
  appSettingProps: defaultAppSettingProps.copyWith(
    disclaimerAccepted: config.appSettingProps.disclaimerAccepted,
    crashlyticsTip: config.appSettingProps.crashlyticsTip,
    autoCheckUpdate: true,
  ),
  networkProps: defaultNetworkProps,
  vpnProps: defaultVpnProps,
  themeProps: defaultThemeProps.copyWith(themeMode: ThemeMode.system),
  proxiesStyleProps: defaultProxiesStyleProps,
  patchClashConfig: harmonyPatchConfig,
  overrideDns: false,
  excludeSSIDs: [],
  definedPackages: {},
);

Profile harmonyProfileDefaults(Profile profile) => profile.copyWith(
  selectedMap: const {},
  overwriteType: OverwriteType.standard,
  scriptId: null,
  autoUpdate: true,
  autoUpdateDuration: defaultUpdateDuration,
);
