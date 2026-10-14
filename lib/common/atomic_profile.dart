import 'dart:io';

/// Validates a complete staged file before atomically replacing the destination.
/// Staging beside the destination keeps the final rename on one filesystem.
Future<void> replaceProfileFile(
  File destination,
  List<int> bytes,
  Future<String> Function(String path) validate,
) async {
  await destination.parent.create(recursive: true);
  final temporary = await destination.parent.createTemp('.profile-');
  final staged = File('${temporary.path}/config.yaml');
  try {
    await staged.writeAsBytes(bytes, flush: true);
    final message = await validate(staged.path);
    if (message.isNotEmpty) throw message;
    await staged.rename(destination.path);
  } finally {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  }
}
