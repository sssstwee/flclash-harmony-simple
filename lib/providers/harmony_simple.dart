import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/common/harmony_config_check.dart';
import 'package:fl_clash/common/harmony_config_freshness.dart';
import 'package:fl_clash/common/harmony_connect.dart';
import 'package:fl_clash/common/harmony_home_status.dart';
import 'package:fl_clash/common/harmony_user_issue.dart';
import 'package:fl_clash/common/proxy_transport.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
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
  final HarmonyHomeStatus homeStatus;
  final HarmonyUserIssue? issue;

  const HarmonySimpleState({
    this.bootstrapping = true,
    this.busy = false,
    this.disconnecting = false,
    this.error,
    this.usingCachedConfig = false,
    this.remoteProfile,
    this.session,
    this.homeStatus = const HarmonyHomeStatus(),
    this.issue,
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
    HarmonyHomeStatus? homeStatus,
    HarmonyUserIssue? issue,
    bool clearIssue = false,
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
      homeStatus: homeStatus ?? this.homeStatus,
      issue: clearIssue ? null : (issue ?? this.issue),
    );
  }
}

@Riverpod(keepAlive: true)
HarmonyAccountApi harmonyAccountApi(Ref ref) => harmonyAccount;

@Riverpod(keepAlive: true)
class HarmonySimple extends _$HarmonySimple {
  static const _healthCheckInterval = Duration(minutes: 5);
  static const _manualRefreshDebounce = Duration(seconds: 2);
  static const _versionPollTick = Duration(minutes: 1);

  HarmonyAccountApi get _api => ref.read(harmonyAccountApiProvider);

  Timer? _configRefreshTimer;
  Timer? _healthCheckTimer;
  Timer? _versionCheckTimer;
  Duration _configRefreshInterval = const Duration(hours: 24);
  Duration _minCheckInterval = harmonyDefaultVersionCheckInterval;
  DateTime? _lastVersionCheckAt;
  int _versionCheckFailures = 0;
  DateTime? _lastManualRefreshAt;
  bool _manualRefreshInFlight = false;
  bool _versionCheckInFlight = false;
  final Random _random = Random();

  @override
  HarmonySimpleState build() {
    ref.onDispose(_stopBackgroundTasks);
    return const HarmonySimpleState();
  }

  Future<void> bootstrap() async {
    state = state.copyWith(bootstrapping: true, clearError: true, clearIssue: true);
    var shouldReconnect = false;
    try {
      final session = await _api.restore();
      if (session != null) {
        state = state.copyWith(session: session);
        await _cleanupOrphanRemoteProfiles();
        await _syncRemoteProfile(fallbackOnNetworkError: true);
        shouldReconnect = await _api.readReconnectOnLaunch();
        state = state.copyWith(
          homeStatus: state.homeStatus.copyWith(
            autoReconnectArmed: shouldReconnect,
          ),
        );
        _configRefreshInterval = await _api.readConfigRefreshInterval();
        _minCheckInterval = await _api.readMinCheckInterval();
        _scheduleConfigRefresh();
        _scheduleVersionCheck();
        unawaited(checkConfigVersion(force: true));
      } else {
        state = state.copyWith(clearSession: true);
        await _cleanupOrphanRemoteProfiles();
      }
    } on HarmonyAccountError catch (error) {
      if (error != HarmonyAccountError.unavailable) {
        state = state.copyWith(
          error: _message(error),
          issue: harmonyUserIssueFromAccount(error),
        );
      }
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        issue: HarmonyUserIssue.serviceUnreachable,
      );
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

  void reportNetworkConnectivity(List<ConnectivityResult> results) {
    state = state.copyWith(
      homeStatus: state.homeStatus.copyWith(
        networkKind: HarmonyHomeStatus.networkKindFromConnectivity(results),
      ),
    );
    unawaited(handleNetworkChange());
  }

  Future<void> handleNetworkChange() async {
    if (_api.session == null) return;
    unawaited(checkConfigVersion());
    if (!ref.read(isStartProvider) || state.busy) return;
    await reevaluateRoute();
  }

  Future<void> onAppResumed() async {
    await checkSession();
    if (_api.session != null) {
      unawaited(checkConfigVersion(force: true));
    }
  }

  Future<void> reevaluateRoute() async {
    if (state.busy || _api.session == null || !ref.read(isStartProvider)) {
      return;
    }
    try {
      final ok = await _applyBestRoute(showNoRouteError: false);
      _recordHealthCheck(ok);
    } catch (_) {
      _recordHealthCheck(false);
    }
  }

  void _recordHealthCheck(bool ok) {
    state = state.copyWith(
      homeStatus: state.homeStatus.copyWith(
        lastHealthCheckAt: DateTime.now(),
        lastHealthCheckOk: ok,
      ),
    );
  }

  Future<void> login(String username, String password) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true, clearIssue: true);
    try {
      final session = await _api.login(username, password);
      state = state.copyWith(session: session, clearError: true);
      await _syncRemoteProfile(fallbackOnNetworkError: false);
      _minCheckInterval = await _api.readMinCheckInterval();
      _scheduleVersionCheck();
      unawaited(checkConfigVersion(force: true));
    } on HarmonyAccountError catch (error) {
      state = state.copyWith(
        error: _message(error),
        issue: harmonyUserIssueFromAccount(error),
      );
    } catch (error) {
      state = state.copyWith(
        error: _message(error),
        issue: HarmonyUserIssue.serviceUnreachable,
      );
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> logout({bool expired = false}) async {
    state = state.copyWith(busy: true, clearError: true, clearIssue: true);
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
      issue: expired ? HarmonyUserIssue.authExpired : null,
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
      clearIssue: true,
    );
    try {
      if (running) {
        await _api.setReconnectOnLaunch(false);
        state = state.copyWith(
          homeStatus: state.homeStatus.copyWith(autoReconnectArmed: false),
        );
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
        state = state.copyWith(
          error: _message(error),
          issue: harmonyUserIssueFromAccount(error),
        );
      }
    } catch (_) {
      await setup.updateStatus(false);
      state = state.copyWith(
        error: currentAppLocalizations.simpleConnectFailed,
        issue: HarmonyUserIssue.vpnStartFailed,
      );
    } finally {
      state = state.copyWith(busy: false, disconnecting: false);
    }
  }

