import 'package:fl_clash/common/harmony_vpn_notification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds Chinese titles for each phase', () {
    expect(
      harmonyVpnNotificationTitle(
        HarmonyVpnNotificationPhase.connected,
        lineName: '香港-01',
      ),
      '已连接 · 香港-01',
    );
    expect(
      harmonyVpnNotificationTitle(HarmonyVpnNotificationPhase.connecting),
      '正在连接…',
    );
    expect(
      harmonyVpnNotificationTitle(HarmonyVpnNotificationPhase.reconnecting),
      '连接异常，正在自动重连',
    );
    expect(
      harmonyVpnNotificationTitle(HarmonyVpnNotificationPhase.disconnected),
      '已断开',
    );
  });

  test('content includes speeds, session totals, and config hint', () {
    final text = harmonyVpnNotificationContent(
      uploadSpeed: '1.2 MB',
      downloadSpeed: '3.4 MB',
      uploadTotal: '10 MB',
      downloadTotal: '20 MB',
      configHint: '配置最新',
    );
    expect(text, contains('↑ 1.2 MB/s'));
    expect(text, contains('配置最新'));
  });

  test('resolve phase prefers reconnecting when armed with issue', () {
    expect(
      resolveHarmonyVpnNotificationPhase(
        isStart: true,
        busy: false,
        disconnecting: false,
        autoReconnectArmed: true,
        hasReconnectableIssue: true,
      ),
      HarmonyVpnNotificationPhase.reconnecting,
    );
  });

  test('shortHarmonyLineName truncates long labels', () {
    expect(
      shortHarmonyLineName('Very-Long-Node-Name-Example', maxChars: 8),
      'Very-Lon…',
    );
  });
}
