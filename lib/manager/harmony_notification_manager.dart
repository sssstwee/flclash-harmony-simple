import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/harmony_config_freshness.dart';
import 'package:fl_clash/common/harmony_vpn_notification.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pushes throttled VPN notification content to HarmonyOS while the tunnel runs.
class HarmonyNotificationManager extends ConsumerStatefulWidget {
  final Widget child;

  const HarmonyNotificationManager({super.key, required this.child});

  @override
  ConsumerState<HarmonyNotificationManager> createState() =>
      _HarmonyNotificationManagerState();
}

class _HarmonyNotificationManagerState
    extends ConsumerState<HarmonyNotificationManager>
    with ServiceListener {
  static const _pushInterval = Duration(milliseconds: 1500);

  Timer? _timer;
  DateTime? _lastPushAt;
  HarmonyVpnNotificationPayload? _lastPayload;

  @override
  void initState() {
    super.initState();
    if (!system.isOhos) return;
    service?.addListener(this);
    _timer = Timer.periodic(
      _pushInterval,
      (_) => _pushNotification(force: false),
    );
    ref.listenManual(isStartProvider, (prev, next) {
      if (prev == next) return;
      if (!next) {
        unawaited(service?.clearVpnNotification());
        _lastPayload = null;
      } else {
        unawaited(_pushNotification(force: true));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    service?.removeListener(this);
    unawaited(service?.clearVpnNotification());
    super.dispose();
  }

  @override
  void onNotificationAction(String action) {
    if (!mounted) return;
    if (action == 'disconnect') {
      if (ref.read(isStartProvider)) {
        unawaited(ref.read(harmonySimpleProvider.notifier).toggleConnect());
      }
      return;
    }
    if (action == 'reswitch') {
      unawaited(ref.read(harmonySimpleProvider.notifier).reevaluateRoute());
    }
  }

  Future<void> _pushNotification({required bool force}) async {
    if (!system.isOhos) return;
    final running = ref.read(isStartProvider);
    final ui = ref.read(harmonySimpleProvider);
    if (!running && !ui.busy && !ui.disconnecting) {
      if (_lastPayload?.phase !=
          HarmonyVpnNotificationPhase.disconnected.name) {
        await service?.clearVpnNotification();
        _lastPayload = null;
      }
      return;
    }
    final now = DateTime.now();
    if (!force &&
        _lastPushAt != null &&
        now.difference(_lastPushAt!) < _pushInterval) {
      return;
    }
    final live = ref.read(trafficsProvider).list.safeLast(const Traffic());
    final total = ref.read(totalTrafficProvider);
    final profile = ref.read(currentProfileProvider);
    final groupName = profile?.currentGroupName;
    final lineName = groupName == null ? null : profile?.selectedMap[groupName];
    final freshness = ui.homeStatus.configFreshness;
    final configHint = harmonyVpnConfigHintForNotification(
      configAutoUpdatedRecently:
          freshness.displayKind == HarmonyConfigFreshnessKind.autoUpdated,
      configUpToDate:
          freshness.kind == HarmonyConfigFreshnessKind.upToDate ||
          freshness.displayKind == HarmonyConfigFreshnessKind.upToDate,
    );
    final phase = resolveHarmonyVpnNotificationPhase(
      isStart: running,
      busy: ui.busy,
      disconnecting: ui.disconnecting,
      autoReconnectArmed: ui.homeStatus.autoReconnectArmed,
      hasReconnectableIssue: ui.issue != null,
    );
    final payload = buildHarmonyVpnNotificationPayload(
      phase: phase,
      lineName: lineName,
      uploadSpeed: live.up.traffic.show,
      downloadSpeed: live.down.traffic.show,
      uploadTotal: total.up.traffic.show,
      downloadTotal: total.down.traffic.show,
      configHint: configHint,
    );
    if (!force &&
        _lastPayload != null &&
        _payloadsEqual(_lastPayload!, payload)) {
      return;
    }
    _lastPushAt = now;
    _lastPayload = payload;
    if (phase == HarmonyVpnNotificationPhase.disconnected) {
      await service?.clearVpnNotification();
      return;
    }
    await service?.updateVpnNotification(payload);
  }

  bool _payloadsEqual(
    HarmonyVpnNotificationPayload a,
    HarmonyVpnNotificationPayload b,
  ) {
    return a.phase == b.phase &&
        a.title == b.title &&
        a.content == b.content &&
        a.configHint == b.configHint &&
        a.showActions == b.showActions;
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