  Future<void> _connectVpn() async {
    final setup = ref.read(setupActionProvider.notifier);
    await _syncRemoteProfile(fallbackOnNetworkError: true);
    final profile = state.remoteProfile;
    if (profile == null) {
      state = state.copyWith(
        error: _message(HarmonyAccountError.config),
        issue: HarmonyUserIssue.subscriptionUnreachable,
      );
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
      state = state.copyWith(
        error: currentAppLocalizations.simpleConnectFailed,
        issue: HarmonyUserIssue.vpnStartFailed,
      );
      return;
    }
    await _api.setReconnectOnLaunch(true);
    state = state.copyWith(
      clearIssue: true,
      clearError: true,
      homeStatus: state.homeStatus.copyWith(autoReconnectArmed: true),
    );
    _scheduleConfigRefresh();
    _scheduleHealthCheck();
    _scheduleVersionCheck();
    unawaited(checkConfigVersion(force: true));
  }

  Future<bool> forceRefreshConfig() async {
    if (_api.session == null || state.busy) return false;
    final now = DateTime.now();
    if (_manualRefreshInFlight) return false;
    if (_lastManualRefreshAt != null &&
        now.difference(_lastManualRefreshAt!) < _manualRefreshDebounce) {
      globalState.showNotifier(
        currentAppLocalizations.harmonyConfigRefreshDebounced,
      );
      return false;
    }
    _lastManualRefreshAt = now;
    _manualRefreshInFlight = true;
    _setConfigFreshness(
      state.homeStatus.configFreshness.copyWith(refreshInProgress: true),
    );
    var ok = false;
    try {
      await _syncRemoteProfile(
        fallbackOnNetworkError: true,
        background: true,
        skipConditionals: true,
        hotApplyWhenConnected: true,
        manualRefresh: true,
      );
      ok = true;
      globalState.showNotifier(
        currentAppLocalizations.harmonyConfigRefreshSuccess,
      );
    } on HarmonyAccountError catch (error) {
      if (error == HarmonyAccountError.expired) {
        await logout(expired: true);
      } else {
        _markConfigCheckFailed(error);
        globalState.showNotifier(
          currentAppLocalizations.harmonyConfigRefreshFailed,
        );
      }
    } catch (_) {
      _markConfigCheckFailed(HarmonyAccountError.unavailable);
      globalState.showNotifier(
        currentAppLocalizations.harmonyConfigRefreshFailed,
      );
    } finally {
      _manualRefreshInFlight = false;
      _setConfigFreshness(
        state.homeStatus.configFreshness.copyWith(refreshInProgress: false),
      );
    }
    return ok;
  }

