import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/common/harmony_remote_config.dart';
import 'package:fl_clash/common/harmony_config_check.dart';
import 'package:fl_clash/common/harmony_config_freshness.dart';
import 'package:fl_clash/common/harmony_connect.dart';
import 'package:fl_clash/common/harmony_home_status.dart';
import 'package:fl_clash/common/harmony_user_issue.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/harmony_simple.g.dart';

/// The file boundary is injectable so retries can be tested without a live core.
class HarmonyProfileStore {
  Future<Uint8List?> read(Profile profile) async {
    final file = File(await appPath.getProfilePath(profile.id.toString()));
    if (!await file.exists()) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<Profile> save(Profile profile, Uint8List bytes) =>
      profile.saveFile(bytes);

  Future<void> delete(Profile profile) async {
    final file = File(await appPath.getProfilePath(profile.id.toString()));
    await file.safeDelete();
  }
}

final harmonyProfileStoreProvider = Provider<HarmonyProfileStore>(
  (ref) => HarmonyProfileStore(),
);

final harmonyCoreControllerProvider = Provider<CoreController>(
  (ref) => coreController,
);

class _SupersededHarmonyOperation implements Exception {}

class HarmonySimpleState {
  final Map<String, dynamic> remoteRuntime;
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
    this.remoteRuntime = const {},
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
    Map<String, dynamic>? remoteRuntime,
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
      remoteRuntime: remoteRuntime ?? this.remoteRuntime,
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
  HarmonyProfileStore get _files => ref.read(harmonyProfileStoreProvider);
  int _operation = 0;
  int _configSyncGeneration = 0;
  bool _restoring = false;
  final _profileInstalls = <({Profile profile, Completer<void> done})>[];

  void _ensureCurrent(int operation, String token) {
    if (!ref.mounted ||
        operation != _operation ||
        _api.session?.token != token) {
      throw _SupersededHarmonyOperation();
    }
  }

