import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/common/harmony_recovery.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

export 'package:fl_clash/common/harmony_recovery.dart'
    show HarmonyConnectionHealth;

part 'generated/harmony_simple.g.dart';

enum HarmonySimpleError {
  credentials,
  sessionExpired,
  rateLimited,
  config,
  service,
  noRoute,
  connectFailed,
}

class HarmonySimpleState {
  final bool bootstrapping;
  final bool busy;
  final bool disconnecting;
  final String? _error;
  final HarmonySimpleError? errorCause;
  final HarmonyConnectionHealth health;
  final bool connectionRequested;
  final bool? domesticHealthy;
  final bool? foreignHealthy;
  final int recoveryAttempt;
  final DateTime? nextRetryAt;

  bool get actualConnected => health == HarmonyConnectionHealth.connected;
  String? get error => resolveError(currentAppLocalizations);

  String? resolveError(AppLocalizations localizations) => switch (errorCause) {
    HarmonySimpleError.credentials => localizations.harmonyCredentialsError,
    HarmonySimpleError.sessionExpired => localizations.harmonySessionExpired,
    HarmonySimpleError.rateLimited => localizations.harmonyRateLimited,
    HarmonySimpleError.config => localizations.harmonyConfigError,
    HarmonySimpleError.service => localizations.harmonyServiceError,
    HarmonySimpleError.noRoute => localizations.simpleNoRoute,
    HarmonySimpleError.connectFailed => localizations.simpleConnectFailed,
    null => _error,
  };
  final bool usingCachedConfig;
  final Profile? remoteProfile;
  final HarmonySession? session;

  const HarmonySimpleState({
    this.bootstrapping = true,
    this.busy = false,
    this.disconnecting = false,
    String? error,
    this.errorCause,
    this.health = HarmonyConnectionHealth.disconnected,
    this.connectionRequested = false,
    this.domesticHealthy,
    this.foreignHealthy,
    this.recoveryAttempt = 0,
    this.nextRetryAt,
    this.usingCachedConfig = false,
    this.remoteProfile,
    this.session,
  }) : _error = error;

  HarmonySimpleState copyWith({
    bool? bootstrapping,
    bool? busy,
    bool? disconnecting,
    String? error,
    HarmonySimpleError? errorCause,
    HarmonyConnectionHealth? health,
    bool? connectionRequested,
    bool? domesticHealthy,
    bool? foreignHealthy,
    bool clearHealthChecks = false,
    int? recoveryAttempt,
    DateTime? nextRetryAt,
    bool clearNextRetry = false,
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
      error: clearError ? null : (error ?? _error),
      errorCause: clearError ? null : (errorCause ?? this.errorCause),
      health: health ?? this.health,
      connectionRequested: connectionRequested ?? this.connectionRequested,
      domesticHealthy: clearHealthChecks
          ? null
          : (domesticHealthy ?? this.domesticHealthy),
      foreignHealthy: clearHealthChecks
          ? null
          : (foreignHealthy ?? this.foreignHealthy),
      recoveryAttempt: recoveryAttempt ?? this.recoveryAttempt,
      nextRetryAt: clearNextRetry ? null : (nextRetryAt ?? this.nextRetryAt),
      usingCachedConfig: usingCachedConfig ?? this.usingCachedConfig,
      remoteProfile: clearRemoteProfile
          ? null
          : (remoteProfile ?? this.remoteProfile),
      session: clearSession ? null : (session ?? this.session),
    );
  }
}

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

/// Lets tests exercise the OHOS-generated routing contract without a device.
final harmonyManagedRoutingProvider = Provider<bool>((ref) => system.isOhos);

final harmonyConnectivityCheckProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    final results = await Connectivity().checkConnectivity();
    return results.any(
      (result) =>
          result != ConnectivityResult.none && result != ConnectivityResult.vpn,
    );
  },
);

class _SupersededHarmonyOperation implements Exception {}

@Riverpod(keepAlive: true)
HarmonyAccountApi harmonyAccountApi(Ref ref) => harmonyAccount;

