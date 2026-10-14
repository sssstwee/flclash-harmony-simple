import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

final _config = Uint8List.fromList('proxies: []\nrules: []'.codeUnits);

HarmonySession _session([String username = 'alice']) => HarmonySession(
  '$username-token',
  username,
  DateTime.now().add(const Duration(days: 1)),
);

Profile _profile([int id = 7]) => Profile(
  id: id,
  label: appDisplayName,
  autoUpdate: false,
  autoUpdateDuration: const Duration(hours: 24),
);

HarmonyConfigCacheMetadata _metadata({
  String username = 'alice',
  int profileId = 7,
  Uint8List? bytes,
}) => HarmonyConfigCacheMetadata(
  username: username,
  profileId: profileId,
  contentHash: sha256.convert(bytes ?? _config).toString(),
  etag: '"accepted-etag"',
  lastModified: 'accepted-date',
);

class _Api extends HarmonyAccountApi {
  final List<String> events;
  HarmonyConfigCacheMetadata? metadata;
  final downloads = <Object>[];
  final requests = <({String? etag, String? lastModified})>[];
  Object? loginFailure;
  Object? logoutFailure;
  Object? commitFailure;
  Object? restoreFailure;
  int logouts = 0;
  int commits = 0;
  void Function()? downloadStarted;
  Future<HarmonySession?> Function()? restoreHook;
  Future<HarmonyConfigCacheMetadata?> Function()? cacheHook;

  _Api(this.events) {
    session = _session();
  }

  @override
  Future<HarmonySession?> restore() async {
    if (restoreHook != null) {
      return restoreHook!();
    }
    if (restoreFailure != null) {
      throw restoreFailure!;
    }
    return session;
  }

  @override
  Future<HarmonySession> login(String username, String password) async {
    if (loginFailure != null) {
      throw loginFailure!;
    }
    return session = _session(username);
  }

  @override
  Future<HarmonyConfigCacheMetadata?> readConfigCache() async {
    if (cacheHook != null) {
      return cacheHook!();
    }
    return metadata?.username == session?.username ? metadata : null;
  }

  @override
  Future<HarmonyConfigDownload> downloadConfig({
    String? ifNoneMatch,
    String? ifModifiedSince,
  }) async {
    requests.add((etag: ifNoneMatch, lastModified: ifModifiedSince));
    events.add('download');
    downloadStarted?.call();
    if (downloads.isEmpty) {
      throw StateError('Unexpected config request');
    }
    final next = downloads.removeAt(0);
    if (next is Future<HarmonyConfigDownload>) {
      return next;
    }
    if (next is HarmonyConfigDownload) {
      return next;
    }
    throw next;
  }

  @override
  Future<void> commitConfigCache(
    HarmonyConfigCacheMetadata value, {
    required String expectedToken,
  }) async {
    if (commitFailure != null) {
      throw commitFailure!;
    }
    if (session?.token != expectedToken ||
        session?.username != value.username) {
      throw HarmonyAccountError.expired;
    }
    commits++;
    events.add('commit');
    metadata = value;
  }

  @override
  Future<void> clearConfigCache() async {
    metadata = null;
  }

  @override
  Future<void> logout() async {
    logouts++;
    events.add('logout');
    session = null;
    metadata = null;
    if (logoutFailure != null) {
      throw logoutFailure!;
    }
  }

  @override
  Future<void> clear() async {
    session = null;
    metadata = null;
    if (logoutFailure != null) {
      throw logoutFailure!;
    }
  }
}

class _Files extends HarmonyProfileStore {
  final List<String> events;
  final bytes = <int, Uint8List>{};
  final deleted = <int>[];
  Object? saveFailure;
  Object? deleteFailure;
  Future<void> Function(Profile, Uint8List)? saveHook;
  Future<Uint8List?> Function(Profile)? readHook;

  _Files(this.events);

  @override
  Future<Uint8List?> read(Profile profile) async {
    if (readHook != null) {
      return readHook!(profile);
    }
    return bytes[profile.id];
  }

  @override
  Future<Profile> save(Profile profile, Uint8List value) async {
    if (saveFailure != null) {
      throw saveFailure!;
    }
    await saveHook?.call(profile, value);
    bytes[profile.id] = Uint8List.fromList(value);
    events.add('save');
    return profile.copyWith(lastUpdateDate: DateTime.now());
  }

  @override
  Future<void> delete(Profile profile) async {
    deleted.add(profile.id);
    bytes.remove(profile.id);
    events.add('delete-file');
    if (deleteFailure != null) {
      throw deleteFailure!;
    }
  }
}

class _Profiles extends Profiles {
  final List<Profile> initial;

