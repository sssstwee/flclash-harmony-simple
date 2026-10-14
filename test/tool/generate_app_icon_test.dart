import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import '../../tool/generate_app_icon.dart' as icons;

Future<bool> _hasRenderer() async {
  try {
    final result = await Process.run('rsvg-convert', ['--version']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<ui.Image> _readImage(File file) async {
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

List<int> _pixel(ByteData data, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return List.generate(4, (channel) => data.getUint8(offset + channel));
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasRenderer = await _hasRenderer();

  test('launcher layers use distinct sources and retain full app badges', () {
    expect(icons.outputs, [
      (path: 'assets/images/icon.png', source: icons.source, size: 512),
      (
        path: 'ohos/AppScope/resources/base/media/background.png',
        source: icons.backgroundSource,
        size: 512,
      ),
      (
        path: 'ohos/AppScope/resources/base/media/foreground.png',
        source: icons.foregroundSource,
        size: 432,
      ),
      (
        path: 'ohos/entry/src/main/resources/base/media/icon.png',
        source: icons.source,
        size: 256,
      ),
    ]);
    expect({
      icons.source,
      icons.backgroundSource,
      icons.foregroundSource,
    }, hasLength(3));
    final full = File(icons.source).readAsStringSync();
    final background = File(icons.backgroundSource).readAsStringSync();
    final foreground = File(icons.foregroundSource).readAsStringSync();
    expect(background, contains('<rect width="512" height="512"'));
    expect(background, isNot(contains('rx=')));
    expect(background, isNot(contains('<path')));
    expect(background, contains('fill="#FFFFFF"'));
    expect(foreground, isNot(contains('<rect')));
    final awake = File('assets/images/cat_awake.svg').readAsStringSync();
    final sleeping = File('assets/images/cat_sleeping.svg').readAsStringSync();
    final artwork = RegExp(r'<g id="cat">[\s\S]*?</g>');
    final awakeArtwork = artwork.firstMatch(awake)?.group(0);
    expect(awakeArtwork, isNotNull);
    expect(artwork.firstMatch(full)?.group(0), awakeArtwork);
    expect(artwork.firstMatch(foreground)?.group(0), awakeArtwork);
    for (final source in [awake, sleeping, full, foreground, background]) {
      expect(source, isNot(contains('currentColor')));
      expect(source, isNot(contains('linearGradient')));
      expect(
        RegExp(r'#[0-9a-fA-F]{6}').allMatches(source).map((m) => m.group(0)),
        everyElement(isIn(['#FFFFFF', '#000000'])),
      );
    }
    final layeredImage = jsonDecode(
      File(
        'ohos/AppScope/resources/base/media/layered_image.json',
      ).readAsStringSync(),
    );
    expect(layeredImage['layered-image'], {
      'background': r'$media:background',
      'foreground': r'$media:foreground',
    });
  });

  test(
    'generated foreground is transparent over an opaque background',
    () async {
      final destination = await Directory.systemTemp.createTemp(
        'harmony-icon-',
      );
      addTearDown(() => destination.delete(recursive: true));
      await icons.generateAppIcons(
        renderer: 'rsvg-convert',
        outputDirectory: destination,
      );
      final images = <String, ui.Image>{};
      for (final output in icons.outputs) {
        final image = await _readImage(
          File.fromUri(destination.uri.resolve(output.path)),
        );
        addTearDown(image.dispose);
        expect(image.width, output.size, reason: output.path);
        expect(image.height, output.size, reason: output.path);
        images[output.path] = image;
      }
      final background =
          images['ohos/AppScope/resources/base/media/background.png']!;
      final foreground =
          images['ohos/AppScope/resources/base/media/foreground.png']!;
      final backgroundData = (await background.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final foregroundData = (await foreground.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      expect([
        for (var i = 3; i < backgroundData.lengthInBytes; i += 4)
          backgroundData.getUint8(i),
      ], everyElement(255));
      for (final point in [(0, 0), (431, 0), (0, 431), (431, 431), (0, 216)]) {
        expect(_pixel(foregroundData, 432, point.$1, point.$2).last, 0);
      }
      expect(_pixel(foregroundData, 432, 216, 216).last, 255);
      expect(_pixel(backgroundData, 512, 256, 256), [255, 255, 255, 255]);
      expect(_pixel(foregroundData, 432, 216, 297), [0, 0, 0, 255]);

      // Layering must leave the white background visible outside the cat.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImage(background, ui.Offset.zero, ui.Paint());
      canvas.drawImage(foreground, const ui.Offset(40, 40), ui.Paint());
      final picture = recorder.endRecording();
      addTearDown(picture.dispose);
      final composite = await picture.toImage(512, 512);
      addTearDown(composite.dispose);
      final compositeData = (await composite.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      for (final point in [(0, 0), (40, 40), (40, 256), (511, 511)]) {
        expect(
          _pixel(compositeData, 512, point.$1, point.$2),
          _pixel(backgroundData, 512, point.$1, point.$2),
        );
      }
      expect(
        _pixel(compositeData, 512, 256, 256),
        _pixel(foregroundData, 432, 216, 216),
      );

      final full = images['assets/images/icon.png']!;
      final fullData = (await full.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      // The complete badge and launcher layers use the same artwork and scale.
      for (final point in [(128, 128), (180, 290), (256, 256), (350, 350)]) {
        expect(
          _pixel(compositeData, 512, point.$1, point.$2),
          _pixel(fullData, 512, point.$1, point.$2),
        );
      }
      expect(_pixel(fullData, 512, 0, 0).last, 0);
    },
    skip: hasRenderer
        ? false
        : 'Install librsvg2-bin to verify rendered icons.',
  );
}