  Future<void> checkConfigVersion({bool force = false}) async {
    if (_api.session == null || state.busy || _versionCheckInFlight) return;
    if (!force && !_isVersionCheckDue()) return;
    _versionCheckInFlight = true;
    _bindConfigFetchRoute();
    try {
      final localVersion = await _api.readConfigVersion();
      final remote = await _api.fetchConfigVersionInfo();
      if (remote != null) {
        _minCheckInterval = remote.minCheckInterval;
        await _api.saveMinCheckInterval(remote.minCheckInterval);
      }
      var needsDownload = false;
      if (remote != null) {
        needsDownload =
            localVersion == null || localVersion != remote.version;
      } else {
        needsDownload = !await _api.probeConfigNotModified();
      }
      _versionCheckFailures = 0;
      _lastVersionCheckAt = DateTime.now();
      _markConfigUpToDate(checkedAt: _lastVersionCheckAt);
      if (needsDownload) {
        _setConfigFreshness(
          state.homeStatus.configFreshness.copyWith(
            kind: HarmonyConfigFreshnessKind.discoveringUpdate,
            lastCheckedAt: _lastVersionCheckAt,
          ),
        );
        await _syncRemoteProfile(
          fallbackOnNetworkError: true,
          background: true,
          hotApplyWhenConnected: true,
        );
      }
    } on HarmonyAccountError catch (error) {
      if (error == HarmonyAccountError.expired) {
        await logout(expired: true);
        return;
      }
      _versionCheckFailures++;
      _lastVersionCheckAt = DateTime.now();
      _markConfigCheckFailed(error);
    } catch (_) {
      _versionCheckFailures++;
      _lastVersionCheckAt = DateTime.now();
      _markConfigCheckFailed(HarmonyAccountError.unavailable);
    } finally {
      _versionCheckInFlight = false;
    }
  }

  bool _isVersionCheckDue() {
    if (_lastVersionCheckAt == null) return true;
    final delay = _versionCheckFailures > 0
        ? versionCheckBackoffDelay(_versionCheckFailures, _minCheckInterval)
        : applyVersionCheckJitter(_minCheckInterval, _random);
    return DateTime.now().isAfter(_lastVersionCheckAt!.add(delay));
  }

  void _bindConfigFetchRoute() {
    if (ref.read(isStartProvider)) {
      _api.localMixedProxyPort = ref.read(patchClashConfigProvider).mixedPort;
    } else {
      _api.localMixedProxyPort = null;
    }
  }

  Future<void> _markConfigUpToDate({DateTime? checkedAt}) async {
    final version = shortConfigVersionLabel(await _api.readConfigVersion());
    _setConfigFreshness(
      state.homeStatus.configFreshness.copyWith(
        kind: HarmonyConfigFreshnessKind.upToDate,
        versionShort: version,
        lastCheckedAt: checkedAt ?? DateTime.now(),
        clearFailureReason: true,
      ),
    );
  }

  void _markConfigCheckFailed(HarmonyAccountError error) {
    final reason = switch (error) {
      HarmonyAccountError.rateLimited =>
        currentAppLocalizations.harmonyConfigCheckReasonRateLimit,
      HarmonyAccountError.config ||
      HarmonyAccountError.unavailable =>
        currentAppLocalizations.harmonyConfigCheckReasonServer,
      _ => currentAppLocalizations.harmonyConfigCheckReasonOffline,
    };
    _setConfigFreshness(
      state.homeStatus.configFreshness.copyWith(
        kind: HarmonyConfigFreshnessKind.checkFailedUsingCache,
        failureReason: reason,
        lastCheckedAt: DateTime.now(),
      ),
    );
  }

