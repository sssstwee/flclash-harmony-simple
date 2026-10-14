import 'dart:async';
import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _profile(int id) => Profile(
  id: id,
  label: 'Profile $id',
  autoUpdateDuration: const Duration(hours: 24),
);

class _Profiles extends Profiles {
  final List<Profile> initial;
  Object? deleteFailure;
  final deleted = <int>[];
  final puts = <Profile>[];

  _Profiles(this.initial);

  @override
  List<Profile> build() => List.of(initial);

  @override
  Future<void> putAndWait(Profile profile) async {
    puts.add(profile);
    state = [
      for (final old in state)
        if (old.id != profile.id) old,
      profile,
    ];
  }

  @override
  Future<void> delAndWait(int id) async {
    deleted.add(id);
    if (deleteFailure != null) {
      // A failed database delete leaves the previous state intact.
      throw deleteFailure!;
    }
    state = state.where((profile) => profile.id != id).toList();
  }
}

class _ProfileActions extends ProfilesAction {
  Object? cleanupFailure;
  Future<void> Function()? cleanupHook;
  final cleaned = <int>[];

  @override
  Future<void> clearEffect(int profileId) async {
    cleaned.add(profileId);
    await cleanupHook?.call();
    if (cleanupFailure != null) {
      throw cleanupFailure!;
    }
  }
}

class _Setup extends SetupAction {
  final statuses = <bool>[];

  @override
  Future<void> updateStatus(
    bool isStart, {
    bool isInit = false,
    bool profileApplied = false,
  }) async {
    statuses.add(isStart);
  }
}

class _Harness {
  late final _Profiles profiles;
  final actions = _ProfileActions();
  final setup = _Setup();
  late final ProviderContainer container;

