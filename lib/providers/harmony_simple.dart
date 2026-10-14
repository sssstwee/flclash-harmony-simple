import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/common/harmony_connect.dart';
import 'package:fl_clash/common/proxy_transport.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/harmony_simple.g.dart';

class HarmonySimpleState {
  final bool bootstrapping;
  final bool busy;
  final bool disconnecting;
  final String? error;
  final bool usingCachedConfig;
  final Profile? remoteProfile;
  final HarmonySession? session;

  const HarmonySimpleState({
    this.bootstrapping = true,
    this.busy = false,
    this.disconnecting = false,
    this.error,
    this.usingCachedConfig = false,
    this.remoteProfile,
    this.session,
  });

  HarmonySimpleState copyWith({
    bool? bootstrapping,
    bool? busy,
    bool? disconnecting,
    String? error,
    bool clearError = false,
    bool? usingCachedConfig,
    Profile? remoteProfile,
    bool clearRemoteProfile = false,
    HarmonySession? session,
    bool clearSession = false,
  }) {
    return HarmonySimpleState(
      bootstrapping: bootstrapping ?? this.bootstrapping,
      busy: busy ?? this.busy,
      disconnecting: disconnecting ?? this.disconnecting,
      error: clearError ? null : (error ?? this.error),
      usingCachedConfig: usingCachedConfig ?? this.usingCachedConfig,
      remoteProfile: clearRemoteProfile
          ? null
          : (remoteProfile ?? this.remoteProfile),
      session: clearSession ? null : (session ?? this.session),
    );
  }
}

@Riverpod(keepAlive: true)
HarmonyAccountApi harmonyAccountApi(Ref ref) => harmonyAccount;

@Riverpod(keepAlive: true)
class HarmonySimple extends _$HarmonySimple {
  static const _healthCheckInterval = Duration(minutes: 5);

  HarmonyAccountApi get _api => ref.read(harmonyAccountApiProvider);

  Timer? _configRefreshTimer;
  Timer? _healthCheckTimer;
  Duration _configRefreshInterval = const Duration(hours: 24);

  @override
  HarmonySimpleState build() {
    ref.onDispose(_stopBackgroundTasks);
    return const HarmonySimpleState();
  }

  Future<void> bootstrap() async {
    state = state.copyWith(bootstrapping: true, clearError: true);
    var shouldReconnect = false;
    try {
      final session = await _api.restore();
      if (session != null) {
        state = state.copyWith(session: session);
        await _cleanupOrphanRemoteProfiles();
        await _syncRemoteProfile(fallbackOnNetworkError: true);
        shouldReconnect = await _api.readReconnectOnLaunch();
        _configRefreshInterval = await _api.readConfigRefreshInterval();
        _scheduleConfigRefresh();
      } else {
        state = state.copyWith(clearSession: true);
        await _cleanupOrphanRemoteProfiles();
      }
    } on HarmonyAccountError catch (error) {
      if (error != HarmonyAccountError.unavailable) {
        state = state.copyWith(error: _message(error));
      }
    } catch (error) {
      state = state.copyWith(error: _message(error));
    } finally {
      state = state.copyWith(bootstrapping: false);
      if (shouldReconnect && _api.session != null && !ref.read(isStartProvider)) {
        unawaited(toggleConnect());
      }
    }
  }

  Future<void> checkSession() async {
    if (state.bootstrapping || state.busy || _api.session == null) return;
    try {
      if (await _api.restore() == null) {
        await logout(expired: true);
      }
    } on HarmonyAccountError catch (error) {
      if (error == HarmonyAccountError.expired) {
        await logout(expired: true);
      }
    } catch (_) {}
  }

  Future<void> handleNetworkChange() async {
    if (!ref.read(isStartProvider) || state.busy) return;
    await reevaluateRoute();
  }

  Future<void> reevaluateRoute() async {
    if (state.busy || _api.session == null || !ref.read(isStartProvider)) {
      return;
    }
    try {
      await _applyBestRoute(showNoRouteError: false);
    } catch (_) {}
  }

