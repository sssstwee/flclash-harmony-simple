import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

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

@Riverpod(keepAlive: true)
HarmonyAccountApi harmonyAccountApi(Ref ref) => harmonyAccount;

@Riverpod(keepAlive: true)
class HarmonySimple extends _$HarmonySimple {
  HarmonyAccountApi get _api => ref.read(harmonyAccountApiProvider);
  HarmonyProfileStore get _files => ref.read(harmonyProfileStoreProvider);
  int _operation = 0;
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

  @override
  HarmonySimpleState build() => const HarmonySimpleState();

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
          state = state.copyWith(error: _message(error));
        }
      }
    } catch (error) {
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(error: _message(error));
      }
    } finally {
      _restoring = false;
      if (operation == _operation && ref.mounted) {
        state = state.copyWith(bootstrapping: false);
      }
    }
  }

  Future<void> checkSession() async {
    if (state.bootstrapping || state.busy || _restoring || _api.session == null) {
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
          state = state.copyWith(error: _message(error));
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
          error: expired ? _message(HarmonyAccountError.expired) : null,
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
    );
    try {
      if (running) {
        await setup.updateStatus(false);
        return;
      }
      await _syncRemoteProfile(
        fallbackOnNetworkError: true,
        operation: operation,
      );
      _ensureCurrent(operation, token);
      final profile = state.remoteProfile;
      if (profile == null) {
        state = state.copyWith(error: _message(HarmonyAccountError.config));
        return;
      }
      if (profile.id != ref.read(currentProfileIdProvider)) {
        return;
      }
      ref
          .read(patchClashConfigProvider.notifier)
          .update((s) => s.copyWith(mode: Mode.rule));
      ref
          .read(vpnSettingProvider.notifier)
          .update((s) => s.copyWith(enable: true));
      await setup.applyProfile(force: true);
      _ensureCurrent(operation, token);
      final groups = ref.read(groupsProvider);
      final config = await ref
          .read(harmonyCoreControllerProvider)
          .getConfig(profile.id);
      final group = connectionGroup(
        groups,
        system.isOhos
            ? defaultRoutingRules(config)
            : List<String>.from(config['rules'] ?? const <String>[]),
      );
      final selected = group == null
          ? null
          : await autoSelectProxy(
              group,
              groups,
              (name) async =>
                  (await ref
                          .read(harmonyCoreControllerProvider)
                          .getDelay(
                            group.testUrl ??
                                ref.read(appSettingProvider).testUrl,
                            name,
                          ))
                      .value,
            );
      _ensureCurrent(operation, token);
      if (selected == null) {
        state = state.copyWith(error: currentAppLocalizations.simpleNoRoute);
        return;
      }
      for (final entry in selected.selections.entries.toList().reversed) {
        _ensureCurrent(operation, token);
        await ref
            .read(proxiesActionProvider.notifier)
            .changeProxy(groupName: entry.key, proxyName: entry.value);
        ref
            .read(profilesActionProvider.notifier)
            .updateCurrentSelectedMap(entry.key, entry.value);
      }
      ref
          .read(proxiesActionProvider.notifier)
          .updateCurrentGroupName(group!.name);
      _ensureCurrent(operation, token);
      await setup.updateStatus(true, isInit: true, profileApplied: true);
      _ensureCurrent(operation, token);
      if (!ref.read(isStartProvider)) {
        state = state.copyWith(
          error: currentAppLocalizations.simpleConnectFailed,
        );
      }
    } on _SupersededHarmonyOperation {
      // Do not let an old probe/connect completion revive a signed-out session.
    } on HarmonyAccountError catch (error) {
      if (ref.mounted && operation == _operation) {
        await _stopSafely();
        if (error == HarmonyAccountError.expired) {
          await logout(expired: true);
        } else {
          state = state.copyWith(error: _message(error));
        }
      }
    } catch (_) {
      if (ref.mounted && operation == _operation) {
        await _stopSafely();
        state = state.copyWith(
          error: currentAppLocalizations.simpleConnectFailed,
        );
      }
    } finally {
      if (ref.mounted && operation == _operation) {
        state = state.copyWith(busy: false, disconnecting: false);
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
