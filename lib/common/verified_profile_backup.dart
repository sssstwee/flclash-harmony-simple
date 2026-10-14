import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/atomic_profile.dart';

/// Keeps previously accepted bytes until secure cache metadata selects a version.
/// Callers must obtain the hash from the current account's trusted metadata.
class VerifiedProfileBackup {
  final File primary;
  final int profileId;

  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _backupNamePattern = RegExp(r'^[a-f0-9]{64}\.yaml$');

  const VerifiedProfileBackup(this.primary, this.profileId);

  Directory get _directory => Directory(
    '${primary.parent.path}/.harmony-accepted/$profileId',
  );

  void _validateHash(String contentHash) {
    if (!_hashPattern.hasMatch(contentHash)) {
      throw ArgumentError.value(contentHash, 'contentHash', 'Invalid SHA-256');
    }
  }

  File _file(String contentHash) {
    _validateHash(contentHash);
    return File('${_directory.path}/$contentHash.yaml');
  }

  bool _matches(List<int> bytes, String contentHash) =>
      sha256.convert(bytes).toString() == contentHash;

  Future<void> _writeVerified(
    File destination,
    Uint8List bytes,
    String contentHash,
  ) async {
    if (!_matches(bytes, contentHash)) {
      throw ArgumentError('Profile bytes do not match the expected SHA-256');
    }
    await replaceProfileFile(destination, bytes, (path) async {
      final staged = await File(path).readAsBytes();
      return _matches(staged, contentHash)
          ? ''
          : 'Staged profile bytes failed SHA-256 verification';
    });
  }

  /// Aborts before the caller replaces its primary if protection is unavailable.
  Future<void> preserve(Uint8List bytes, String contentHash) async {
    final destination = _file(contentHash);
    await _writeVerified(destination, bytes, contentHash);
    if (await read(contentHash) == null) {
      throw FileSystemException(
        'Saved profile backup failed SHA-256 verification',
        destination.path,
      );
    }
    // Only an already verified saved generation permits retiring older backups.
    // Leftover files are preferable to losing the currently protected bytes.
    try {
      await for (final entity in _directory.list(followLinks: false)) {
        final name = entity.uri.pathSegments.last;
        if (entity is! File ||
            !_backupNamePattern.hasMatch(name) ||
            name == '$contentHash.yaml') {
          continue;
        }
        try {
          await entity.delete();
        } on FileSystemException {
          // A later successful preservation can retry cleanup.
        }
      }
    } on FileSystemException {
      // Cleanup never invalidates the backup just verified above.
    }
  }

  /// Missing/corrupt backups are unusable; other IO errors remain distinguishable.
  Future<Uint8List?> read(String contentHash) async {
    final file = _file(contentHash);
    late final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) {
        return null;
      }
      rethrow;
    }
    return _matches(bytes, contentHash) ? bytes : null;
  }

  /// Restores authenticated bytes without depending on a running proxy core.
  Future<void> restore(Uint8List bytes, String contentHash) async {
    _validateHash(contentHash);
    await _writeVerified(primary, bytes, contentHash);
  }

  /// Clears this profile's backups without touching its primary or other IDs.
  Future<void> clear() async {
    try {
      await _directory.delete(recursive: true);
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && !(Platform.isWindows && code == 3)) {
        rethrow;
      }
    }
  }
}
