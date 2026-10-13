import 'dart:io';

const source = 'assets_source/images/app_icon.svg';
const outputs = <({String path, int size})>[
  (path: 'assets/images/icon.png', size: 512),
  (path: 'ohos/AppScope/resources/base/media/background.png', size: 512),
  (path: 'ohos/AppScope/resources/base/media/foreground.png', size: 432),
  (path: 'ohos/entry/src/main/resources/base/media/icon.png', size: 256),
];

Future<void> main() async {
  final rsvgConvert = await _findExecutable('rsvg-convert');
  if (rsvgConvert == null) {
    stderr.writeln('rsvg-convert is required to generate app icons.');
    exitCode = 1;
    return;
  }
  final sourceFile = File(source);
  if (!sourceFile.existsSync()) {
    stderr.writeln('Missing $source');
    exitCode = 1;
    return;
  }
  for (final output in outputs) {
    final file = File(output.path);
    await file.parent.create(recursive: true);
    final result = await Process.run(rsvgConvert, [
      '-w',
      '${output.size}',
      '-h',
      '${output.size}',
      source,
      '-o',
      file.path,
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to render ${output.path}');
      exitCode = result.exitCode;
      return;
    }
  }
  stdout.writeln('App icons generated.');
}

Future<String?> _findExecutable(String name) async {
  final result = await Process.run('which', [name]);
  if (result.exitCode != 0) return null;
  final path = '${result.stdout}'.trim();
  return path.isEmpty ? null : path;
}