  _Profiles(this.initial);

  @override
  List<Profile> build() => List.of(initial);

  @override
  void put(Profile profile) {
    state = [
      for (final old in state)
        if (old.id != profile.id) old,
      profile,
    ];
  }

  @override
  void del(int id) {
    state = state.where((profile) => profile.id != id).toList();
  }
}

class _ProfileActions extends ProfilesAction {
  final List<String> events;
  Object? putFailure;
  Object? deleteFailure;
  Future<void> Function(Profile)? putHook;
  final deleted = <int>[];
  final selections = <String, String>{};

  _ProfileActions(this.events);

  @override
  Future<void> putProfile(Profile profile) async {
    if (putFailure != null) {
      throw putFailure!;
    }
    await putHook?.call(profile);
    events.add('put');
    ref.read(profilesProvider.notifier).put(profile);
  }

  @override
  Future<void> deleteProfile(int id) async {
    deleted.add(id);
    ref.read(profilesProvider.notifier).del(id);
    if (ref.read(currentProfileIdProvider) == id) {
      ref.read(currentProfileIdProvider.notifier).value = null;
    }
    if (deleteFailure != null) {
      throw deleteFailure!;
    }
  }

  @override
  void updateCurrentSelectedMap(String groupName, String proxyName) {
    selections[groupName] = proxyName;
  }
}

class _CoreActions extends CoreAction {
  final List<String> events;

  _CoreActions(this.events);

  @override
  Future<bool> tryStartCore([bool start = false]) async {
    events.add('core-ready');
    return false;
  }
}

class _Setup extends SetupAction {
  final List<String> events;
  Object? stopFailure;
  int applies = 0;
  Future<void> Function()? startHook;
  final starts = <({bool isInit, bool profileApplied})>[];

  _Setup(this.events);

  @override
  Future<void> updateStatus(
    bool isStart, {
    bool isInit = false,
    bool profileApplied = false,
  }) async {
    events.add(isStart ? 'start' : 'stop');
    if (!isStart && stopFailure != null) {
      throw stopFailure!;
    }
    if (isStart) {
      starts.add((isInit: isInit, profileApplied: profileApplied));
      await startHook?.call();
    }
    ref.read(runTimeProvider.notifier).value = isStart ? 0 : null;
  }

  @override
  Future<void> applyProfile({
    bool silence = false,
    bool force = false,
    VoidCallback? preloadInvoke,
  }) async {
    applies++;
    events.add('apply');
    preloadInvoke?.call();
  }
}

class _ProxyActions extends ProxiesAction {
  final changes = <String, String>{};
  String? group;

  @override
  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
    bool preserveConnections = false,
  }) async {
    expect(preserveConnections, isTrue);
    changes[groupName] = proxyName;
  }

  @override
  void updateCurrentGroupName(String groupName) {
    group = groupName;
  }
}

class _Controller extends Mock implements CoreController {}

class _Harness {
  final events = <String>[];
  late final api = _Api(events);
  late final files = _Files(events);
  late final profiles = _ProfileActions(events);
  late final setup = _Setup(events);
  final proxies = _ProxyActions();
  final controller = _Controller();
  late final ProviderContainer container;
  Future<bool> Function()? connectivityHook;

  _Harness({List<Profile> initial = const [], bool managed = false}) {
    container = ProviderContainer(
      overrides: [
        harmonyAccountApiProvider.overrideWithValue(api),
        harmonyProfileStoreProvider.overrideWithValue(files),
        harmonyCoreControllerProvider.overrideWithValue(controller),
        harmonyManagedRoutingProvider.overrideWithValue(managed),
        harmonyConnectivityCheckProvider.overrideWithValue(
          () => connectivityHook?.call() ?? Future<bool>.value(true),
        ),
        profilesProvider.overrideWith(() => _Profiles(initial)),
        profilesActionProvider.overrideWith(() => profiles),
        coreActionProvider.overrideWith(() => _CoreActions(events)),
        setupActionProvider.overrideWith(() => setup),
        proxiesActionProvider.overrideWith(() => proxies),
        currentProfileIdProvider.overrideWithBuild((_, _) => null),
      ],
    );
    // Keep auto-dispose state alive across awaited notifier operations, as the
    // dashboard does, instead of letting test timing reset selected profiles.
    container.listen(currentProfileIdProvider, (_, _) {});
    container.listen(runTimeProvider, (_, _) {});
    container.listen(groupsProvider, (_, _) {});
    container.listen(patchClashConfigProvider, (_, _) {});
    container.listen(vpnSettingProvider, (_, _) {});
    addTearDown(container.dispose);
  }

