import 'dart:io';

const source = 'assets_source/images/app_icon.svg';
const backgroundSource = 'assets_source/images/app_icon_background.svg';
const foregroundSource = 'assets_source/images/app_icon_foreground.svg';
const outputs = <({String path, String source, int size})>[
  (path: 'assets/images/icon.png', source: source, size: 512),
  (
    path: 'ohos/AppScope/resources/base/media/background.png',
    source: backgroundSource,
    size: 512,
  ),
  (
    path: 'ohos/AppScope/resources/base/media/foreground.png',
    source: foregroundSource,
    size: 432,
  ),
  (
    path: 'ohos/entry/src/main/resources/base/media/icon.png',
    source: source,
    size: 256,
  ),
];

Future<void> main() async {
  final rsvgConvert = await _findExecutable('rsvg-convert');
  if (rsvgConvert == null) {
    stderr.writeln('rsvg-convert is required to generate app icons.');
    exitCode = 1;
    return;
  }
  try {
    await generateAppIcons(renderer: rsvgConvert);
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
    return;
  }
  stdout.writeln('App icons generated.');
}

/// Keeps the layered launcher artwork separate from the complete app badge.
/// An optional destination lets tests render without changing checked-in assets.
Future<void> generateAppIcons({
  required String renderer,
  Directory? outputDirectory,
}) async {
  for (final input in outputs.map((output) => output.source).toSet()) {
    if (!File(input).existsSync()) {
      throw FileSystemException('Missing app icon source', input);
    }
  }
  final destination = outputDirectory ?? Directory.current;
  for (final output in outputs) {
    final file = File.fromUri(destination.uri.resolve(output.path));
    await file.parent.create(recursive: true);
    final arguments = [
      '-w',
      '${output.size}',
      '-h',
      '${output.size}',
      output.source,
      '-o',
      file.path,
    ];
    final result = await Process.run(renderer, arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        renderer,
        arguments,
        'Failed to render ${output.path}: ${result.stderr}',
        result.exitCode,
      );
    }
  }
}

Future<String?> _findExecutable(String name) async {
  final result = await Process.run('which', [name]);
  if (result.exitCode != 0) return null;
  final path = '${result.stdout}'.trim();
  return path.isEmpty ? null : path;
}
