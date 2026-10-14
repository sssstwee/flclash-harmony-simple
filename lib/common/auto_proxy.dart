import 'dart:async';

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
  final probes = <String, Future<int?>>{};
  final deadline = Completer<void>();
  var timedOut = false;
  final timer = Timer(const Duration(seconds: 24), () {
    timedOut = true;
    deadline.complete();
  });

  Future<int?> delay(String name) {
    if (timedOut) return Future<int?>.value();
    return probes.putIfAbsent(name, () async {
      try {
        return await Future.any<int?>([
          Future<int?>.sync(() => measure(name))
              .timeout(const Duration(seconds: 8)),
          deadline.future.then<int?>((_) => null),
        ]);
      } catch (_) {
        return null;
      }
    });
  }

  Future<({String name, Map<String, String> selections})?> select() async {
    final automaticCandidates = candidates
        .where((item) => automatic.contains(item.name))
        .toList();
    final manual = candidates
        .where((item) => !automatic.contains(item.name))
        .toList();
    for (final candidateSet in [automaticCandidates, manual]) {
      for (var offset = 0; offset < candidateSet.length; offset += 6) {
        if (timedOut) return null;
        final batch = candidateSet.skip(offset).take(6).toList();
        final values = await Future.wait(
          batch.map((candidate) => delay(candidate.name)),
        );
        if (timedOut) return null;
        ({String name, Map<String, String> selections})? best;
        var bestDelay = double.infinity;
        for (var index = 0; index < batch.length; index++) {
          final value = values[index];
          if (value == null || value <= 0) continue;
          if (automatic.contains(batch[index].name)) return batch[index];
          if (value < bestDelay) {
            best = batch[index];
            bestDelay = value.toDouble();
          }
        }
        if (best != null) return best;
      }
    }
    return null;
  }

  try {
    // This deadline spans automatic and manual batches together. Merely
    // checking a stopwatch between batches can overshoot by a full probe.
    return await Future.any([
      select(),
      deadline.future.then<({String name, Map<String, String> selections})?>(
        (_) => null,
      ),
    ]);
  } finally {
    timer.cancel();
  }
}