  HarmonySimple get notifier => container.read(harmonySimpleProvider.notifier);
  HarmonySimpleState get state => container.read(harmonySimpleProvider);

  void cache({String username = 'alice', Uint8List? content}) {
    files.bytes[7] = content ?? _config;
    api.metadata = _metadata(username: username);
  }

  void installRoute({bool managed = false}) {
    final group = Group(
      name: managed ? 'Harmony Auto' : 'Main',
      type: managed ? GroupType.URLTest : GroupType.Selector,
      testUrl: 'https://example.test',
      all: const [Proxy(name: 'fast', type: 'Trojan')],
    );
    container.read(groupsProvider.notifier).value = [group];
    when(() => controller.getConfig(any())).thenAnswer((_) async {
      events.add('read-config');
      // Include the same raw subscription structure consumed by the OHOS
      // routing policy, not only the derived desktop rules list.
      return <String, dynamic>{
        'rules': ['MATCH,Main'],
        'proxies': [
          {'name': 'fast', 'type': 'trojan'},
        ],
        'proxy-groups': [
          {
            'name': 'Main',
            'type': 'select',
            'proxies': ['fast'],
          },
        ],
      };
    });
    when(
      () => controller.getHarmonyNetworkState(),
    ).thenAnswer((_) async => (connected: true, captivePortal: false));
    when(() => controller.refreshHarmonyHealth()).thenAnswer((_) async {
      events.add('refresh-managed');
      return true;
    });
    when(() => controller.getHealthDelay(any(), any())).thenAnswer((_) async {
      events.add('health-probe');
      return const Delay(name: 'fast', value: 10, url: 'https://example.test');
    });
    when(() => controller.getDelay(any(), any())).thenAnswer((_) async {
      events.add('probe');
      return const Delay(name: 'fast', value: 10, url: 'https://example.test');
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await AppLocalizations.load(const Locale('zh', 'CN'));
  });

  test(
    'runtime platform and core routing boundary work without swallowed errors',
    () async {
      final harness = _Harness();
      harness.installRoute(managed: system.isOhos);
      // Keep the platform and routing boundary outside the notifier's
      // user-facing catch so runtime compatibility failures have a useful stack.
      expect(system.isOhos, Platform.operatingSystem == 'ohos');
      final config = await harness.container
          .read(harmonyCoreControllerProvider)
          .getConfig(7);
      final rules = system.isOhos
          ? defaultRoutingRules(config)
          : List<String>.from(config['rules']);
      final groups = harness.container.read(groupsProvider);
      expect(groups, hasLength(1));
      final group = system.isOhos
          ? groups.getGroup(effectiveHarmonyAutoGroupName(config))
          : connectionGroup(groups, rules);
      expect(group, isNotNull);
      final root = group!;
      final selected = await autoSelectProxy(root, groups, (name) async {
        final delay = await harness.controller.getDelay(root.testUrl!, name);
        return delay.value;
      }, warmAutomatic: false);
      expect(selected?.name, system.isOhos ? 'Harmony Auto' : 'fast');
      expect(harness.events, ['read-config', 'probe']);
    },
  );

  test('credential failure clears busy using the real notifier', () async {
    final harness = _Harness();
    harness.api.session = null;
    harness.api.loginFailure = HarmonyAccountError.credentials;

    await harness.notifier.login('alice', 'wrong');

    expect(
      harness.state.error,
      AppLocalizations.current.harmonyCredentialsError,
    );
    expect(harness.state.busy, isFalse);
    expect(harness.state.session, isNull);
  });

  test(
    'validation failure never commits validators and a retry downloads again',
    () async {
      final harness = _Harness();
      harness.files.saveFailure = HarmonyAccountError.config;
      harness.api.downloads.addAll([
        HarmonyConfigDownload(
          bytes: _config,
          etag: '"new"',
          lastModified: 'new-date',
        ),
        HarmonyConfigDownload(
          bytes: _config,
          etag: '"new"',
          lastModified: 'new-date',
        ),
      ]);

      await harness.notifier.bootstrap();
      expect(harness.api.commits, 0);
      expect(harness.api.metadata, isNull);
      expect(harness.state.remoteProfile, isNull);
      expect(harness.state.error, AppLocalizations.current.harmonyConfigError);

      harness.files.saveFailure = null;
      await harness.notifier.bootstrap();

      expect(harness.api.requests.map((request) => request.etag), [null, null]);
      expect(harness.api.commits, 1);
      expect(harness.api.metadata?.lastModified, 'new-date');
      expect(harness.state.remoteProfile, isNotNull);
      expect(harness.state.error, isNull);
      expect(harness.events.sublist(harness.events.length - 4), [
        'core-ready',
        'save',
        'put',
        'commit',
      ]);
    },
  );

  test(
    'database persistence failure cannot acknowledge downloaded validators',
    () async {
      final harness = _Harness();
      harness.profiles.putFailure = StateError('database unavailable');
      harness.api.downloads.add(
        HarmonyConfigDownload(bytes: _config, etag: '"new"'),
      );

      await harness.notifier.bootstrap();

      expect(harness.api.commits, 0);
      expect(harness.api.metadata, isNull);
      expect(harness.state.remoteProfile, isNull);
      expect(harness.state.bootstrapping, isFalse);
      expect(harness.state.error, isNotNull);
    },
  );

  test(
    'online 304 selects a verified cache without marking it offline',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      harness.api.downloads.add(const HarmonyConfigDownload(notModified: true));

      await harness.notifier.bootstrap();

      expect(harness.api.requests.single.etag, '"accepted-etag"');
      expect(harness.state.remoteProfile?.id, 7);
      expect(harness.state.usingCachedConfig, isFalse);
      expect(harness.container.read(currentProfileIdProvider), 7);
      expect(harness.events, isNot(contains('save')));
      expect(harness.state.error, isNull);
    },
  );

