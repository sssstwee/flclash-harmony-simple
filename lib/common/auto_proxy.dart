import 'package:fl_clash/enum/enum.dart';
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
  for (final group in groups) {
    if (group.name != GroupName.GLOBAL.name &&
        group.hidden != true &&
        group.all.any(
          (proxy) =>
              proxy.type.toUpperCase() != 'DIRECT' &&
              !proxy.type.toUpperCase().startsWith('REJECT'),
        )) {
      return group;
    }
  }
  return null;
}

/// Returns only selector changes along the chosen route. Automatic groups keep
/// their own health checks; DIRECT/REJECT and cyclic routes are never candidates.
Future<({String name, Map<String, String> selections})?> autoSelectProxy(
  Group root,
  List<Group> groups,
  Future<int?> Function(String name) measure,
) async {
  final candidates = <({String name, Map<String, String> selections})>[];
  final automatic = <String>{};

  void collect(Group group, Map<String, String> route, Set<String> visited) {
    if (visited.contains(group.name)) return;
    if (group.type != GroupType.Selector) {
      if (group.type != GroupType.Relay) {
        automatic.add(group.name);
        candidates.add((name: group.name, selections: route));
      }
      return;
    }
    final nextVisited = {...visited, group.name};
    for (final proxy in group.all) {
      final type = proxy.type.toUpperCase();
      if (type == 'DIRECT' ||
          type.startsWith('REJECT') ||
          proxy.name == 'DIRECT' ||
          proxy.name.startsWith('REJECT')) {
        continue;
      }
      final selections = {...route, group.name: proxy.name};
      final nested = groups.getGroup(proxy.name);
      if (nested != null) {
        collect(nested, selections, nextVisited);
      } else {
        candidates.add((name: proxy.name, selections: selections));
      }
    }
  }

  collect(root, {}, {});
  final delays = <String, int?>{};
  final elapsed = Stopwatch()..start();
  Future<int?> delay(String name) async {
    if (delays.containsKey(name)) return delays[name];
    try {
      delays[name] = await measure(name).timeout(const Duration(seconds: 8));
    } catch (_) {
      delays[name] = null;
    }
    return delays[name];
  }

  final automaticCandidates = candidates
      .where((item) => automatic.contains(item.name))
      .toList();
  for (var offset = 0; offset < automaticCandidates.length; offset += 6) {
    if (elapsed.elapsed >= const Duration(seconds: 24)) return null;
    final batch = automaticCandidates.skip(offset).take(6).toList();
    await Future.wait(batch.map((candidate) => delay(candidate.name)));
    for (final candidate in batch) {
      final value = delays[candidate.name];
      if (value != null && value > 0) return candidate;
    }
  }
  final manual = candidates
      .where((item) => !automatic.contains(item.name))
      .toList();
  // Bound concurrent probes on a phone, including subscriptions with many nodes.
  for (var offset = 0; offset < manual.length; offset += 6) {
    final batch = manual.skip(offset).take(6).toList();
    await Future.wait(batch.map((candidate) => delay(candidate.name)));
    ({String name, Map<String, String> selections})? best;
    var bestDelay = double.infinity;
    for (final candidate in batch) {
      final value = delays[candidate.name];
      if (value != null && value > 0 && value < bestDelay) {
        best = candidate;
        bestDelay = value.toDouble();
      }
    }
    if (best != null) return best;
    if (elapsed.elapsed >= const Duration(seconds: 24)) return null;
  }
  return null;
}
