/// Payload pushed to HarmonyOS for the VPN foreground notification (GET-only server rules unrelated).
class HarmonyVpnNotificationPayload {
  final String phase;
  final String title;
  final String content;
  final String configHint;
  final bool showActions;

  const HarmonyVpnNotificationPayload({
    required this.phase,
    required this.title,
    required this.content,
    this.configHint = '',
    this.showActions = false,
  });

  Map<String, Object?> toJson() => {
    'phase': phase,
    'title': title,
    'content': content,
    'configHint': configHint,
    'showActions': showActions,
  };
}

enum HarmonyVpnNotificationPhase {
  connected,
  connecting,
  reconnecting,
  disconnected,
}

HarmonyVpnNotificationPhase resolveHarmonyVpnNotificationPhase({
  required bool isStart,
  required bool busy,
  required bool disconnecting,
  required bool autoReconnectArmed,
  bool hasReconnectableIssue = false,
}) {
  if (disconnecting || (!isStart && !busy)) {
    return HarmonyVpnNotificationPhase.disconnected;
  }
  if (busy && !isStart) {
    return HarmonyVpnNotificationPhase.connecting;
  }
  if (isStart &&
      autoReconnectArmed &&
      (hasReconnectableIssue || busy)) {
    return HarmonyVpnNotificationPhase.reconnecting;
  }
  if (isStart) {
    return HarmonyVpnNotificationPhase.connected;
  }
  if (autoReconnectArmed && hasReconnectableIssue) {
    return HarmonyVpnNotificationPhase.reconnecting;
  }
  return HarmonyVpnNotificationPhase.connecting;
}

String harmonyVpnNotificationTitle(
  HarmonyVpnNotificationPhase phase, {
  String? lineName,
}) {
  return switch (phase) {
    HarmonyVpnNotificationPhase.connected =>
      '已连接 · ${shortHarmonyLineName(lineName ?? '自动线路')}',
    HarmonyVpnNotificationPhase.connecting => '正在连接…',
    HarmonyVpnNotificationPhase.reconnecting => '连接异常，正在自动重连',
    HarmonyVpnNotificationPhase.disconnected => '已断开',
  };
}

String shortHarmonyLineName(String name, {int maxChars = 14}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '自动线路';
  if (trimmed.runes.length <= maxChars) return trimmed;
  return '${String.fromCharCodes(trimmed.runes.take(maxChars))}…';
}

String harmonyVpnNotificationContent({
  required String uploadSpeed,
  required String downloadSpeed,
  required String uploadTotal,
  required String downloadTotal,
  String configHint = '',
}) {
  final traffic =
      '↑ $uploadSpeed/s  ↓ $downloadSpeed/s · 会话 ↑$uploadTotal ↓$downloadTotal';
  if (configHint.isEmpty) return traffic;
  return '$traffic · $configHint';
}

String harmonyVpnConfigHintForNotification({
  required bool configAutoUpdatedRecently,
  required bool configUpToDate,
}) {
  if (configAutoUpdatedRecently) return '配置已更新';
  if (configUpToDate) return '配置最新';
  return '';
}

HarmonyVpnNotificationPayload buildHarmonyVpnNotificationPayload({
  required HarmonyVpnNotificationPhase phase,
  String? lineName,
  required String uploadSpeed,
  required String downloadSpeed,
  required String uploadTotal,
  required String downloadTotal,
  String configHint = '',
}) {
  final title = harmonyVpnNotificationTitle(phase, lineName: lineName);
  if (phase == HarmonyVpnNotificationPhase.disconnected) {
    return HarmonyVpnNotificationPayload(
      phase: phase.name,
      title: title,
      content: '',
      showActions: false,
    );
  }
  return HarmonyVpnNotificationPayload(
    phase: phase.name,
    title: title,
    content: harmonyVpnNotificationContent(
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
      uploadTotal: uploadTotal,
      downloadTotal: downloadTotal,
      configHint: configHint,
    ),
    configHint: configHint,
    showActions: phase == HarmonyVpnNotificationPhase.connected,
  );
}
