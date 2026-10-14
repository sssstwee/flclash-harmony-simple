import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/common/harmony_config_freshness.dart';

/// Novice-facing home screen status (no settings required).
enum HarmonyNetworkKind { wifi, cellular, other, unknown }

enum HarmonyRouteKind { automaticGroup, tcpPreferred, manual }

class HarmonyHomeStatus {
  final HarmonyRouteKind? routeKind;
  final String? aiGroupName;
  final HarmonyNetworkKind networkKind;
  final bool autoReconnectArmed;
  final bool configSyncInProgress;
  final DateTime? lastConfigSyncAt;
  final DateTime? lastHealthCheckAt;
  final bool? lastHealthCheckOk;
  final HarmonyConfigFreshness configFreshness;

  const HarmonyHomeStatus({
    this.routeKind,
    this.aiGroupName,
    this.networkKind = HarmonyNetworkKind.unknown,
    this.autoReconnectArmed = false,
    this.configSyncInProgress = false,
    this.lastConfigSyncAt,
    this.lastHealthCheckAt,
    this.lastHealthCheckOk,
    this.configFreshness = const HarmonyConfigFreshness(),
  });

  HarmonyHomeStatus copyWith({
    HarmonyRouteKind? routeKind,
    String? aiGroupName,
    bool clearAiGroupName = false,
    HarmonyNetworkKind? networkKind,
    bool? autoReconnectArmed,
    bool? configSyncInProgress,
    DateTime? lastConfigSyncAt,
    DateTime? lastHealthCheckAt,
    bool? lastHealthCheckOk,
    bool clearHealthCheck = false,
    HarmonyConfigFreshness? configFreshness,
  }) {
    return HarmonyHomeStatus(
      routeKind: routeKind ?? this.routeKind,
      aiGroupName: clearAiGroupName
          ? null
          : (aiGroupName ?? this.aiGroupName),
      networkKind: networkKind ?? this.networkKind,
      autoReconnectArmed: autoReconnectArmed ?? this.autoReconnectArmed,
      configSyncInProgress:
          configSyncInProgress ?? this.configSyncInProgress,
      lastConfigSyncAt: lastConfigSyncAt ?? this.lastConfigSyncAt,
      lastHealthCheckAt: clearHealthCheck
          ? null
          : (lastHealthCheckAt ?? this.lastHealthCheckAt),
      lastHealthCheckOk: clearHealthCheck
          ? null
          : (lastHealthCheckOk ?? this.lastHealthCheckOk),
      configFreshness: configFreshness ?? this.configFreshness,
    );
  }

  static HarmonyNetworkKind networkKindFromConnectivity(
    List<ConnectivityResult> results,
  ) {
    if (results.contains(ConnectivityResult.wifi)) {
      return HarmonyNetworkKind.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return HarmonyNetworkKind.cellular;
    }
    if (results.isEmpty) return HarmonyNetworkKind.unknown;
    return HarmonyNetworkKind.other;
  }
}
