import 'dart:math';

import 'package:fl_clash/common/harmony_config_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses version JSON with unix updated_at', () {
    final info = HarmonyConfigVersionInfo.fromJson({
      'version': 'abcd1234ef567890',
      'updated_at': 1_700_000_000,
      'min_check_seconds': 120,
    });
    expect(info?.version, 'abcd1234ef567890');
    expect(info?.updatedAt?.toUtc().millisecondsSinceEpoch, 1_700_000_000_000);
    expect(info?.minCheckInterval, const Duration(minutes: 2));
  });

  test('version path appends /version to config resource path', () {
    expect(
      HarmonyConfigVersionInfo.versionPathForConfigPath('/token/vpn.yml'),
      '/token/vpn.yml/version',
    );
    expect(
      HarmonyConfigVersionInfo.versionPathForConfigPath('/v1/config'),
      '/v1/config/version',
    );
  });

  test('jitter and backoff stay within bounds', () {
    const base = Duration(minutes: 5);
    final jittered = applyVersionCheckJitter(base, Random(1));
    expect(jittered.inMilliseconds, greaterThan(0));
    expect(
      versionCheckBackoffDelay(3, base).inMinutes,
      greaterThanOrEqualTo(5),
    );
  });

  test('etag matching ignores weak prefix and list values', () {
    expect(
      harmonyEtagMatches(
        'W/"abc", "def"',
        '"abc"',
      ),
      isTrue,
    );
    expect(harmonyEtagMatches('"zzz"', '"abc"'), isFalse);
  });
}
