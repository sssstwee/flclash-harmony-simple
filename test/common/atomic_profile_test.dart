import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/atomic_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File profile;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile-write-test-');
    profile = File('${directory.path}/profile.yaml');
    await profile.writeAsString('accepted');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'validation failure preserves last accepted bytes and removes staging',
    () async {
      await expectLater(
        replaceProfileFile(
          profile,
          utf8.encode('rejected'),
          (_) async => 'invalid',
        ),
        throwsA('invalid'),
      );
      expect(await profile.readAsString(), 'accepted');
      expect(await directory.list().length, 1);
    },
  );

  test(
    'validation exception preserves the destination and permits retry',
    () async {
      await expectLater(
        replaceProfileFile(
          profile,
          utf8.encode('new'),
          (_) async => throw StateError('core'),
        ),
        throwsStateError,
      );
      await replaceProfileFile(profile, utf8.encode('new'), (path) async {
        expect(await File(path).readAsString(), 'new');
        expect(await profile.readAsString(), 'accepted');
        expect(File(path).parent.parent.path, directory.path);
        return '';
      });
      expect(await profile.readAsString(), 'new');
      expect(await directory.list().length, 1);
    },
  );

  test(
    'overlapping imports use distinct staging and never expose partial bytes',
    () async {
      final firstReady = Completer<void>();
      final releaseFirst = Completer<void>();
      String? firstPath;
      final first = replaceProfileFile(profile, utf8.encode('first'), (
        path,
      ) async {
        firstPath = path;
        firstReady.complete();
        await releaseFirst.future;
        expect(await File(path).readAsString(), 'first');
        return '';
      });
      await firstReady.future;
      await replaceProfileFile(profile, utf8.encode('second'), (path) async {
        expect(path, isNot(firstPath));
        expect(await profile.readAsString(), 'accepted');
        return '';
      });
      expect(await profile.readAsString(), 'second');
      releaseFirst.complete();
      await first;
      expect(await profile.readAsString(), 'first');
      expect(await directory.list().length, 1);
    },
  );

  test('failed first validation does not create an empty profile', () async {
    await profile.delete();
    await expectLater(
      replaceProfileFile(profile, utf8.encode('bad'), (_) async => 'invalid'),
      throwsA('invalid'),
    );
    expect(await profile.exists(), isFalse);
    expect(await directory.list().length, 0);
  });
}
