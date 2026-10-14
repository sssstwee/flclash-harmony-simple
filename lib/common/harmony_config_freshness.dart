/// User-visible config freshness on the Harmony simple home screen.
enum HarmonyConfigFreshnessKind {
  unknown,
  upToDate,
  discoveringUpdate,
  autoUpdated,
  checkFailedUsingCache,
}

class HarmonyConfigFreshness {
  final HarmonyConfigFreshnessKind kind;
  final String? versionShort;
  final DateTime? lastCheckedAt;
  final String? failureReason;
  final bool refreshInProgress;
  final DateTime? autoUpdatedAt;

  const HarmonyConfigFreshness({
    this.kind = HarmonyConfigFreshnessKind.unknown,
    this.versionShort,
    this.lastCheckedAt,
    this.failureReason,
    this.refreshInProgress = false,
    this.autoUpdatedAt,
  });

  HarmonyConfigFreshness copyWith({
    HarmonyConfigFreshnessKind? kind,
    String? versionShort,
    bool clearVersionShort = false,
    DateTime? lastCheckedAt,
    String? failureReason,
    bool clearFailureReason = false,
    bool? refreshInProgress,
    DateTime? autoUpdatedAt,
    bool clearAutoUpdatedAt = false,
  }) {
    return HarmonyConfigFreshness(
      kind: kind ?? this.kind,
      versionShort: clearVersionShort
          ? null
          : (versionShort ?? this.versionShort),
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      failureReason: clearFailureReason
          ? null
          : (failureReason ?? this.failureReason),
      refreshInProgress: refreshInProgress ?? this.refreshInProgress,
      autoUpdatedAt: clearAutoUpdatedAt
          ? null
          : (autoUpdatedAt ?? this.autoUpdatedAt),
    );
  }

  /// Prefer the brief auto-updated banner while it is still recent.
  HarmonyConfigFreshnessKind get displayKind {
    if (refreshInProgress) {
      return HarmonyConfigFreshnessKind.discoveringUpdate;
    }
    final updatedAt = autoUpdatedAt;
    if (updatedAt != null &&
        DateTime.now().difference(updatedAt) < const Duration(minutes: 3)) {
      return HarmonyConfigFreshnessKind.autoUpdated;
    }
    return kind;
  }
}

String? shortConfigVersionLabel(String? version) {
  if (version == null || version.isEmpty) return null;
  final trimmed = version.trim();
  if (trimmed.length <= 8) return trimmed;
  return trimmed.substring(0, 8);
}
