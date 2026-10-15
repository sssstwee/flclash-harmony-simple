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

ui.Rect _contentBounds(ByteData data, int width, int height) {
  var left = width;
  var top = height;
  var right = 0;
  var bottom = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (_pixel(data, width, x, y).last < 128) continue;
      if (x < left) left = x;
      if (y < top) top = y;
      if (x >= right) right = x + 1;
      if (y >= bottom) bottom = y + 1;
    }
  }
  return ui.Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
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
    expect(background, contains('fill="#1765F6"'));
    expect(foreground, isNot(contains('<rect')));
    final guardian = File('assets/images/cc_guardian.svg').readAsStringSync();
    final artwork = RegExp(r'<g id="cc-guardian">[\s\S]*?</g>');
    final guardianArtwork = artwork.firstMatch(guardian)?.group(0);
    expect(guardianArtwork, isNotNull);
    expect(artwork.firstMatch(full)?.group(0), guardianArtwork);
    expect(artwork.firstMatch(foreground)?.group(0), guardianArtwork);
    for (final source in [guardian, full, foreground, background]) {
      expect(source, isNot(contains('currentColor')));
      expect(source, isNot(contains('linearGradient')));
      expect(
        RegExp(r'#[0-9a-fA-F]{6}').allMatches(source).map((m) => m.group(0)),
        everyElement(isIn(['#1765F6', '#F8FBFF'])),
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
      expect(_pixel(backgroundData, 512, 256, 256), [23, 101, 246, 255]);
      final bounds = _contentBounds(foregroundData, 432, 432);
      // Keep a visible safe margin after the launcher scales the whole layer.
      expect(bounds.left, greaterThanOrEqualTo(40));
      expect(bounds.top, greaterThanOrEqualTo(40));
      expect(bounds.right, lessThanOrEqualTo(392));
      expect(bounds.bottom, lessThanOrEqualTo(392));

      // Layer pixel sizes differ; the launcher fits both to the same icon box.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImage(background, ui.Offset.zero, ui.Paint());
      canvas.drawImageRect(
        foreground,
        const ui.Rect.fromLTWH(0, 0, 432, 432),
        const ui.Rect.fromLTWH(0, 0, 512, 512),
        ui.Paint()..filterQuality = ui.FilterQuality.low,
      );
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
      // Compare the artwork while allowing antialiasing differences caused by
      // scaling the 432 px foreground. The full badge has transparent corners.
      var difference = 0;
      var channels = 0;
      for (var offset = 0; offset < fullData.lengthInBytes; offset += 4) {
        if (fullData.getUint8(offset + 3) != 255) continue;
        for (var channel = 0; channel < 3; channel++) {
          difference +=
              (compositeData.getUint8(offset + channel) -
                      fullData.getUint8(offset + channel))
                  .abs();
          channels++;
        }
      }
      expect(difference / channels, lessThan(1.5));
      expect(_pixel(fullData, 512, 0, 0).last, 0);
    },
    skip: hasRenderer
        ? false
        : 'Install librsvg2-bin to verify rendered icons.',
  );
}
