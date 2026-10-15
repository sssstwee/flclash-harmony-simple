import 'dart:async';

import 'package:fl_clash/models/models.dart';

/// Uses the subscription's catch-all group without rewriting its routing rules.
Group? connectionGroup(List<Group> groups, List<String> rules) {
  for (final rule in rules.reversed) {
    final parts = rule.split(',').map((part) => part.trim()).toList();
    if (parts.length >= 2 &&
        (parts.first.toUpperCase() == 'MATCH' ||
            parts.first.toUpperCase() == 'FINAL')) {
      return groups.getGroup(parts[1]);
    }
  }
  return null;
}

/// Checks the route selected by the core. Selection and failover belong to the
/// hosted groups; a failed probe must never select a different node locally.
Future<bool> probeConfiguredRoute(
  Group group,
  Future<int?> Function(String name) measure,
) async {
  try {
    final delay = await measure(
      group.name,
    ).timeout(const Duration(seconds: 24));
    return delay != null && delay > 0;
  } catch (_) {
    return false;
  }
}
