import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/verified_profile_backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File primary;
  late VerifiedProfileBackup backup;
  final accepted = Uint8List.fromList('accepted profile'.codeUnits);
  final replacement = Uint8List.fromList('replacement profile'.codeUnits);
  final acceptedHash = sha256.convert(accepted).toString();
  final replacementHash = sha256.convert(replacement).toString();

  File stored(String hash, {int profileId = 7}) => File(
    '${directory.path}/.harmony-accepted/$profileId/$hash.yaml',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('verified-profile-test-');
    primary = File('${directory.path}/7.yaml');
    await primary.writeAsBytes(accepted);
    backup = VerifiedProfileBackup(primary, 7);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'preserves and restores verified bytes without changing primary early',
    () async {
      await backup.preserve(accepted, acceptedHash);

      expect(await primary.readAsBytes(), orderedEquals(accepted));
      expect(await backup.read(acceptedHash), orderedEquals(accepted));
      expect(await stored(acceptedHash).readAsBytes(), orderedEquals(accepted));

      await primary.writeAsBytes(replacement);
      await backup.restore((await backup.read(acceptedHash))!, acceptedHash);

      expect(await primary.readAsBytes(), orderedEquals(accepted));
      expect(await backup.read(acceptedHash), orderedEquals(accepted));
    },
  );

  test('missing and corrupt backups are unusable', () async {
    expect(await backup.read(acceptedHash), isNull);
    await backup.preserve(accepted, acceptedHash);
    await stored(acceptedHash).writeAsBytes(replacement);

    expect(await backup.read(acceptedHash), isNull);
    expect(await primary.readAsBytes(), orderedEquals(accepted));
  });

  test(
    'invalid hashes and mismatching bytes cannot overwrite accepted data',
    () async {
      await backup.preserve(accepted, acceptedHash);
      await expectLater(
        backup.preserve(replacement, acceptedHash),
        throwsArgumentError,
      );
      await expectLater(
        backup.restore(replacement, acceptedHash),
        throwsArgumentError,
      );
      for (final invalid in ['../outside', 'short', 'A' * 64]) {
        await expectLater(backup.read(invalid), throwsArgumentError);
        await expectLater(backup.preserve(accepted, invalid), throwsArgumentError);
        await expectLater(backup.restore(accepted, invalid), throwsArgumentError);
      }

      expect(await primary.readAsBytes(), orderedEquals(accepted));
      expect(await backup.read(acceptedHash), orderedEquals(accepted));
    },
  );

  test('backup write failure leaves the primary untouched', () async {
    await File('${directory.path}/.harmony-accepted').writeAsString('blocked');

    await expectLater(
      backup.preserve(accepted, acceptedHash),
      throwsA(isA<FileSystemException>()),
    );

    expect(await primary.readAsBytes(), orderedEquals(accepted));
  });

  test(
    'restore failure retains the verified backup for another attempt',
    () async {
      await backup.preserve(accepted, acceptedHash);
      await primary.delete();
      await Directory(primary.path).create();

      await expectLater(
        backup.restore(accepted, acceptedHash),
        throwsA(isA<FileSystemException>()),
      );

      expect(await backup.read(acceptedHash), orderedEquals(accepted));
      await Directory(primary.path).delete();
      await backup.restore(accepted, acceptedHash);
      expect(await primary.readAsBytes(), orderedEquals(accepted));
    },
  );

  test('a backup read IO error is not reported as missing or corrupt', () async {
    await Directory(stored(acceptedHash).path).create(recursive: true);

    await expectLater(
      backup.read(acceptedHash),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'prunes only other hash-named backup files after successful preservation',
    () async {
      await backup.preserve(accepted, acceptedHash);
      final unrelated = File('${stored(acceptedHash).parent.path}/keep.txt');
      await unrelated.writeAsString('unrelated');
      final nested = Directory(
        '${stored(acceptedHash).parent.path}/${'b' * 64}.yaml',
      );
      await nested.create();
      final otherBackup = VerifiedProfileBackup(primary, 8);
      await otherBackup.preserve(accepted, acceptedHash);

      await backup.preserve(replacement, replacementHash);

      expect(await backup.read(acceptedHash), isNull);
      expect(await backup.read(replacementHash), orderedEquals(replacement));
      expect(await unrelated.readAsString(), 'unrelated');
      expect(await nested.exists(), isTrue);
      expect(await otherBackup.read(acceptedHash), orderedEquals(accepted));
      expect(await primary.readAsBytes(), orderedEquals(accepted));
    },
  );

  test('failed preservation never prunes the last verified backup', () async {
    await backup.preserve(accepted, acceptedHash);
    await Directory(stored(replacementHash).path).create();

    await expectLater(
      backup.preserve(replacement, replacementHash),
      throwsA(isA<FileSystemException>()),
    );

    expect(await backup.read(acceptedHash), orderedEquals(accepted));
    expect(await primary.readAsBytes(), orderedEquals(accepted));
  });

  test(
    'clear removes only this profile backup directory and is repeatable',
    () async {
      await backup.preserve(accepted, acceptedHash);
      final otherBackup = VerifiedProfileBackup(primary, 8);
      await otherBackup.preserve(replacement, replacementHash);

      await backup.clear();
      await backup.clear();

      expect(await stored(acceptedHash).parent.exists(), isFalse);
      expect(await otherBackup.read(replacementHash), orderedEquals(replacement));
      expect(await primary.readAsBytes(), orderedEquals(accepted));
    },
  );
}
