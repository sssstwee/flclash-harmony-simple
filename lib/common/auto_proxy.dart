import 'package:fl_clash/common/proxy_transport.dart';
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
  Future<int?> Function(String name) measure, {
  Map<String, ProxyTransportKind> transportKinds = const {},
  bool preferTcpFirst = false,
}) async {
  final candidates = <({String name, Map<String, String> selections})>[];
  final automatic = <String>{};

  String? proxyTypeFor(String name) {
    for (final group in groups) {
      for (final proxy in group.all) {
        if (proxy.name == name) return proxy.type;
      }
    }
    return null;
  }

  ProxyTransportKind kindFor(String name) {
    return transportKinds[name] ?? proxyTransportKind(proxyTypeFor(name), name);
  }

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
  var preferTcp = preferTcpFirst;

  Future<int?> delay(String name) async {
    if (delays.containsKey(name)) return delays[name];
    final timeout = probeTimeoutFor(kindFor(name), preferTcp: preferTcp);
    try {
      delays[name] = await measure(name).timeout(timeout);
    } catch (_) {
      delays[name] = null;
    }
    if (!preferTcp && inferPreferTcpFromDelays(delays, {
      for (final key in delays.keys) key: kindFor(key),
    })) {
      preferTcp = true;
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
  var manual = candidates
      .where((item) => !automatic.contains(item.name))
      .toList();
  manual = sortByTransportPreference(
    manual,
    (item) => kindFor(item.name),
    preferTcp: preferTcp,
  );
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
