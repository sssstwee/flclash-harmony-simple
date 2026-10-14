import 'dart:math';

/// Server hint for minimum interval between lightweight version checks.
const harmonyDefaultMinCheckSeconds = 300;

const harmonyDefaultVersionCheckInterval = Duration(
  seconds: harmonyDefaultMinCheckSeconds,
);

const harmonyVersionCheckJitterMaxFraction = 0.15;

Duration harmonyMinCheckIntervalFromSeconds(int? seconds) {
  if (seconds == null || seconds <= 0) {
    return harmonyDefaultVersionCheckInterval;
  }
  return Duration(seconds: seconds);
}

Duration applyVersionCheckJitter(Duration base, Random random) {
  if (base <= Duration.zero) return base;
  final maxJitterMs = (base.inMilliseconds * harmonyVersionCheckJitterMaxFraction)
      .round();
  if (maxJitterMs <= 0) return base;
  final jitter = random.nextInt(maxJitterMs * 2 + 1) - maxJitterMs;
  return Duration(milliseconds: max(base.inMilliseconds + jitter, 1000));
}

Duration versionCheckBackoffDelay(int failureCount, Duration base) {
  if (failureCount <= 0) return base;
  final capped = failureCount.clamp(1, 6);
  final multiplier = 1 << (capped - 1);
  final ms = (base.inMilliseconds * multiplier).clamp(
    base.inMilliseconds,
    const Duration(hours: 1).inMilliseconds,
  );
  return Duration(milliseconds: ms);
}

bool harmonyEtagMatches(String? clientEtag, String? serverEtag) {
  if (clientEtag == null ||
      clientEtag.isEmpty ||
      serverEtag == null ||
      serverEtag.isEmpty) {
    return false;
  }
  String normalize(String value) {
    var trimmed = value.trim();
    if (trimmed.startsWith('W/')) {
      trimmed = trimmed.substring(2);
    }
    return trimmed;
  }

  final target = normalize(serverEtag);
  for (final part in clientEtag.split(',')) {
    if (normalize(part) == target) return true;
  }
  return false;
}

class HarmonyConfigVersionInfo {
  final String version;
  final DateTime? updatedAt;
  final Duration minCheckInterval;

  const HarmonyConfigVersionInfo({
    required this.version,
    this.updatedAt,
    required this.minCheckInterval,
  });

  static DateTime? _parseUpdatedAt(Object? updatedRaw) {
    if (updatedRaw == null) return null;
    if (updatedRaw is int) {
      return DateTime.fromMillisecondsSinceEpoch(updatedRaw * 1000, isUtc: true);
    }
    if (updatedRaw is double) {
      return DateTime.fromMillisecondsSinceEpoch(
        (updatedRaw * 1000).round(),
        isUtc: true,
      );
    }
    if (updatedRaw is String) {
      final trimmed = updatedRaw.trim();
      final unix = int.tryParse(trimmed);
      if (unix != null) {
        return DateTime.fromMillisecondsSinceEpoch(unix * 1000, isUtc: true);
      }
      return DateTime.tryParse(trimmed);
    }
    return null;
  }

  /// Appends `/version` to a config resource path (e.g. `/token/vpn.yml` → `/token/vpn.yml/version`).
  static String versionPathForConfigPath(String configPath) {
    if (configPath.isEmpty || configPath == '/') return '/version';
    if (configPath.endsWith('/')) {
      return '${configPath}version';
    }
    return '$configPath/version';
  }

  static HarmonyConfigVersionInfo? fromJson(Object? data) {
    if (data is! Map) return null;
    final version = '${data['version']}'.trim();
    if (version.isEmpty) return null;
    final updatedAt = _parseUpdatedAt(data['updated_at']);
    final minSeconds = switch (data['min_check_seconds']) {
      final int v => v,
      final double v => v.round(),
      final String v => int.tryParse(v.trim()),
      _ => null,
    };
    return HarmonyConfigVersionInfo(
      version: version,
      updatedAt: updatedAt,
      minCheckInterval: harmonyMinCheckIntervalFromSeconds(minSeconds),
    );
  }
}