  test(
    'missing cache retries an unsolicited 304 once without validators',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.api.metadata = _metadata();
      harness.api.downloads.addAll([
        const HarmonyConfigDownload(notModified: true),
        HarmonyConfigDownload(bytes: _config, etag: '"fresh"'),
      ]);

      await harness.notifier.bootstrap();

      expect(harness.api.requests, hasLength(2));
      expect(harness.api.requests.map((request) => request.etag), [null, null]);
      expect(harness.state.remoteProfile, isNotNull);
      expect(harness.api.metadata?.etag, '"fresh"');
      expect(harness.state.usingCachedConfig, isFalse);
    },
  );

  test(
    'a second bodyless 304 is a config error, not an infinite retry',
    () async {
      final harness = _Harness();
      harness.api.downloads.addAll([
        const HarmonyConfigDownload(notModified: true),
        const HarmonyConfigDownload(notModified: true),
      ]);

      await harness.notifier.bootstrap();

      expect(harness.api.requests, hasLength(2));
      expect(harness.api.commits, 0);
      expect(harness.state.remoteProfile, isNull);
      expect(harness.state.error, AppLocalizations.current.harmonyConfigError);
      expect(harness.state.bootstrapping, isFalse);
    },
  );

  test(
    'transport unavailability can use only an account-bound verified cache',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      harness.api.downloads.add(HarmonyAccountError.unavailable);

      await harness.notifier.bootstrap();

      expect(harness.state.remoteProfile?.id, 7);
      expect(harness.state.usingCachedConfig, isTrue);
      expect(harness.state.error, isNull);
    },
  );

  for (final error in [
    HarmonyAccountError.config,
    HarmonyAccountError.rateLimited,
  ]) {
    test('$error does not silently activate the offline fallback', () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      harness.api.downloads.add(error);

      await harness.notifier.bootstrap();

      expect(harness.state.usingCachedConfig, isFalse);
      expect(
        harness.state.error,
        error == HarmonyAccountError.config
            ? AppLocalizations.current.harmonyConfigError
            : AppLocalizations.current.harmonyRateLimited,
      );
      expect(harness.events, isNot(contains('start')));
    });
  }

  for (final badCache in ['wrong-account', 'corrupt', 'empty', 'missing']) {
    test(
      '$badCache cache is neither conditionally requested nor used offline',
      () async {
        final harness = _Harness(initial: [_profile()]);
        harness.cache(username: badCache == 'wrong-account' ? 'bob' : 'alice');
        if (badCache == 'corrupt') {
          harness.files.bytes[7] = Uint8List.fromList([99]);
        }
        if (badCache == 'empty') {
          harness.files.bytes[7] = Uint8List(0);
        }
        if (badCache == 'missing') {
          harness.files.bytes.remove(7);
        }
        harness.api.downloads.add(HarmonyAccountError.unavailable);

        await harness.notifier.bootstrap();

        expect(harness.api.requests.single.etag, isNull);
        expect(harness.state.remoteProfile, isNull);
        expect(harness.state.usingCachedConfig, isFalse);
        expect(harness.files.deleted, contains(7));
      },
    );
  }

  test(
    'logout completes UI cleanup even if storage, stop and profile cleanup fail',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      harness.api.downloads.add(const HarmonyConfigDownload(notModified: true));
      await harness.notifier.bootstrap();
      harness.api.logoutFailure = StateError('keystore unavailable');
      harness.setup.stopFailure = StateError('core unavailable');
      harness.profiles.deleteFailure = StateError('database unavailable');
      harness.files.deleteFailure = StateError('filesystem unavailable');

      await harness.notifier.logout();

      expect(harness.state.busy, isFalse);
      expect(harness.state.disconnecting, isFalse);
      expect(harness.state.bootstrapping, isFalse);
      expect(harness.state.session, isNull);
      expect(harness.state.remoteProfile, isNull);
      expect(harness.state.usingCachedConfig, isFalse);
      expect(harness.api.isAuthorized, isFalse);
      expect(harness.files.deleted, contains(7));
    },
  );

  test(
    'config authorization expiry during bootstrap signs out and deletes cache',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      harness.api.downloads.add(HarmonyAccountError.expired);

      await harness.notifier.bootstrap();

      expect(harness.api.logouts, 1);
      expect(harness.state.session, isNull);
      expect(harness.state.remoteProfile, isNull);
      expect(
        harness.state.error,
        AppLocalizations.current.harmonySessionExpired,
      );
      expect(harness.state.busy, isFalse);
      expect(harness.state.bootstrapping, isFalse);
    },
  );

  test(
    'logout during a download cannot restore a profile or commit cache',
    () async {
      final harness = _Harness();
      final response = Completer<HarmonyConfigDownload>();
      final downloading = Completer<void>();
      harness.api.downloads.add(response.future);
      harness.api.downloadStarted = () => downloading.complete();
      final bootstrapping = harness.notifier.bootstrap();
      await downloading.future;
      await harness.notifier.logout();
      response.complete(HarmonyConfigDownload(bytes: _config, etag: '"late"'));
      await bootstrapping;

      expect(harness.api.commits, 0);
      expect(harness.state.session, isNull);
      expect(harness.state.remoteProfile, isNull);
      expect(harness.state.busy, isFalse);
      expect(harness.state.bootstrapping, isFalse);
      expect(harness.events, isNot(contains('save')));
    },
  );

  test(
    'logout during cached-file verification cannot resurrect that profile',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      final reading = Completer<void>();
      final read = Completer<Uint8List?>();
      harness.files.readHook = (_) {
        if (!reading.isCompleted) {
          reading.complete();
        }
        return read.future;
      };
      final bootstrapping = harness.notifier.bootstrap();
      await reading.future;
      await harness.notifier.logout();
      read.complete(_config);
      await bootstrapping;

      expect(harness.state.session, isNull);
      expect(harness.state.remoteProfile, isNull);
      expect(harness.state.usingCachedConfig, isFalse);
      expect(harness.api.requests, isEmpty);
    },
  );

  for (final stage in ['save', 'database']) {
    test(
      'logout joins an in-flight $stage before deleting its profile',
      () async {
        final harness = _Harness();
        final entered = Completer<void>();
        final release = Completer<void>();
        if (stage == 'save') {
          harness.files.saveHook = (_, _) {
            entered.complete();
            return release.future;
          };
        } else {
          harness.profiles.putHook = (_) {
            entered.complete();
            return release.future;
          };
        }
        harness.api.downloads.add(
          HarmonyConfigDownload(bytes: _config, etag: '"late"'),
        );
        final bootstrapping = harness.notifier.bootstrap();
        await entered.future;
        final loggingOut = harness.notifier.logout();
        expect(harness.state.session, isNull);
        expect(harness.api.isAuthorized, isFalse);
        expect(harness.state.busy, isTrue);
        release.complete();
        await Future.wait([bootstrapping, loggingOut]);

        expect(harness.api.commits, 0);
        expect(harness.container.read(profilesProvider), isEmpty);
        expect(harness.files.bytes, isEmpty);
        expect(harness.state.session, isNull);
        expect(harness.state.remoteProfile, isNull);
        expect(harness.state.busy, isFalse);
        expect(harness.state.bootstrapping, isFalse);
      },
    );
  }

  test(
    'connect errors clear busy even when the native stop operation also fails',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      harness.api.downloads.add(const HarmonyConfigDownload(notModified: true));
      await harness.notifier.bootstrap();
      harness.api.downloads.add(HarmonyAccountError.rateLimited);
      harness.setup.stopFailure = StateError('native service unavailable');

      await harness.notifier.toggleConnect();

      expect(harness.state.error, AppLocalizations.current.harmonyRateLimited);
      expect(harness.state.busy, isFalse);
      expect(harness.state.disconnecting, isFalse);
      expect(harness.state.usingCachedConfig, isFalse);
      expect(harness.setup.starts, isEmpty);
    },
  );

  test(
    'an expired periodic session check signs out without retaining profile access',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      harness.api.downloads.add(const HarmonyConfigDownload(notModified: true));
      await harness.notifier.bootstrap();
      harness.api.restoreFailure = HarmonyAccountError.expired;

      await harness.notifier.checkSession();

      expect(harness.state.session, isNull);
      expect(harness.state.remoteProfile, isNull);
      expect(
        harness.state.error,
        AppLocalizations.current.harmonySessionExpired,
      );
      expect(harness.state.busy, isFalse);
      expect(harness.api.logouts, 1);
    },
  );

  test(
    'connect applies once and preserves the selected route when starting',
    () async {
      final harness = _Harness(initial: [_profile()]);
      harness.cache();
      harness.api.downloads.addAll([
        const HarmonyConfigDownload(notModified: true),
        const HarmonyConfigDownload(notModified: true),
      ]);
      await harness.notifier.bootstrap();
      harness.installRoute();

      await harness.notifier.toggleConnect();

      expect(
        harness.state.error,
        isNull,
        reason: 'Connection events: ${harness.events}',
      );
      expect(harness.setup.applies, 1);
      expect(harness.setup.starts, [(isInit: true, profileApplied: true)]);
      expect(harness.proxies.changes, {'Main': 'fast'});
      expect(harness.profiles.selections, {'Main': 'fast'});
      expect(harness.container.read(isStartProvider), isTrue);
      expect(harness.state.error, isNull);
      expect(harness.state.busy, isFalse);
      expect(harness.state.actualConnected, isTrue);
      expect(harness.state.connectionRequested, isTrue);
    },
  );

  test('a late successful probe cannot start VPN after logout', () async {
    final harness = _Harness(initial: [_profile()]);
    harness.cache();
    harness.api.downloads.addAll([
      const HarmonyConfigDownload(notModified: true),
      const HarmonyConfigDownload(notModified: true),
    ]);
    await harness.notifier.bootstrap();
    harness.installRoute();
    final probing = Completer<void>();
    final probe = Completer<Delay>();
    when(() => harness.controller.getHealthDelay(any(), any())).thenAnswer((_) {
      if (!probing.isCompleted) probing.complete();
      return probe.future;
    });
    final connecting = harness.notifier.toggleConnect();
    await Future.any([
      probing.future,
      connecting.then((_) {
        if (!probing.isCompleted) {
          fail(
            'Connection ended before probing: ${harness.state.error}; events: ${harness.events}',
          );
        }
      }),
    ]);
    await harness.notifier.logout();
    probe.complete(
      const Delay(name: 'fast', value: 1, url: 'https://example.test'),
    );
    await connecting;

    expect(harness.setup.starts, isEmpty);
    expect(harness.proxies.changes, isEmpty);
    expect(harness.state.session, isNull);
    expect(harness.state.remoteProfile, isNull);
    expect(harness.state.busy, isFalse);
    expect(harness.state.disconnecting, isFalse);
  });

  Future<_Harness> connectedHarness({bool managed = false}) async {
    final harness = _Harness(initial: [_profile()], managed: managed);
    harness.cache();
    harness.api.downloads.addAll([
      const HarmonyConfigDownload(notModified: true),
      const HarmonyConfigDownload(notModified: true),
    ]);
    await harness.notifier.bootstrap();
    harness.installRoute(managed: managed);
    await harness.notifier.toggleConnect();
    expect(harness.state.actualConnected, isTrue);
    return harness;
  }

  test(
    'failed recovery preserves direct flows and reuses installed config',
    () async {
      final harness = await connectedHarness();
      final requests = harness.api.requests.length;
      final applies = harness.setup.applies;
      when(() => harness.controller.getHealthDelay(any(), any())).thenAnswer(
        (invocation) async => Delay(
          name: invocation.positionalArguments[1] as String,
          value: invocation.positionalArguments[1] == 'DIRECT' ? 10 : -1,
          url: invocation.positionalArguments[0] as String,
        ),
      );

      await harness.notifier.retryConnect();
      await harness.notifier.retryConnect();

      expect(harness.state.health, HarmonyConnectionHealth.degraded);
      expect(harness.state.actualConnected, isFalse);
      expect(harness.state.domesticHealthy, isTrue);
      expect(harness.state.foreignHealthy, isFalse);
      expect(harness.state.connectionRequested, isTrue);
      expect(harness.state.busy, isFalse);
      expect(harness.state.nextRetryAt, isNotNull);
      expect(harness.container.read(isStartProvider), isTrue);
      expect(harness.api.requests.length, requests);
      expect(harness.setup.applies, applies);
      expect(harness.setup.starts, hasLength(1));
      expect(harness.events, isNot(contains('stop')));
    },
  );

  test('domestic failure does not reselect a working overseas route', () async {
    final harness = await connectedHarness();
    harness.proxies.changes.clear();
    when(() => harness.controller.getHealthDelay(any(), any())).thenAnswer(
      (invocation) async => Delay(
        name: invocation.positionalArguments[1] as String,
        value: invocation.positionalArguments[1] == 'DIRECT' ? -1 : 10,
        url: invocation.positionalArguments[0] as String,
      ),
    );

    await harness.notifier.retryConnect();

    expect(harness.state.health, HarmonyConnectionHealth.degraded);
    expect(harness.state.domesticHealthy, isFalse);
    expect(harness.state.foreignHealthy, isTrue);
    expect(harness.proxies.changes, isEmpty);
    expect(harness.events, isNot(contains('stop')));
  });

  test('offline retains intent, while manual disconnect cancels it', () async {
    final harness = await connectedHarness();
    harness.notifier.handleNetworkChanged(connected: false);
    expect(harness.state.health, HarmonyConnectionHealth.offline);
    expect(harness.state.actualConnected, isFalse);
    expect(harness.state.connectionRequested, isTrue);
    expect(harness.events, isNot(contains('stop')));

    await harness.notifier.toggleConnect();
    harness.notifier.handleNetworkChanged(connected: true);

    expect(harness.state.connectionRequested, isFalse);
    expect(harness.state.health, HarmonyConnectionHealth.disconnected);
    expect(harness.container.read(isStartProvider), isFalse);
    expect(harness.setup.starts, hasLength(1));
  });

  test('network change discards a previous successful health result', () async {
    final harness = await connectedHarness();
    final started = Completer<void>();
    final delayed = Completer<Delay>();
    when(() => harness.controller.getHealthDelay(any(), any())).thenAnswer((_) {
      if (!started.isCompleted) started.complete();
      return delayed.future;
    });
    final recovering = harness.notifier.retryConnect();
    await started.future;
    harness.notifier.handleNetworkChanged(connected: false);
    delayed.complete(
      const Delay(name: 'fast', value: 1, url: 'https://example.test'),
    );
    await recovering;

    expect(harness.state.health, HarmonyConnectionHealth.offline);
    expect(harness.state.actualConnected, isFalse);
    expect(harness.state.domesticHealthy, isNull);
    expect(harness.state.foreignHealthy, isNull);
  });

  test('logout joins submitted native start before stopping it', () async {
    final harness = _Harness(initial: [_profile()]);
    harness.cache();
    harness.api.downloads.addAll([
      const HarmonyConfigDownload(notModified: true),
      const HarmonyConfigDownload(notModified: true),
    ]);
    await harness.notifier.bootstrap();
    harness.installRoute();
    final entered = Completer<void>();
    final released = Completer<void>();
    harness.setup.startHook = () {
      entered.complete();
      return released.future;
    };
    final connecting = harness.notifier.toggleConnect();
    await entered.future;
    final loggingOut = harness.notifier.logout();
    expect(harness.state.session, isNull);
    expect(harness.state.connectionRequested, isFalse);
    released.complete();
    await Future.wait([connecting, loggingOut]);

    expect(
      harness.events.indexOf('start'),
      lessThan(harness.events.indexOf('stop')),
    );
    expect(harness.container.read(isStartProvider), isFalse);
    expect(harness.state.actualConnected, isFalse);
    expect(harness.state.session, isNull);
  });

  test(
    'managed failover refreshes shared health before strict root validation',
    () async {
      final harness = await connectedHarness(managed: true);
      harness.events.clear();
      var refreshed = false;
      when(() => harness.controller.refreshHarmonyHealth()).thenAnswer((
        _,
      ) async {
        harness.events.add('refresh-managed');
        refreshed = true;
        return true;
      });
      when(() => harness.controller.getHealthDelay(any(), any())).thenAnswer((
        invocation,
      ) async {
        final name = invocation.positionalArguments[1] as String;
        harness.events.add('health-$name');
        return Delay(
          name: name,
          value: name == 'DIRECT' || refreshed ? 10 : -1,
          url: invocation.positionalArguments[0] as String,
        );
      });

      await harness.notifier.retryConnect();

      expect(harness.state.actualConnected, isTrue);
      expect(harness.events, contains('refresh-managed'));
      expect(
        harness.events.lastIndexOf('health-Harmony Auto'),
        greaterThan(harness.events.indexOf('refresh-managed')),
      );
      expect(
        harness.events.where((event) => event == 'health-Harmony Auto'),
        hasLength(2),
        reason: 'One failed root check and one verified recovery',
      );
      expect(
        harness.proxies.changes,
        isEmpty,
        reason: 'The managed automatic group must not pin a leaf',
      );
      expect(harness.api.requests, hasLength(2));
      expect(harness.setup.applies, 1);
      expect(harness.setup.starts, hasLength(1));
      expect(harness.events, isNot(contains('stop')));
    },
  );

  test(
    'typed errors resolve with the locale supplied by the current UI',
    () async {
      const state = HarmonySimpleState(
        errorCause: HarmonySimpleError.credentials,
      );
      final english = await AppLocalizations.load(const Locale('en'));
      expect(state.resolveError(english), english.harmonyCredentialsError);
      final chinese = await AppLocalizations.load(const Locale('zh', 'CN'));
      expect(state.resolveError(chinese), chinese.harmonyCredentialsError);
      expect(state.error, chinese.harmonyCredentialsError);
    },
  );

  test(
    'confirmed OS portal pauses probes and clears without a Wi-Fi type change',
    () async {
      final harness = await connectedHarness(managed: true);
      harness.events.clear();
      when(
        () => harness.controller.getHarmonyNetworkState(),
      ).thenAnswer((_) async => (connected: true, captivePortal: true));

      await harness.notifier.retryConnect();

      expect(harness.state.health, HarmonyConnectionHealth.captivePortal);
      expect(harness.state.actualConnected, isFalse);
      expect(harness.state.domesticHealthy, isNull);
      expect(harness.state.foreignHealthy, isNull);
      expect(harness.state.connectionRequested, isTrue);
      expect(
        harness.events,
        isEmpty,
        reason: 'Portal checks must not fan out probes',
      );
      when(
        () => harness.controller.getHarmonyNetworkState(),
      ).thenAnswer((_) async => (connected: true, captivePortal: false));
      await harness.notifier.retryConnect();
      expect(harness.state.actualConnected, isTrue);
      expect(harness.api.requests, hasLength(2));
      expect(harness.setup.starts, hasLength(1));
    },
  );

  test(
    'a delayed resume lookup cannot restart foreground work after pause',
    () async {
      final harness = await connectedHarness();
      harness.notifier.onAppPaused();
      final checking = Completer<void>();
      final available = Completer<bool>();
      harness.connectivityHook = () {
        checking.complete();
        return available.future;
      };
      harness.events.clear();
      final resuming = harness.notifier.onAppResumed();
      await checking.future;
      harness.notifier.onAppPaused();
      available.complete(true);
      await resuming;

      expect(harness.state.actualConnected, isFalse);
      expect(harness.state.connectionRequested, isTrue);
      expect(harness.events, isEmpty);
    },
  );

  for (final rootHealthy in [true, false]) {
    test(
      'managed provider-name collision requires native strict success: $rootHealthy',
      () async {
        final harness = _Harness(initial: [_profile()], managed: true);
        harness.cache();
        harness.api.downloads.addAll([
          const HarmonyConfigDownload(notModified: true),
          const HarmonyConfigDownload(notModified: true),
        ]);
        await harness.notifier.bootstrap();
        harness.installRoute(managed: true);
        harness.container.read(groupsProvider.notifier).value = const [
          Group(
            name: 'Harmony Auto',
            type: GroupType.URLTest,
            all: [Proxy(name: 'Harmony Auto', type: 'Trojan')],
          ),
        ];
        harness.events.clear();
        when(() => harness.controller.getHealthDelay(any(), any())).thenAnswer((
          invocation,
        ) async {
          final name = invocation.positionalArguments[1] as String;
          harness.events.add('health-$name');
          return Delay(
            name: name,
            value: name == 'DIRECT' || rootHealthy ? 10 : -1,
            url: invocation.positionalArguments[0] as String,
          );
        });

        await harness.notifier.toggleConnect();

        expect(harness.state.actualConnected, rootHealthy);
        expect(
          harness.state.health,
          rootHealthy
              ? HarmonyConnectionHealth.connected
              : HarmonyConnectionHealth.noRoute,
        );
        expect(
          harness.events.where((event) => event == 'health-Harmony Auto'),
          hasLength(1),
          reason:
              'Verify the native managed root exactly once, never a leaf alias',
        );
        expect(
          harness.events.indexOf('refresh-managed'),
          lessThan(harness.events.indexOf('health-Harmony Auto')),
        );
        expect(harness.proxies.changes, isEmpty);
        expect(harness.setup.starts, hasLength(rootHealthy ? 1 : 0));
        expect(harness.api.requests, hasLength(2));
      },
    );
  }
}