  void _setConfigFreshness(HarmonyConfigFreshness freshness) {
    state = state.copyWith(
      homeStatus: state.homeStatus.copyWith(configFreshness: freshness),
    );
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
        state = state.copyWith(
          error: currentAppLocalizations.simpleNoRoute,
          issue: HarmonyUserIssue.noRoute,
        );
      }
      return false;
    }
    final routeKind = selected.usedAutomaticGroup
        ? HarmonyRouteKind.automaticGroup
        : selected.preferTcpActive
        ? HarmonyRouteKind.tcpPreferred
        : HarmonyRouteKind.manual;
    state = state.copyWith(
      homeStatus: state.homeStatus.copyWith(
        routeKind: routeKind,
        aiGroupName: _aiGroupFromRules(rules),
      ),
    );
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

  String? _aiGroupFromRules(List<String> rules) {
    for (final rule in rules) {
      if (rule.startsWith('GEOSITE,category-ai')) {
        final parts = rule.split(',');
        if (parts.length >= 3) return parts[2].trim();
      }
    }
    return null;
  }

  Future<void> _syncRemoteProfile({
    required bool fallbackOnNetworkError,
    bool background = false,
    bool skipConditionals = false,
    bool hotApplyWhenConnected = false,
    bool manualRefresh = false,
  }) async {
    _bindConfigFetchRoute();
    if (background) {
      state = state.copyWith(
        homeStatus: state.homeStatus.copyWith(configSyncInProgress: true),
      );
    }
    try {
      final download = await _api.downloadConfig(
        ifModifiedSince: skipConditionals
            ? null
            : await _api.readConfigLastModified(),
        ifNoneMatch: skipConditionals ? null : await _api.readConfigEtag(),
      );
      if (download.notModified) {
        final existing = state.remoteProfile ?? _findRemoteProfile();
        if (existing != null) {
          ref.read(currentProfileIdProvider.notifier).value = existing.id;
          state = state.copyWith(remoteProfile: existing);
        }
        await _markConfigUpToDate(checkedAt: DateTime.now());
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
      final now = DateTime.now();
      final autoUpdated =
          hotApplyWhenConnected &&
          ref.read(isStartProvider) &&
          !manualRefresh;
      state = state.copyWith(
        remoteProfile: profile,
        usingCachedConfig: false,
        clearIssue: true,
        homeStatus: state.homeStatus.copyWith(
          lastConfigSyncAt: now,
          configFreshness: state.homeStatus.configFreshness.copyWith(
            kind: autoUpdated
                ? HarmonyConfigFreshnessKind.autoUpdated
                : HarmonyConfigFreshnessKind.upToDate,
            versionShort: shortConfigVersionLabel(
              download.configVersion ?? await _api.readConfigVersion(),
            ),
            lastCheckedAt: now,
            autoUpdatedAt: autoUpdated ? now : null,
            clearFailureReason: true,
          ),
        ),
      );
      if (hotApplyWhenConnected && ref.read(isStartProvider)) {
        final setup = ref.read(setupActionProvider.notifier);
        await setup.applyProfile(force: true, silence: true);
        await _applyBestRoute(showNoRouteError: false);
      }
    } on HarmonyAccountError catch (error) {
      if (error == HarmonyAccountError.expired) rethrow;
      if (fallbackOnNetworkError) {
        final existing = state.remoteProfile ?? _findRemoteProfile();
        if (existing != null) {
          ref.read(currentProfileIdProvider.notifier).value = existing.id;
          state = state.copyWith(
            remoteProfile: existing,
            usingCachedConfig: true,
            issue: harmonyUserIssueFromAccount(error) ??
                HarmonyUserIssue.offlineCached,
          );
          _markConfigCheckFailed(error);
          return;
        }
      }
      rethrow;
    } finally {
      if (background) {
        state = state.copyWith(
          homeStatus: state.homeStatus.copyWith(
            configSyncInProgress: false,
            lastConfigSyncAt: state.homeStatus.lastConfigSyncAt ?? DateTime.now(),
          ),
        );
      }
    }
  }

  void _scheduleConfigRefresh() {
    _configRefreshTimer?.cancel();
    if (_api.session == null) return;
    _configRefreshTimer = Timer.periodic(_configRefreshInterval, (_) {
      if (_api.session == null || state.busy) return;
      unawaited(checkConfigVersion(force: true));
    });
  }

  void _scheduleHealthCheck() {
    _healthCheckTimer?.cancel();
    if (_api.session == null) return;
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) {
      if (!ref.read(isStartProvider) || state.busy) return;
      unawaited(reevaluateRoute());
      unawaited(checkConfigVersion());
    });
  }

  void _scheduleVersionCheck() {
    _versionCheckTimer?.cancel();
    if (_api.session == null) return;
    _versionCheckTimer = Timer.periodic(_versionPollTick, (_) {
      if (_api.session == null || state.busy) return;
      unawaited(checkConfigVersion());
    });
  }

  void _stopBackgroundTasks() {
    _configRefreshTimer?.cancel();
    _configRefreshTimer = null;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _versionCheckTimer?.cancel();
    _versionCheckTimer = null;
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