  Future<void> _stopSafely() async {
    try {
      await ref.read(setupActionProvider.notifier).updateStatus(false);
    } catch (_) {
      // Session/UI cleanup must still complete when the native service fails.
    }
  }

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
    if (_restoring || state.busy) {
      return;
    }
    _restoring = true;
    final operation = ++_operation;
    state = state.copyWith(
      bootstrapping: true,
      clearError: true,
      clearIssue: true,
    );
    try {
      final session = await _api.restore();
      if (!ref.mounted || operation != _operation) {
        return;
      }
      state = state.copyWith(session: session, clearSession: session == null);
      await _cleanupOrphanRemoteProfiles(operation);
      if (session != null) {
        await _syncRemoteProfile(
          fallbackOnNetworkError: true,
          operation: operation,
        );
        _ensureCurrent(operation, session.token);
        state = state.copyWith(
          homeStatus: state.homeStatus.copyWith(
            autoReconnectArmed: ref.read(isStartProvider),
          ),
        );
        _configRefreshInterval = await _api.readConfigRefreshInterval();
        _minCheckInterval = await _api.readMinCheckInterval();
        _scheduleConfigRefresh();
        _scheduleVersionCheck();
        unawaited(checkConfigVersion(force: true));
      }
    } on _SupersededHarmonyOperation {
      // A newer login/logout owns the state now.
    } on HarmonyAccountError catch (error) {
      if (operation == _operation && ref.mounted) {
        if (error == HarmonyAccountError.expired) {
          await logout(expired: true);
        } else if (error != HarmonyAccountError.unavailable) {
          state = state.copyWith(
            error: _message(error),
            issue: harmonyUserIssueFromAccount(error),
          );
        }
      }
    } catch (error) {
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(
          error: _message(error),
          issue: HarmonyUserIssue.serviceUnreachable,
        );
      }
    } finally {
      _restoring = false;
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(bootstrapping: false);
      }
    }
  }

  Future<void> checkSession() async {
    if (state.bootstrapping ||
        state.busy ||
        _restoring ||
        _api.session == null) {
      return;
    }
    final token = _api.session!.token;
    try {
      final session = await _api.restore();
      if (!ref.mounted || state.session?.token != token) return;
      if (session == null) {
        await logout(expired: true);
      }
    } on HarmonyAccountError catch (error) {
      if (!ref.mounted || state.session?.token != token) return;
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
    unawaited(ref.read(commonActionProvider.notifier).autoCheckUpdate());
    await checkSession();
    if (_api.session != null) {
      unawaited(checkConfigVersion(force: true));
    }
  }

  Future<void> reevaluateRoute() async {
    if (state.busy || _api.session == null || !ref.read(isStartProvider)) {
      return;
    }
    final operation = _operation;
    final token = _api.session!.token;
    try {
      final ok = await _checkConfiguredRoute(
        operation: operation,
        token: token,
      );
      _ensureCurrent(operation, token);
      if (ref.read(isStartProvider)) _recordHealthCheck(ok);
    } on _SupersededHarmonyOperation {
      return;
    } catch (_) {
      if (ref.mounted && operation == _operation && ref.read(isStartProvider)) {
        _recordHealthCheck(false);
      }
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
    if (state.busy || _restoring) {
      return;
    }
    final operation = ++_operation;
    state = state.copyWith(busy: true, clearError: true, clearIssue: true);
    try {
      final session = await _api.login(username, password);
      _ensureCurrent(operation, session.token);
      state = state.copyWith(session: session, clearError: true);
      await _cleanupOrphanRemoteProfiles(operation);
      await _syncRemoteProfile(
        fallbackOnNetworkError: false,
        operation: operation,
      );
      _minCheckInterval = await _api.readMinCheckInterval();
      _scheduleVersionCheck();
      unawaited(checkConfigVersion(force: true));
    } on _SupersededHarmonyOperation {
      // A newer logout owns the state now.
    } on HarmonyAccountError catch (error) {
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(
          error: _message(error),
          issue:
              state.session != null && error == HarmonyAccountError.unavailable
              ? HarmonyUserIssue.subscriptionUnreachable
              : harmonyUserIssueFromAccount(error),
        );
      }
    } catch (error) {
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(
          error: _message(error),
          issue: state.session != null
              ? HarmonyUserIssue.subscriptionUnreachable
              : HarmonyUserIssue.serviceUnreachable,
        );
      }
    } finally {
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(busy: false);
      }
    }
  }

  Future<void> logout({bool expired = false}) async {
    final operation = ++_operation;
    _stopBackgroundTasks();
    _lastVersionCheckAt = null;
    _versionCheckFailures = 0;
    state = state.copyWith(busy: true, clearError: true, clearIssue: true);
    final installations = List.of(_profileInstalls);
    final profiles = <int, Profile>{
      for (final profile in _remoteProfiles()) profile.id: profile,
      for (final install in installations) install.profile.id: install.profile,
    };
    state = state.copyWith(
      clearRemoteProfile: true,
      remoteRuntime: const {},
      clearSession: true,
      usingCachedConfig: false,
      homeStatus: HarmonyHomeStatus(networkKind: state.homeStatus.networkKind),
    );
    try {
      final logout = _api.logout().catchError((Object _) {
        _api.session = null;
      });
      await _stopSafely();
      try {
        await logout;
      } catch (_) {
        _api.session = null;
      }
      await Future.wait(installations.map((install) => install.done.future));
      for (final profile in profiles.values) {
        await _deleteRemoteProfile(profile);
      }
    } finally {
      if (ref.mounted && operation == _operation) {
        state = state.copyWith(
          busy: false,
          bootstrapping: false,
          disconnecting: false,
          clearSession: true,
          clearRemoteProfile: true,
          error: expired ? _message(HarmonyAccountError.expired) : null,
          issue: expired ? HarmonyUserIssue.authExpired : null,
          clearError: !expired,
        );
      }
    }
  }

  Future<void> retryConnect() => toggleConnect();

  Future<void> toggleConnect() async {
    if (state.busy || _restoring || _api.session == null) {
      return;
    }
    final operation = ++_operation;
    final token = _api.session!.token;
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
        state = state.copyWith(
          homeStatus: state.homeStatus.copyWith(autoReconnectArmed: false),
        );
        _stopBackgroundTasks();
        await setup.updateStatus(false);
        return;
      }
      await _connectVpn(operation: operation, token: token);
    } on _SupersededHarmonyOperation {
      // Do not let an old probe/connect completion revive a signed-out session.
      return;
    } on HarmonyAccountError catch (error) {
      if (ref.mounted && operation == _operation) {
        await _stopSafely();
        if (error == HarmonyAccountError.expired) {
          await logout(expired: true);
        } else {
          state = state.copyWith(
            error: _message(error),
            issue: harmonyUserIssueFromAccount(error),
          );
        }
      }
    } catch (_) {
      if (ref.mounted && operation == _operation) {
        await _stopSafely();
        state = state.copyWith(
          error: currentAppLocalizations.simpleConnectFailed,
          issue: HarmonyUserIssue.vpnStartFailed,
        );
      }
    } finally {
      if (ref.mounted && operation == _operation) {
        state = state.copyWith(busy: false, disconnecting: false);
        if (!running && ref.read(isStartProvider)) {
          unawaited(reevaluateRoute());
        }
      }
    }
  }

  Future<void> _connectVpn({
    required int operation,
    required String token,
  }) async {
    final setup = ref.read(setupActionProvider.notifier);
    // A version probe must not block VPN startup. The cache is still bound to
    // this account and checked against its installed file hash on every start.
    final verified = await _verifiedCachedProfile(await _api.readConfigCache());
    _ensureCurrent(operation, token);
    if (verified == null || verified.id != state.remoteProfile?.id) {
      await _syncRemoteProfile(
        fallbackOnNetworkError: true,
        operation: operation,
      );
    }
    _ensureCurrent(operation, token);
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
    ref
        .read(vpnSettingProvider.notifier)
        .update((s) => s.copyWith(enable: true));
    await setup.applyProfile(force: true);
    _ensureCurrent(operation, token);
    await setup.updateStatus(true, isInit: true, profileApplied: true);
    _ensureCurrent(operation, token);
    if (!ref.read(isStartProvider)) {
      state = state.copyWith(
        error: currentAppLocalizations.simpleConnectFailed,
        issue: HarmonyUserIssue.vpnStartFailed,
      );
      return;
    }
    state = state.copyWith(
      clearIssue: true,
      clearError: true,
      homeStatus: state.homeStatus.copyWith(autoReconnectArmed: true),
    );
    _scheduleConfigRefresh();
    _scheduleHealthCheck();
    _scheduleVersionCheck();
    unawaited(checkConfigVersion(force: true));
    unawaited(
      ref.read(commonActionProvider.notifier).autoCheckUpdate(retry: true),
    );
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
    if (!ref.mounted ||
        _api.session == null ||
        state.busy ||
        _versionCheckInFlight) {
      return;
    }
    if (!force && !_isVersionCheckDue()) return;
    final operation = _operation;
    final token = _api.session!.token;
    _versionCheckInFlight = true;
    _bindConfigFetchRoute();
    try {
      final localVersion = await _api.readConfigVersion();
      _ensureCurrent(operation, token);
      final remote = await _api.fetchConfigVersionInfo();
      _ensureCurrent(operation, token);
      if (remote != null) {
        final configured =
            (state.remoteRuntime['parameters'] as Map?)?['checkSeconds'];
        _minCheckInterval = configured is int
            ? Duration(
                seconds: max(configured, remote.minCheckInterval.inSeconds),
              )
            : remote.minCheckInterval;
        await _api.saveMinCheckInterval(_minCheckInterval);
        _ensureCurrent(operation, token);
      }
      var needsDownload = false;
      if (remote != null) {
        needsDownload = localVersion == null || localVersion != remote.version;
      } else {
        needsDownload = !await _api.probeConfigNotModified();
      }
      _ensureCurrent(operation, token);
      _versionCheckFailures = 0;
      _lastVersionCheckAt = DateTime.now();
      await _markConfigUpToDate(
        operation: operation,
        checkedAt: _lastVersionCheckAt,
      );
      _ensureCurrent(operation, token);
      if (needsDownload) {
        _setConfigFreshness(
          state.homeStatus.configFreshness.copyWith(
            kind: HarmonyConfigFreshnessKind.discoveringUpdate,
            lastCheckedAt: _lastVersionCheckAt,
          ),
        );
        await _syncRemoteProfile(
          fallbackOnNetworkError: true,
          hotApplyWhenConnected: true,
          operation: operation,
        );
      }
    } on _SupersededHarmonyOperation {
      // A later connect, login or logout owns the state now.
    } on HarmonyAccountError catch (error) {
      if (!ref.mounted || operation != _operation) return;
      if (error == HarmonyAccountError.expired) {
        await logout(expired: true);
        return;
      }
      _versionCheckFailures++;
      _lastVersionCheckAt = DateTime.now();
      _markConfigCheckFailed(error);
    } catch (_) {
      if (!ref.mounted || operation != _operation) return;
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

  Future<void> _markConfigUpToDate({
    required int operation,
    DateTime? checkedAt,
  }) async {
    if (!ref.mounted || operation != _operation) return;
    final version = shortConfigVersionLabel(await _api.readConfigVersion());
    if (!ref.mounted || operation != _operation) return;
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
    if (!ref.mounted) return;
    final reason = switch (error) {
      HarmonyAccountError.rateLimited =>
        currentAppLocalizations.harmonyConfigCheckReasonRateLimit,
      HarmonyAccountError.config || HarmonyAccountError.unavailable =>
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
    if (!ref.mounted) return;
    state = state.copyWith(
      homeStatus: state.homeStatus.copyWith(configFreshness: freshness),
    );
  }

  Future<bool> _checkConfiguredRoute({
    required int operation,
    required String token,
  }) async {
    final profile = state.remoteProfile;
    if (profile == null) return false;
    final core = ref.read(harmonyCoreControllerProvider);
    final config = await core.getConfig(profile.id);
    _ensureCurrent(operation, token);
    final rules = List<String>.from(config['rules'] ?? const <String>[]);
    final groups = ref.read(groupsProvider);
    final group = connectionGroup(groups, rules);
    if (group == null) return false;
    state = state.copyWith(
      homeStatus: state.homeStatus.copyWith(
        routeKind: group.type.isComputedSelected
            ? HarmonyRouteKind.automaticGroup
            : HarmonyRouteKind.manual,
        aiGroupName: _aiGroupFromRules(rules),
      ),
    );
    ref.read(proxiesActionProvider.notifier).updateCurrentGroupName(group.name);
    final groupConfig = (config['proxy-groups'] as List? ?? const [])
        .whereType<Map>()
        .where((item) => item['name'] == group.name)
        .firstOrNull;
    final expectedStatus = groupConfig?['expected-status']?.toString();
    return probeConfiguredRoute(group, (name) async {
      final url = group.testUrl ?? ref.read(appSettingProvider).testUrl;
      final delay = expectedStatus == null
          ? await core.getDelay(url, name)
          : await core.getDelay(url, name, expectedStatus: expectedStatus);
      _ensureCurrent(operation, token);
      ref.read(proxiesActionProvider.notifier).setDelay(delay);
      return delay.value;
    });
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

  Future<Profile?> _verifiedCachedProfile(
    HarmonyConfigCacheMetadata? metadata,
  ) async {
    final token = _api.session?.token;
    if (metadata == null || metadata.username != _api.session?.username) {
      return null;
    }
    final profile = _remoteProfiles()
        .where((profile) => profile.id == metadata.profileId)
        .firstOrNull;
    if (profile == null) {
      return null;
    }
    try {
      final bytes = await _files.read(profile);
      if (_api.session?.token != token ||
          !ref.mounted ||
          bytes == null ||
          bytes.isEmpty ||
          bytes.length > harmonyConfigMaxBytes ||
          sha256.convert(bytes).toString() != metadata.contentHash) {
        return null;
      }
      state = state.copyWith(
        remoteRuntime: HarmonyRemoteConfig.runtimeFromProfile(
          bytes,
          clientVersion:
              utf8.decode(bytes).contains('harmony-min-client-version')
              ? '${globalState.packageInfo.version}+${globalState.packageInfo.buildNumber}'
              : null,
        ),
      );
      return profile;
    } catch (_) {
      return null;
    }
  }

  Future<void> _syncRemoteProfile({
    required bool fallbackOnNetworkError,
    int? operation,
    bool skipConditionals = false,
    bool hotApplyWhenConnected = false,
    bool manualRefresh = false,
  }) async {
    final session = _api.session;
    if (session == null) {
      throw HarmonyAccountError.expired;
    }
    final op = operation ?? _operation;
    final syncGeneration = ++_configSyncGeneration;
    _bindConfigFetchRoute();
    state = state.copyWith(
      homeStatus: state.homeStatus.copyWith(configSyncInProgress: true),
    );
    HarmonyConfigCacheMetadata? metadata;
    Profile? cached;
    var stage = 'verify-cache';
    try {
      metadata = await _api.readConfigCache();
      cached = await _verifiedCachedProfile(metadata);
      _ensureCurrent(op, session.token);
      if (cached == null) {
        state = state.copyWith(
          clearRemoteProfile: true,
          remoteRuntime: const {},
          usingCachedConfig: false,
        );
      }
      stage = 'download';
      var download = await _api.downloadConfig(
        ifModifiedSince: skipConditionals
            ? null
            : cached != null
            ? metadata?.lastModified ?? await _api.readConfigLastModified()
            : null,
        ifNoneMatch: skipConditionals
            ? null
            : cached != null
            ? metadata?.etag
            : null,
      );
      _ensureCurrent(op, session.token);
      if (download.notModified) {
        final current = await _verifiedCachedProfile(metadata);
        _ensureCurrent(op, session.token);
        if (current != null && cached != null) {
          ref.read(currentProfileIdProvider.notifier).value = current.id;
          state = state.copyWith(
            remoteProfile: current,
            usingCachedConfig: false,
          );
          await _markConfigUpToDate(operation: op, checkedAt: DateTime.now());
          return;
        }
        download = await _api.downloadConfig();
        _ensureCurrent(op, session.token);
      }
      final bytes = download.bytes;
      if (download.notModified || bytes == null || bytes.isEmpty) {
        throw HarmonyAccountError.config;
      }
      stage = 'parse-config';
      final runtime = HarmonyRemoteConfig.runtimeFromProfile(bytes);
      final parameters = runtime['parameters'] as Map? ?? {};
      final yamlText = utf8.decode(bytes);
      final interval =
          (parameters['refreshSeconds'] is int
              ? Duration(seconds: parameters['refreshSeconds'] as int)
              : null) ??
          download.profileUpdateInterval ??
          profileUpdateIntervalFromYaml(yamlText) ??
          const Duration(hours: 24);
      // App startup owns the initial core preload. Never race it with restartCore.
      stage = 'start-core';
      if (!ref.read(initProvider)) {
        final ready = Completer<void>();
        final subscription = ref.listen(initProvider, (_, initialized) {
          if (initialized && !ready.isCompleted) ready.complete();
        });
        await ready.future.whenComplete(subscription.close);
        _ensureCurrent(op, session.token);
      }
      await ref.read(coreActionProvider.notifier).tryStartCore();
      _ensureCurrent(op, session.token);
      stage = 'prepare-install';
      final target =
          cached?.copyWith(label: appDisplayName) ??
          _remoteProfiles().firstOrNull?.copyWith(label: appDisplayName) ??
          Profile.normal(label: appDisplayName);
      final previousBytes = cached?.id == target.id
          ? await _files.read(target)
          : null;
      _ensureCurrent(op, session.token);
      final previousId = ref.read(currentProfileIdProvider);
      final previousVersion = await _api.readConfigVersion();
      _ensureCurrent(op, session.token);
      final install = (profile: target, done: Completer<void>());
      _profileInstalls.add(install);
      late final Profile profile;
      var saved = false;
      var committed = false;
      try {
        stage = 'save-profile';
        profile = await ref
            .read(profilesActionProvider.notifier)
            .updateProfile(
              target.copyWith(autoUpdate: false),
              bytes: bytes,
              save: (profile, bytes) async {
                stage = 'validate-and-save-profile';
                final result = await _files.save(profile, bytes);
                saved = true;
                stage = 'persist-profile';
                return result;
              },
              apply: false,
            );
        saved = true;
        _ensureCurrent(op, session.token);
        if (hotApplyWhenConnected && ref.read(isStartProvider)) {
          stage = 'apply-profile';
          ref.read(currentProfileIdProvider.notifier).value = profile.id;
          await ref
              .read(setupActionProvider.notifier)
              .applyProfile(force: true, silence: true);
          _ensureCurrent(op, session.token);
        }
        stage = 'persist-cache';
        await _api.commitConfigCache(
          HarmonyConfigCacheMetadata(
            username: session.username,
            profileId: profile.id,
            contentHash: sha256.convert(bytes).toString(),
            etag: download.etag,
            lastModified: download.lastModified,
          ),
          expectedToken: session.token,
        );
        committed = true;
        stage = 'persist-validators';
        await _api.persistInstalledConfigValidators(
          expectedToken: session.token,
          lastModified: download.lastModified,
          etag: download.etag,
          configVersion: download.configVersion,
        );
      } catch (_) {
        if (saved && op == _operation && _api.session?.token == session.token) {
          ref.read(currentProfileIdProvider.notifier).value = previousId;
          if (previousBytes != null) {
            await _files.save(target, previousBytes);
            ref.read(profilesProvider.notifier).put(target);
            try {
              await ref
                  .read(profilesActionProvider.notifier)
                  .putProfile(target);
            } catch (_) {
              // Restore the live core even if database persistence is unavailable.
            }
            if (hotApplyWhenConnected && ref.read(isStartProvider)) {
              await ref
                  .read(setupActionProvider.notifier)
                  .applyProfile(force: true, silence: true);
            }
            if (committed && metadata != null) {
              await _api.commitConfigCache(
                metadata,
                expectedToken: session.token,
              );
              await _api.persistInstalledConfigValidators(
                expectedToken: session.token,
                lastModified: metadata.lastModified,
                etag: metadata.etag,
                configVersion: previousVersion,
              );
            }
          } else {
            await _deleteRemoteProfile(target);
            if (committed) {
              await _api.clearConfigCache();
              await _api.persistInstalledConfigValidators(
                expectedToken: session.token,
              );
            }
          }
        }
        rethrow;
      } finally {
        install.done.complete();
        _profileInstalls.remove(install);
      }
      _ensureCurrent(op, session.token);
      ref.read(currentProfileIdProvider.notifier).value = profile.id;
      stage = 'persist-refresh';
      await _api.saveConfigRefreshInterval(interval);
      _configRefreshInterval = interval;
      _scheduleConfigRefresh();
      state = state.copyWith(remoteRuntime: runtime);
      if (parameters['checkSeconds'] is int) {
        _minCheckInterval = Duration(
          seconds: parameters['checkSeconds'] as int,
        );
        stage = 'persist-check-interval';
        await _api.saveMinCheckInterval(_minCheckInterval);
      }
      final now = DateTime.now();
      final autoUpdated =
          hotApplyWhenConnected && ref.read(isStartProvider) && !manualRefresh;
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
        unawaited(reevaluateRoute());
      }
    } on HarmonyAccountError catch (error) {
      _ensureCurrent(op, session.token);
      commonPrint.log('Harmony config/$stage failed (${error.name})');
      if (error == HarmonyAccountError.expired) {
        rethrow;
      }
      if (fallbackOnNetworkError && error == HarmonyAccountError.unavailable) {
        final existing = await _verifiedCachedProfile(metadata);
        _ensureCurrent(op, session.token);
        if (existing != null) {
          ref.read(currentProfileIdProvider.notifier).value = existing.id;
          state = state.copyWith(
            remoteProfile: existing,
            usingCachedConfig: true,
            issue:
                harmonyUserIssueFromAccount(error) ??
                HarmonyUserIssue.offlineCached,
          );
          _markConfigCheckFailed(error);
          return;
        }
      }
      rethrow;
    } catch (error) {
      _ensureCurrent(op, session.token);
      commonPrint.log('Harmony config/$stage failed (${error.runtimeType})');
      rethrow;
    } finally {
      // A connect may supersede this operation without starting another sync.
      // Only a newer sync, rather than any new operation, takes the indicator.
      if (ref.mounted &&
          syncGeneration == _configSyncGeneration &&
          _api.session?.token == session.token) {
        state = state.copyWith(
          homeStatus: state.homeStatus.copyWith(configSyncInProgress: false),
        );
      }
    }
  }

  List<Profile> _remoteProfiles() => ref
      .read(profilesProvider)
      .where(
        (p) =>
            p.url.isEmpty &&
            (p.label == appDisplayName ||
                legacyAppDisplayNames.contains(p.label)),
      )
      .toList();

  Future<void> _deleteRemoteProfile(Profile profile) async {
    try {
      await ref.read(profilesActionProvider.notifier).deleteProfile(profile.id);
    } catch (_) {}
    try {
      await _files.delete(profile);
    } catch (_) {}
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

  Future<void> _cleanupOrphanRemoteProfiles(int operation) async {
    final metadata = await _api.readConfigCache();
    if (!ref.mounted || operation != _operation) {
      return;
    }
    var accepted = await _verifiedCachedProfile(metadata);
    if (!ref.mounted || operation != _operation) {
      return;
    }
    final token = _api.session?.token;
    if (accepted != null &&
        legacyAppDisplayNames.contains(accepted.label) &&
        token != null) {
      final renamed = accepted.copyWith(label: appDisplayName);
      // Track label-only DB writes too: logout must join them before deleting
      // managed profiles, so a delayed migration cannot resurrect access.
      final migration = (profile: renamed, done: Completer<void>());
      _profileInstalls.add(migration);
      try {
        await ref.read(profilesActionProvider.notifier).putProfile(renamed);
        _ensureCurrent(operation, token);
        accepted = renamed;
      } on _SupersededHarmonyOperation {
        rethrow;
      } catch (_) {
        // A cosmetic write failure must not invalidate a verified offline cache.
        _ensureCurrent(operation, token);
      } finally {
        migration.done.complete();
        _profileInstalls.remove(migration);
      }
    }
    for (final profile in _remoteProfiles()) {
      if (!ref.mounted || operation != _operation) {
        return;
      }
      if (profile.id != accepted?.id) {
        await _deleteRemoteProfile(profile);
      }
    }
    if (ref.mounted && operation == _operation) {
      state = state.copyWith(
        remoteProfile: accepted,
        clearRemoteProfile: accepted == null,
        remoteRuntime: accepted == null ? const {} : state.remoteRuntime,
      );
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