@Riverpod(keepAlive: true)
class HarmonySimple extends _$HarmonySimple {
  HarmonyAccountApi get _api => ref.read(harmonyAccountApiProvider);
  HarmonyProfileStore get _files => ref.read(harmonyProfileStoreProvider);
  int _operation = 0;
  bool _restoring = false;
  late HarmonyRecoveryCoordinator _recovery;
  String? _runtimeGroupName;
  bool _connectionIntentKnown = false;
  int _lifecycleEpoch = 0;
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

  @override
  HarmonySimpleState build() {
    _recovery = HarmonyRecoveryCoordinator(
      attempt: _recoverConnection,
      onChanged: (snapshot) {
        if (!ref.mounted) return;
        state = state.copyWith(
          health: snapshot.health,
          connectionRequested: snapshot.connectionRequested,
          domesticHealthy: snapshot.domesticHealthy,
          foreignHealthy: snapshot.foreignHealthy,
          clearHealthChecks:
              snapshot.domesticHealthy == null &&
              snapshot.foreignHealthy == null,
          recoveryAttempt: snapshot.recoveryAttempt,
          nextRetryAt: snapshot.nextRetryAt,
          clearNextRetry: snapshot.nextRetryAt == null,
        );
      },
    );
    ref.onDispose(_recovery.dispose);
    ref.listen(isStartProvider, (previous, running) {
      if (previous == true &&
          !running &&
          _recovery.snapshot.connectionRequested) {
        _recovery.serviceStopped();
      }
    });
    return const HarmonySimpleState();
  }

