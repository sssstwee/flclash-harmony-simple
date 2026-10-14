import 'dart:async';

import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

typedef AutomaticProxySelection = ({
  String name,
  Map<String, String> selections,
});

bool _safeGroup(Group group, List<Group> groups, Set<String> visited) {
  if (group.type == GroupType.Relay ||
      group.name == GroupName.GLOBAL.name ||
      group.all.isEmpty ||
      visited.contains(group.name)) {
    return false;
  }
  final nextVisited = {...visited, group.name};
  return group.all.every((proxy) {
    final nested = groups.getGroup(proxy.name);
    if (nested != null) return _safeGroup(nested, groups, nextVisited);
    return isHarmonyProxyLeaf(proxy.name, proxy.type);
  });
}

/// Validates every branch in the current core snapshot. Empty providers,
/// missing groups, cycles and unknown adapters fail closed. Harmony's generated
/// group also enforces these constraints after future provider updates.
bool isSafeProxyRoute(Proxy proxy, List<Group> groups) {
  final nested = groups.getGroup(proxy.name);
  if (nested != null) return _safeGroup(nested, groups, {});
  return isHarmonyProxyLeaf(proxy.name, proxy.type);
}

/// Uses the first reachable catch-all, matching the core's rule order. Callers
/// on HarmonyOS resolve effectiveHarmonyAutoGroupName from the raw profile.
Group? connectionGroup(List<Group> groups, List<String> rules) {
  for (final rule in rules) {
    final parts = rule.split(',').map((part) => part.trim()).toList();
    if (parts.length >= 2 &&
        const {'MATCH', 'FINAL'}.contains(parts.first.toUpperCase())) {
      return groups.getGroup(parts[1]);
    }
  }
  for (final group in groups) {
    if (group.name != GroupName.GLOBAL.name &&
        group.hidden != true &&
        group.type != GroupType.Relay &&
        group.all.any((proxy) => isSafeProxyRoute(proxy, groups))) {
      return group;
    }
  }
  return null;
}

/// Returns selector changes only, never a fixed choice inside automatic groups.
/// All work shares a 24-second deadline; cancellation stops new probes and drops
/// late results. Warm using harmonyAutomaticTestUrl so the core sees leaf health.
Future<AutomaticProxySelection?> autoSelectProxy(
  Group root,
  List<Group> groups,
  Future<int?> Function(String name) measure, {
  Future<void>? cancelled,
  bool Function()? isCurrent,
  bool warmAutomatic = true,
}) async {
  final candidates = <AutomaticProxySelection>[];
  final automatic = <String, Group>{};

  void collect(Group group, Map<String, String> route, Set<String> visited) {
    if (visited.contains(group.name) || group.type == GroupType.Relay) return;
    if (group.type != GroupType.Selector) {
      if (_safeGroup(group, groups, visited)) {
        automatic[group.name] = group;
        candidates.add((name: group.name, selections: route));
      }
      return;
    }
    final nextVisited = {...visited, group.name};
    for (final proxy in group.all) {
      final selections = {...route, group.name: proxy.name};
      final nested = groups.getGroup(proxy.name);
      if (nested != null) {
        collect(nested, selections, nextVisited);
      } else if (isHarmonyProxyLeaf(proxy.name, proxy.type)) {
        candidates.add((name: proxy.name, selections: selections));
      }
    }
  }

  collect(root, {}, {});
  if (candidates.isEmpty || isCurrent?.call() == false) return null;
  final probes = <String, Future<int?>>{};
  final stopped = Completer<void>();
  var finished = false;
  void stop() {
    if (!stopped.isCompleted) stopped.complete();
  }

  bool active() =>
      !finished && !stopped.isCompleted && isCurrent?.call() != false;
  final timer = Timer(const Duration(seconds: 24), stop);
  cancelled?.then<void>((_) => stop(), onError: (Object _) => stop());

  Future<int?> delay(String name) {
    if (!active()) return Future<int?>.value();
    return probes.putIfAbsent(name, () async {
      try {
        final value = await Future.any<int?>([
          Future<int?>.sync(
            () => active() ? measure(name) : null,
          ).timeout(const Duration(seconds: 8)),
          stopped.future.then<int?>((_) => null),
        ]);
        return active() ? value : null;
      } catch (_) {
        return null;
      }
    });
  }

  List<String> leaves(Group group) {
    final result = <String>{};
    void visit(Group current) {
      for (final proxy in current.all) {
        final nested = groups.getGroup(proxy.name);
        if (nested != null) {
          visit(nested);
        } else {
          result.add(proxy.name);
        }
      }
    }

    // Only recursively validated, acyclic automatic groups reach this method.
    visit(group);
    return result.toList();
  }

  Future<bool> warm(Group group) async {
    final names = leaves(group);
    for (var offset = 0; offset < names.length; offset += 6) {
      if (!active()) return false;
      final values = await Future.wait(names.skip(offset).take(6).map(delay));
      if (!active()) return false;
      if (values.any((value) => value != null && value > 0)) return true;
    }
    return false;
  }

  Future<AutomaticProxySelection?> select() async {
    // One automatic group at a time keeps warm-up fanout at six globally.
    for (final candidate in candidates.where(
      (item) => automatic.containsKey(item.name),
    )) {
      if (!active()) return null;
      if (warmAutomatic && !await warm(automatic[candidate.name]!)) continue;
      final value = await delay(candidate.name);
      if (!active()) return null;
      if (value != null && value > 0) return candidate;
    }
    final manual = candidates
        .where((item) => !automatic.containsKey(item.name))
        .toList();
    for (var offset = 0; offset < manual.length; offset += 6) {
      if (!active()) return null;
      final batch = manual.skip(offset).take(6).toList();
      final values = await Future.wait(
        batch.map((candidate) => delay(candidate.name)),
      );
      if (!active()) return null;
      AutomaticProxySelection? best;
      var bestDelay = double.infinity;
      for (var index = 0; index < batch.length; index++) {
        final value = values[index];
        if (value != null && value > 0 && value < bestDelay) {
          best = batch[index];
          bestDelay = value.toDouble();
        }
      }
      if (best != null) return best;
    }
    return null;
  }

  try {
    if (cancelled != null) {
      // Observe a token cancelled before entry before starting any core probes.
      await Future<void>.value();
      if (!active()) return null;
    }
    final result = await Future.any<AutomaticProxySelection?>([
      select(),
      stopped.future.then<AutomaticProxySelection?>((_) => null),
    ]);
    return active() ? result : null;
  } finally {
    finished = true;
    timer.cancel();
    stop();
  }
}