  _Harness({required List<Profile> initial, required int? selectedId}) {
    profiles = _Profiles(initial);
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => profiles),
        profilesActionProvider.overrideWith(() => actions),
        setupActionProvider.overrideWith(() => setup),
        currentProfileIdProvider.overrideWithBuild((_, _) => selectedId),
      ],
    );
    // Match the UI's subscription across the action's asynchronous boundaries.
    container.listen(currentProfileIdProvider, (_, _) {});
    addTearDown(container.dispose);
  }

  Future<void> delete(int id) =>
      container.read(profilesActionProvider.notifier).deleteProfile(id);

  int? get selectedId => container.read(currentProfileIdProvider);

  List<int> get profileIds =>
      container.read(profilesProvider).map((profile) => profile.id).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cleanup failure selects the first remaining profile', () async {
    final harness = _Harness(
      initial: [_profile(1), _profile(3), _profile(2)],
      selectedId: 1,
    );
    const error = FileSystemException('Profile file cannot be deleted');
    harness.actions.cleanupFailure = error;

    await expectLater(harness.delete(1), throwsA(same(error)));

    expect(harness.profileIds, [3, 2]);
    expect(harness.selectedId, 3);
    expect(harness.actions.cleaned, [1]);
    expect(harness.setup.statuses, isEmpty);
  });

  test(
    'cleanup failure clears the last selected profile and requests stop',
    () async {
      final harness = _Harness(initial: [_profile(1)], selectedId: 1);
      const error = FileSystemException('Profile file cannot be deleted');
      harness.actions.cleanupFailure = error;

      await expectLater(harness.delete(1), throwsA(same(error)));

      expect(harness.profileIds, isEmpty);
      expect(harness.selectedId, isNull);
      expect(harness.setup.statuses, [false]);
    },
  );

  test('cleanup failure preserves a different selected profile', () async {
    final harness = _Harness(
      initial: [_profile(1), _profile(2)],
      selectedId: 2,
    );
    const error = FileSystemException('Profile file cannot be deleted');
    harness.actions.cleanupFailure = error;

    await expectLater(harness.delete(1), throwsA(same(error)));

    expect(harness.profileIds, [2]);
    expect(harness.selectedId, 2);
    expect(harness.setup.statuses, isEmpty);
  });

  test('database failure preserves selection and skips cleanup', () async {
    final harness = _Harness(initial: [_profile(1)], selectedId: 1);
    final error = StateError('Database delete failed');
    harness.profiles.deleteFailure = error;

    await expectLater(harness.delete(1), throwsA(same(error)));

    expect(harness.profiles.deleted, [1]);
    expect(harness.profileIds, [1]);
    expect(harness.selectedId, 1);
    expect(harness.actions.cleaned, isEmpty);
    expect(harness.setup.statuses, isEmpty);
  });

  test(
    'cleanup failure preserves a selection changed while awaiting cleanup',
    () async {
      final harness = _Harness(
        initial: [_profile(1), _profile(2), _profile(3)],
        selectedId: 1,
      );
      final cleanupStarted = Completer<void>();
      final finishCleanup = Completer<void>();
      const error = FileSystemException('Profile file cannot be deleted');
      harness.actions.cleanupFailure = error;
      harness.actions.cleanupHook = () async {
        cleanupStarted.complete();
        await finishCleanup.future;
      };

      final deletion = expectLater(harness.delete(1), throwsA(same(error)));
      await cleanupStarted.future;
      expect(harness.profileIds, [2, 3]);
      harness.container.read(currentProfileIdProvider.notifier).value = 3;
      finishCleanup.complete();
      await deletion;

      expect(harness.selectedId, 3);
      expect(harness.setup.statuses, isEmpty);
    },
  );

  test('successful cleanup selects the next profile', () async {
    final harness = _Harness(
      initial: [_profile(1), _profile(2)],
      selectedId: 1,
    );

    await harness.delete(1);

    expect(harness.profileIds, [2]);
    expect(harness.selectedId, 2);
    expect(harness.actions.cleaned, [1]);
    expect(harness.setup.statuses, isEmpty);
  });

  test(
    'successful cleanup clears the last profile and requests stop',
    () async {
      final harness = _Harness(initial: [_profile(1)], selectedId: 1);

      await harness.delete(1);

      expect(harness.profileIds, isEmpty);
      expect(harness.selectedId, isNull);
      expect(harness.actions.cleaned, [1]);
      expect(harness.setup.statuses, [false]);
    },
  );

  test('successful cleanup preserves a different selected profile', () async {
    final harness = _Harness(
      initial: [_profile(1), _profile(2)],
      selectedId: 2,
    );

    await harness.delete(1);

    expect(harness.profileIds, [2]);
    expect(harness.selectedId, 2);
    expect(harness.actions.cleaned, [1]);
    expect(harness.setup.statuses, isEmpty);
  });

  test('profile insertion keeps its default options', () async {
    final harness = _Harness(initial: [], selectedId: null);
    final profile = _profile(1);

    await harness.container
        .read(profilesActionProvider.notifier)
        .putProfile(profile);

    expect(harness.profileIds, [1]);
    expect(harness.selectedId, 1);
    expect(harness.profiles.puts.single, profile);
  });

  test('staged insertion can skip selection', () async {
    final harness = _Harness(initial: [], selectedId: null);
    final profile = _profile(1);

    await harness.container
        .read(profilesActionProvider.notifier)
        .putProfile(profile, selectIfEmpty: false);

    expect(harness.profileIds, [1]);
    expect(harness.selectedId, isNull);
    expect(harness.profiles.puts.single, profile);
  });

  test('default profile insertion preserves an existing selection', () async {
    final harness = _Harness(initial: [_profile(1)], selectedId: 1);

    await harness.container
        .read(profilesActionProvider.notifier)
        .putProfile(_profile(2));

    expect(harness.profileIds, [1, 2]);
    expect(harness.selectedId, 1);
    expect(harness.profiles.puts.single.id, 2);
  });
}