  Future<void> bootstrap() async {
    if (_restoring || state.busy) {
      return;
    }
    _restoring = true;
    final operation = ++_operation;
    state = state.copyWith(bootstrapping: true, clearError: true);
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
      }
    } on _SupersededHarmonyOperation {
      // A newer login/logout owns the state now.
    } on HarmonyAccountError catch (error) {
      if (operation == _operation && ref.mounted) {
        if (error == HarmonyAccountError.expired) {
          await logout(expired: true);
        } else if (error != HarmonyAccountError.unavailable) {
          state = state.copyWith(errorCause: _errorCause(error));
        }
      }
    } catch (error) {
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(errorCause: _errorCause(error));
      }
    } finally {
      _restoring = false;
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(bootstrapping: false);
        if (state.connectionRequested && state.remoteProfile != null) {
          unawaited(_recovery.checkNow());
        } else if (!_connectionIntentKnown &&
            _api.session != null &&
            state.remoteProfile != null &&
            ref.read(isStartProvider)) {
          _connectionIntentKnown = true;
          unawaited(_recovery.connect());
        }
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
    final operation = _operation;
    try {
      final restored = await _api.restore();
      if (!ref.mounted || operation != _operation) {
        return;
      }
      if (restored == null) {
        await logout(expired: true);
      } else {
        state = state.copyWith(session: restored);
      }
    } on HarmonyAccountError catch (error) {
      if (ref.mounted &&
          operation == _operation &&
          error == HarmonyAccountError.expired) {
        await logout(expired: true);
      }
    } catch (_) {}
  }

  Future<void> login(String username, String password) async {
    if (state.busy || _restoring) {
      return;
    }
    final operation = ++_operation;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final session = await _api.login(username, password);
      _ensureCurrent(operation, session.token);
      state = state.copyWith(session: session, clearError: true);
      await _cleanupOrphanRemoteProfiles(operation);
      await _syncRemoteProfile(
        fallbackOnNetworkError: false,
        operation: operation,
      );
    } on _SupersededHarmonyOperation {
      // A newer logout owns the state now.
    } catch (error) {
      if (operation == _operation && ref.mounted) {
        if (error == HarmonyAccountError.expired) {
          await logout(expired: true);
        } else {
          state = state.copyWith(errorCause: _errorCause(error));
        }
      }
    } finally {
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(busy: false);
      }
    }
  }

  Future<void> logout({bool expired = false}) async {
    final operation = ++_operation;
    _connectionIntentKnown = true;
    final recoveryStopped = _recovery.disconnect();
    _runtimeGroupName = null;
    state = state.copyWith(busy: true, clearError: true);
    final installations = List.of(_profileInstalls);
    final profiles = <int, Profile>{
      for (final profile in _remoteProfiles()) profile.id: profile,
      for (final install in installations) install.profile.id: install.profile,
    };
    state = state.copyWith(
      clearRemoteProfile: true,
      clearSession: true,
      usingCachedConfig: false,
    );
    try {
      // Invalidate authorization immediately, before slow native cleanup.
      final logout = _api.logout().catchError((Object _) {
        _api.session = null;
      });
      // A native start cannot be cancelled after submission. Join it before
      // stopping so an old completion cannot recreate VPN after logout.
      await recoveryStopped;
      await _stopSafely();
      try {
        await logout;
      } catch (_) {
        // The API clears in-memory authorization even if the keystore fails.
        _api.session = null;
      }
      // File/DB writes cannot be cancelled. Join writes already in flight
      // before deleting their results so logout cannot leave a late orphan.
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
          health: expired
              ? HarmonyConnectionHealth.loginRequired
              : HarmonyConnectionHealth.disconnected,
          errorCause: expired ? HarmonySimpleError.sessionExpired : null,
          clearError: !expired,
        );
      }
    }
  }

  Future<void> retryConnect() async {
    if (state.busy || _restoring || _api.session == null) return;
    if (state.connectionRequested) {
      state = state.copyWith(clearError: true);
      await _recovery.connect();
    } else {
      await toggleConnect();
    }
  }

  void handleNetworkChanged({
    required bool connected,
    bool captivePortal = false,
  }) {
    _recovery.networkChanged(
      connected: connected,
      captivePortal: captivePortal,
    );
  }

  void onAppPaused() {
    _lifecycleEpoch++;
    _recovery.pause();
  }

  Future<void> onAppResumed() async {
    if (_api.session == null) return;
    final operation = _operation;
    final lifecycleEpoch = ++_lifecycleEpoch;
    _recovery.pause();
    try {
      final connected = await ref
          .read(harmonyConnectivityCheckProvider)()
          .timeout(const Duration(seconds: 3));
      if (!ref.mounted ||
          operation != _operation ||
          lifecycleEpoch != _lifecycleEpoch) {
        return;
      }
      _recovery.networkChanged(connected: connected);
    } catch (_) {
      // Availability is only a hint. The bounded HTTPS checks remain decisive.
    }
    if (!ref.mounted ||
        operation != _operation ||
        lifecycleEpoch != _lifecycleEpoch) {
      return;
    }
    await _recovery.resume();
    if (!_connectionIntentKnown && ref.read(isStartProvider)) {
      _connectionIntentKnown = true;
      await _recovery.connect();
    }
  }

  Future<void> toggleConnect() async {
    if (_restoring ||
        _api.session == null ||
        state.disconnecting ||
        (state.busy && !state.connectionRequested)) {
      return;
    }
    final operation = ++_operation;
    final token = _api.session!.token;
    final running = ref.read(isStartProvider);
    _connectionIntentKnown = true;
    if (running || state.connectionRequested) {
      final stopped = _recovery.disconnect();
      state = state.copyWith(busy: true, disconnecting: true, clearError: true);
      try {
        await stopped;
        _ensureCurrent(operation, token);
        await ref.read(setupActionProvider.notifier).updateStatus(false);
      } catch (_) {
        if (ref.mounted && operation == _operation) {
          state = state.copyWith(errorCause: HarmonySimpleError.connectFailed);
        }
      } finally {
        if (ref.mounted && operation == _operation) {
          state = state.copyWith(busy: false, disconnecting: false);
        }
      }
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _syncRemoteProfile(
        fallbackOnNetworkError: true,
        operation: operation,
      );
      _ensureCurrent(operation, token);
      if (state.remoteProfile == null) {
        throw HarmonyAccountError.config;
      }
      _runtimeGroupName = null;
      ref
          .read(patchClashConfigProvider.notifier)
          .update((s) => s.copyWith(mode: Mode.rule));
      ref
          .read(vpnSettingProvider.notifier)
          .update((s) => s.copyWith(enable: true));
      await _recovery.connect();
    } on _SupersededHarmonyOperation {
      // A newer logout owns state and native cleanup.
    } catch (error) {
      if (ref.mounted && operation == _operation) {
        if (error == HarmonyAccountError.expired) {
          await logout(expired: true);
        } else {
          state = state.copyWith(errorCause: _errorCause(error));
        }
      }
    } finally {
      if (ref.mounted && operation == _operation) {
        state = state.copyWith(busy: false, disconnecting: false);
      }
    }
  }

  void _ensureRecovery(
    HarmonyRecoveryTicket ticket,
    int operation,
    String token,
  ) {
    ticket.ensureCurrent();
    _ensureCurrent(operation, token);
  }

  Future<bool> _probeHealth(
    HarmonyRecoveryTicket ticket,
    String url,
    String proxyName,
  ) async {
    ticket.ensureCurrent();
    try {
      final delay = await ticket.wait(
        ref
            .read(harmonyCoreControllerProvider)
            .getHealthDelay(url, proxyName)
            .timeout(const Duration(seconds: 8)),
      );
      ticket.ensureCurrent();
      return delay.value != null && delay.value! > 0;
    } on HarmonyRecoveryCancelled {
      rethrow;
    } catch (_) {
      ticket.ensureCurrent();
      return false;
    }
  }

  Future<HarmonyHealthResult> _recoverConnection(
    HarmonyRecoveryTicket ticket,
  ) async {
    final session = _api.session;
    final profile = state.remoteProfile;
    final operation = _operation;
    if (session == null ||
        profile == null ||
        profile.id != ref.read(currentProfileIdProvider)) {
      return const HarmonyHealthResult(
        domesticHealthy: false,
        foreignHealthy: false,
        hasRoute: false,
      );
    }
    final token = session.token;
    _ensureRecovery(ticket, operation, token);
    if (ref.read(harmonyManagedRoutingProvider)) {
      final network = await ticket.wait(
        ref
            .read(harmonyCoreControllerProvider)
            .getHarmonyNetworkState()
            .timeout(const Duration(seconds: 3)),
      );
      _ensureRecovery(ticket, operation, token);
      if (network.connected == false || network.captivePortal) {
        // Only an observed platform state may produce offline/portal guidance.
        // No HTTPS failure, missing VALIDATED capability, or delay implies it.
        return HarmonyHealthResult(
          domesticHealthy: false,
          foreignHealthy: false,
          offline: network.connected == false,
          captivePortal: network.captivePortal,
        );
      }
    }
    final setup = ref.read(setupActionProvider.notifier);
    final wasRunning = ref.read(isStartProvider);
    if (!wasRunning) {
      // Only a genuinely stopped VPN may be started. A failed probe never
      // stops/reapplies a running configuration or drops healthy DIRECT flows.
      await ref.read(coreActionProvider.notifier).tryStartCore();
      _ensureRecovery(ticket, operation, token);
      await setup.applyProfile(force: true);
      _ensureRecovery(ticket, operation, token);
    }
    final groups = ref.read(groupsProvider);
    var group = _runtimeGroupName == null
        ? null
        : groups.getGroup(_runtimeGroupName!);
    if (group == null) {
      final config = await ticket.wait(
        ref
            .read(harmonyCoreControllerProvider)
            .getConfig(profile.id)
            .timeout(const Duration(seconds: 8)),
      );
      _ensureRecovery(ticket, operation, token);
      group = ref.read(harmonyManagedRoutingProvider)
          ? groups.getGroup(effectiveHarmonyAutoGroupName(config))
          : connectionGroup(
              groups,
              List<String>.from(config['rules'] ?? const <String>[]),
            );
      _runtimeGroupName = group?.name;
    }
    if (group == null) {
      return const HarmonyHealthResult(
        domesticHealthy: false,
        foreignHealthy: false,
        hasRoute: false,
      );
    }
    final root = group;
    final managed = ref.read(harmonyManagedRoutingProvider);
    var managedRootVerified = false;
    Future<bool> selectRoute() async {
      if (managed) {
        // Native refresh warms the managed group's real leaves with its exact
        // URL/status policy and clears only its stale fast-selection cache.
        // Isolated strict probes below must never overwrite shared core health.
        await ticket.wait(
          ref
              .read(harmonyCoreControllerProvider)
              .refreshHarmonyHealth()
              .timeout(const Duration(seconds: 15)),
        );
        _ensureRecovery(ticket, operation, token);
        // A provider leaf may share the generated group's display name. The
        // flattened Dart snapshot then resembles a self-cycle, although native
        // identity resolution still distinguishes the managed group and leaf.
        // The compiler and native strict probe enforce the managed safety
        // boundary; do not reconstruct its identity from display names here.
        managedRootVerified = await _probeHealth(
          ticket,
          harmonyAutomaticTestUrl,
          root.name,
        );
        _ensureRecovery(ticket, operation, token);
        if (managedRootVerified) {
          ref
              .read(proxiesActionProvider.notifier)
              .updateCurrentGroupName(root.name);
        }
        return managedRootVerified;
      }
      final selected = await autoSelectProxy(
        root,
        groups,
        (name) async =>
            await _probeHealth(ticket, harmonyAutomaticTestUrl, name)
            ? 1
            : null,
        cancelled: ticket.cancelled,
        isCurrent: () => ticket.mayProbe,
      );
      _ensureRecovery(ticket, operation, token);
      if (selected == null) return false;
      for (final entry in selected.selections.entries.toList().reversed) {
        _ensureRecovery(ticket, operation, token);
        await ref
            .read(proxiesActionProvider.notifier)
            .changeProxy(
              groupName: entry.key,
              proxyName: entry.value,
              preserveConnections: true,
            );
        _ensureRecovery(ticket, operation, token);
        ref
            .read(profilesActionProvider.notifier)
            .updateCurrentSelectedMap(entry.key, entry.value);
      }
      ref
          .read(proxiesActionProvider.notifier)
          .updateCurrentGroupName(root.name);
      return true;
    }

    if (!wasRunning) {
      if (!await selectRoute()) {
        return const HarmonyHealthResult(
          domesticHealthy: false,
          foreignHealthy: false,
          hasRoute: false,
        );
      }
      _ensureRecovery(ticket, operation, token);
      await setup.updateStatus(true, isInit: true, profileApplied: true);
      _ensureRecovery(ticket, operation, token);
    }
    final results = await Future.wait([
      _probeHealth(ticket, 'https://www.baidu.com', 'DIRECT'),
      managedRootVerified
          ? Future<bool>.value(true)
          : _probeHealth(ticket, harmonyAutomaticTestUrl, root.name),
    ]);
    _ensureRecovery(ticket, operation, token);
    var foreignHealthy = results[1];
    if (wasRunning && !foreignHealthy && results[0]) {
      // Warm safe real nodes and allow the core's automatic group to choose a
      // live route. Domestic-only failures must not churn a working proxy.
      if (await selectRoute()) {
        foreignHealthy =
            managedRootVerified ||
            await _probeHealth(ticket, harmonyAutomaticTestUrl, root.name);
      }
    }
    _ensureRecovery(ticket, operation, token);
    return HarmonyHealthResult(
      domesticHealthy: results[0],
      foreignHealthy: foreignHealthy,
      running: ref.read(isStartProvider),
    );
  }

  Future<void> switchNode(String groupName, String proxyName) async {
    if (state.busy || _api.session == null || !state.connectionRequested) {
      return;
    }
    final groups = ref.read(groupsProvider);
    final group = groups.getGroup(groupName);
    final proxy = group?.all
        .where((proxy) => proxy.name == proxyName)
        .firstOrNull;
    if (group?.type != GroupType.Selector ||
        proxy == null ||
        !isSafeProxyRoute(proxy, groups)) {
      return;
    }
    final operation = ++_operation;
    final token = _api.session!.token;
    final stopped = _recovery.disconnect();
    state = state.copyWith(busy: true, clearError: true);
    try {
      await stopped;
      _ensureCurrent(operation, token);
      await ref
          .read(proxiesActionProvider.notifier)
          .changeProxy(
            groupName: groupName,
            proxyName: proxyName,
            preserveConnections: true,
          );
      _ensureCurrent(operation, token);
      ref
          .read(profilesActionProvider.notifier)
          .updateCurrentSelectedMap(groupName, proxyName);
      await _recovery.connect();
    } on _SupersededHarmonyOperation {
      // Logout superseded the requested change.
    } catch (_) {
      if (ref.mounted && operation == _operation) {
        state = state.copyWith(errorCause: HarmonySimpleError.connectFailed);
        await _recovery.connect();
      }
    } finally {
      if (ref.mounted && operation == _operation) {
        state = state.copyWith(busy: false);
      }
    }
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
      return profile;
    } catch (_) {
      return null;
    }
  }

  Future<void> _syncRemoteProfile({
    required bool fallbackOnNetworkError,
    required int operation,
  }) async {
    final session = _api.session;
    if (session == null) {
      throw HarmonyAccountError.expired;
    }
    final metadata = await _api.readConfigCache();
    final cached = await _verifiedCachedProfile(metadata);
    _ensureCurrent(operation, session.token);
    if (cached == null) {
      state = state.copyWith(
        clearRemoteProfile: true,
        usingCachedConfig: false,
      );
    }
    try {
      var download = await _api.downloadConfig(
        ifNoneMatch: cached == null ? null : metadata?.etag,
      );
      _ensureCurrent(operation, session.token);
      if (download.notModified) {
        // Re-check bytes after the request. Missing or changed local files must
        // force a full response, even when an old server returns unsolicited 304.
        final current = await _verifiedCachedProfile(metadata);
        _ensureCurrent(operation, session.token);
        if (current != null && cached != null) {
          ref.read(currentProfileIdProvider.notifier).value = current.id;
          state = state.copyWith(
            remoteProfile: current,
            usingCachedConfig: false,
          );
          return;
        }
        download = await _api.downloadConfig();
        _ensureCurrent(operation, session.token);
      }
      final bytes = download.bytes;
      if (download.notModified || bytes == null || bytes.isEmpty) {
        throw HarmonyAccountError.config;
      }
      await ref.read(coreActionProvider.notifier).tryStartCore();
      _ensureCurrent(operation, session.token);
      final target =
          _remoteProfiles().firstOrNull ??
          Profile.normal(label: appDisplayName);
      final install = (profile: target, done: Completer<void>());
      _profileInstalls.add(install);
      late final Profile profile;
      try {
        profile = await _files.save(target, bytes);
        _ensureCurrent(operation, session.token);
        await ref
            .read(profilesActionProvider.notifier)
            .putProfile(profile.copyWith(autoUpdate: false));
        _ensureCurrent(operation, session.token);
      } finally {
        install.done.complete();
        _profileInstalls.remove(install);
      }
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
      _ensureCurrent(operation, session.token);
      ref.read(currentProfileIdProvider.notifier).value = profile.id;
      state = state.copyWith(remoteProfile: profile, usingCachedConfig: false);
    } on HarmonyAccountError catch (error) {
      _ensureCurrent(operation, session.token);
      // Invalid configs, revoked sessions and rate limits are not network
      // failures. Never hide those behind an unrelated/stale local profile.
      if (fallbackOnNetworkError && error == HarmonyAccountError.unavailable) {
        final existing = await _verifiedCachedProfile(metadata);
        _ensureCurrent(operation, session.token);
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

  List<Profile> _remoteProfiles() => ref
      .read(profilesProvider)
      .where((p) => p.url.isEmpty && p.label == appDisplayName)
      .toList();

  Future<void> _deleteRemoteProfile(Profile profile) async {
    try {
      await ref.read(profilesActionProvider.notifier).deleteProfile(profile.id);
    } catch (_) {}
    try {
      await _files.delete(profile);
    } catch (_) {}
  }

  Future<void> _cleanupOrphanRemoteProfiles(int operation) async {
    final metadata = await _api.readConfigCache();
    if (!ref.mounted || operation != _operation) {
      return;
    }
    final accepted = await _verifiedCachedProfile(metadata);
    if (!ref.mounted || operation != _operation) {
      return;
    }
    for (final profile in _remoteProfiles()) {
      if (!ref.mounted || operation != _operation) {
        return;
      }
      if (profile.id != accepted?.id) await _deleteRemoteProfile(profile);
    }
    if (ref.mounted && operation == _operation) {
      state = state.copyWith(
        remoteProfile: accepted,
        clearRemoteProfile: accepted == null,
      );
    }
  }

  HarmonySimpleError _errorCause(Object error) => switch (error) {
    HarmonyAccountError.credentials => HarmonySimpleError.credentials,
    HarmonyAccountError.expired => HarmonySimpleError.sessionExpired,
    HarmonyAccountError.rateLimited => HarmonySimpleError.rateLimited,
    HarmonyAccountError.config => HarmonySimpleError.config,
    _ => HarmonySimpleError.service,
  };
}