  Future<void> login(String username, String password) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final session = await _api.login(username, password);
      state = state.copyWith(session: session, clearError: true);
      await _syncRemoteProfile(fallbackOnNetworkError: false);
    } on HarmonyAccountError catch (error) {
      state = state.copyWith(error: _message(error));
    } catch (error) {
      state = state.copyWith(error: _message(error));
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> logout({bool expired = false}) async {
    state = state.copyWith(busy: true, clearError: true);
    _stopBackgroundTasks();
    final profile = state.remoteProfile;
    state = state.copyWith(clearRemoteProfile: true, usingCachedConfig: false);
    try {
      await ref.read(setupActionProvider.notifier).updateStatus(false);
    } catch (_) {}
    try {
      await _api.logout();
    } catch (_) {
      await _api.clear();
    }
    if (profile != null) {
      try {
        await ref.read(profilesActionProvider.notifier).deleteProfile(profile.id);
      } catch (_) {}
      try {
        await (await profile.file).safeDelete();
      } catch (_) {}
    }
    state = state.copyWith(
      busy: false,
      clearSession: true,
      error: expired ? _message(HarmonyAccountError.expired) : null,
    );
  }

  Future<void> retryConnect() => toggleConnect();

  Future<void> toggleConnect() async {
    if (state.busy || _api.session == null) return;
    final setup = ref.read(setupActionProvider.notifier);
    final running = ref.read(isStartProvider);
    state = state.copyWith(
      busy: true,
      disconnecting: running,
      clearError: true,
    );
    try {
      if (running) {
        await _api.setReconnectOnLaunch(false);
        _stopBackgroundTasks();
        await setup.updateStatus(false);
        return;
      }
      await _connectVpn();
    } on HarmonyAccountError catch (error) {
      await setup.updateStatus(false);
      if (error == HarmonyAccountError.expired) {
        await logout(expired: true);
      } else {
        state = state.copyWith(error: _message(error));
      }
    } catch (_) {
      await setup.updateStatus(false);
      state = state.copyWith(error: currentAppLocalizations.simpleConnectFailed);
    } finally {
      state = state.copyWith(busy: false, disconnecting: false);
    }
  }

  Future<void> _connectVpn() async {
    final setup = ref.read(setupActionProvider.notifier);
    await _syncRemoteProfile(fallbackOnNetworkError: true);
    final profile = state.remoteProfile;
    if (profile == null) {
      state = state.copyWith(error: _message(HarmonyAccountError.config));
      return;
    }
    if (profile.id != ref.read(currentProfileIdProvider)) return;
    ref
        .read(patchClashConfigProvider.notifier)
        .update((s) => s.copyWith(mode: Mode.rule));
    ref.read(vpnSettingProvider.notifier).update((s) => s.copyWith(enable: true));
    await setup.applyProfile(force: true);
    final applied = await _applyBestRoute(showNoRouteError: true);
    if (!applied) return;
    await setup.updateStatus(true, isInit: true);
    if (!ref.read(isStartProvider)) {
      state = state.copyWith(error: currentAppLocalizations.simpleConnectFailed);
      return;
    }
    await _api.setReconnectOnLaunch(true);
    _scheduleConfigRefresh();
    _scheduleHealthCheck();
  }

  Future<bool> _applyBestRoute({required bool showNoRouteError}) async {
    final profile = state.remoteProfile;
    if (profile == null) return false;
    final groups = ref.read(groupsProvider);
    final config = await coreController.getConfig(profile.id);
    final rules = system.isOhos
        ? defaultRoutingRules(config)
        : List<String>.from(config['rules'] ?? const <String>[]);
    final group = connectionGroup(groups, rules);
    final transportKinds = transportKindsFromConfig(config);
    final selected = group == null
        ? null
        : await autoSelectProxy(
            group,
            groups,
            (name) async => (await coreController.getDelay(
              group.testUrl ?? ref.read(appSettingProvider).testUrl,
              name,
            )).value,
            transportKinds: transportKinds,
            preferTcpFirst: system.isOhos,
          );
    if (selected == null) {
      if (showNoRouteError) {
        state = state.copyWith(error: currentAppLocalizations.simpleNoRoute);
      }
      return false;
    }
    for (final entry in selected.selections.entries.toList().reversed) {
      await ref
          .read(proxiesActionProvider.notifier)
          .changeProxy(groupName: entry.key, proxyName: entry.value);
      ref
          .read(profilesActionProvider.notifier)
          .updateCurrentSelectedMap(entry.key, entry.value);
    }
    ref.read(proxiesActionProvider.notifier).updateCurrentGroupName(group!.name);
    return true;
  }

  Future<void> _syncRemoteProfile({required bool fallbackOnNetworkError}) async {
    try {
      final lastModified = await _api.readConfigLastModified();
      final download = await _api.downloadConfig(ifModifiedSince: lastModified);
      if (download.notModified) {
        final existing = state.remoteProfile ?? _findRemoteProfile();
        if (existing != null) {
          state = state.copyWith(
            remoteProfile: existing,
            usingCachedConfig: true,
          );
          ref.read(currentProfileIdProvider.notifier).value = existing.id;
        }
        return;
      }
      final bytes = download.bytes;
      if (bytes == null) throw HarmonyAccountError.config;
      final yamlText = utf8.decode(bytes);
      final interval =
          download.profileUpdateInterval ??
          profileUpdateIntervalFromYaml(yamlText) ??
          const Duration(hours: 24);
      await _api.saveConfigRefreshInterval(interval);
      _configRefreshInterval = interval;
      _scheduleConfigRefresh();
      await ref.read(coreActionProvider.notifier).tryStartCore();
      final old = _findRemoteProfile();
      final profile = await (old ?? Profile.normal(label: appDisplayName))
          .saveFile(bytes);
      ref
          .read(profilesActionProvider.notifier)
          .putProfile(profile.copyWith(autoUpdate: false));
      ref.read(currentProfileIdProvider.notifier).value = profile.id;
      state = state.copyWith(remoteProfile: profile, usingCachedConfig: false);
    } on HarmonyAccountError catch (error) {
      if (error == HarmonyAccountError.expired) rethrow;
      if (fallbackOnNetworkError) {
        final existing = state.remoteProfile ?? _findRemoteProfile();
        if (existing != null) {
          ref.read(currentProfileIdProvider.notifier).value = existing.id;
          state = state.copyWith(
            remoteProfile: existing,
            usingCachedConfig: true,
          );
          return;
        }
      }
      rethrow;
    }
  }

  void _scheduleConfigRefresh() {
    _configRefreshTimer?.cancel();
    if (_api.session == null) return;
    _configRefreshTimer = Timer.periodic(_configRefreshInterval, (_) {
      if (_api.session == null || state.busy) return;
      unawaited(_syncRemoteProfile(fallbackOnNetworkError: true));
    });
  }

  void _scheduleHealthCheck() {
    _healthCheckTimer?.cancel();
    if (_api.session == null) return;
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) {
      if (!ref.read(isStartProvider) || state.busy) return;
      unawaited(reevaluateRoute());
    });
  }

  void _stopBackgroundTasks() {
    _configRefreshTimer?.cancel();
    _configRefreshTimer = null;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  Profile? _findRemoteProfile() {
    return ref
        .read(profilesProvider)
        .where((p) => p.url.isEmpty && p.label == appDisplayName)
        .firstOrNull;
  }

  Future<void> _cleanupOrphanRemoteProfiles() async {
    final profiles = ref
        .read(profilesProvider)
        .where((p) => p.url.isEmpty && p.label == appDisplayName)
        .toList();
    if (_api.session != null) {
      if (profiles.length <= 1) {
        if (profiles.length == 1 && state.remoteProfile == null) {
          state = state.copyWith(remoteProfile: profiles.first);
        }
        return;
      }
      for (final profile in profiles.skip(1)) {
        await ref.read(profilesActionProvider.notifier).deleteProfile(profile.id);
        await (await profile.file).safeDelete();
      }
      return;
    }
    for (final profile in profiles) {
      await ref.read(profilesActionProvider.notifier).deleteProfile(profile.id);
      await (await profile.file).safeDelete();
    }
  }

  String _message(Object error) {
    return switch (error) {
      HarmonyAccountError.credentials =>
        currentAppLocalizations.harmonyCredentialsError,
      HarmonyAccountError.expired =>
        currentAppLocalizations.harmonySessionExpired,
      HarmonyAccountError.rateLimited =>
        currentAppLocalizations.harmonyRateLimited,
      HarmonyAccountError.config => currentAppLocalizations.harmonyConfigError,
      _ => currentAppLocalizations.harmonyServiceError,
    };
  }
}
