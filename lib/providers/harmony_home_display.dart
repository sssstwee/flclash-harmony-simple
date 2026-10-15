import 'dart:convert';

import 'package:fl_clash/common/harmony_remote_config.dart';
import 'package:fl_clash/providers/harmony_simple.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final harmonyHomeDisplayProvider =
    NotifierProvider<HarmonyHomeDisplay, Map<String, dynamic>>(
      HarmonyHomeDisplay.new,
    );

/// Public UI settings never gate login, profile installation or VPN startup.
class HarmonyHomeDisplay extends Notifier<Map<String, dynamic>> {
  bool _restored = false;
  bool _refreshing = false;
  String? _etag;
  DateTime? _lastAttempt;

  @override
  Map<String, dynamic> build() => const {};

  Future<void> refresh({bool force = false}) async {
    if (_refreshing ||
        (!force &&
            _lastAttempt != null &&
            DateTime.now().difference(_lastAttempt!) <
                const Duration(seconds: 20))) {
      return;
    }
    _refreshing = true;
    _lastAttempt = DateTime.now();
    final api = ref.read(harmonyAccountApiProvider);
    try {
      if (!_restored) {
        _restored = true;
        try {
          final raw = await api.readHomeDisplayCache();
          if (!ref.mounted) return;
          if (raw != null) {
            final cached = jsonDecode(raw) as Map;
            final runtime = HarmonyRemoteConfig.decodeHome(cached['document']);
            final etag = cached['etag'];
            if (etag != null && etag is! String) {
              throw const FormatException('Invalid home cache');
            }
            state = runtime;
            _etag = etag as String?;
          }
        } catch (_) {
          // A missing, corrupt or inaccessible cache falls back to defaults.
        }
      }
      final response = await api.fetchHomeDisplay(etag: _etag);
      if (!ref.mounted || response.statusCode == 304) return;
      final runtime = HarmonyRemoteConfig.decodeHome(response.data);
      state = runtime;
      _etag = response.headers.value('etag');
      try {
        await api.writeHomeDisplayCache(
          jsonEncode({'etag': _etag, 'document': response.data}),
        );
      } catch (_) {
        // Valid UI updates can still be displayed when storage is unavailable.
      }
    } catch (_) {
      // Retain the last verified UI. Display failures cannot affect the tunnel.
    } finally {
      _refreshing = false;
    }
  }
}

final harmonyDisplayRuntimeProvider = Provider<Map<String, dynamic>>((ref) {
  final profile = ref.watch(
    harmonySimpleProvider.select((state) => state.remoteRuntime),
  );
  final home = ref.watch(harmonyHomeDisplayProvider);
  return {
    ...profile,
    ...home,
    'texts': {...?profile['texts'] as Map?, ...?home['texts'] as Map?},
  };
});
