import 'package:fl_clash/common/harmony_config_freshness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('displayKind prefers recent auto-updated banner', () {
    final fresh = HarmonyConfigFreshness(
      kind: HarmonyConfigFreshnessKind.upToDate,
      autoUpdatedAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(fresh.displayKind, HarmonyConfigFreshnessKind.autoUpdated);
  });

  test('shortConfigVersionLabel truncates long hashes', () {
    expect(shortConfigVersionLabel('abcd1234ef567890'), 'abcd1234');
    expect(shortConfigVersionLabel('short'), 'short');
  });
}
