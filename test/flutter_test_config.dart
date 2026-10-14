import 'dart:async';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  static const _root = '/tmp/fl_clash_test';

  Future<String> _path(String segment) async => '$_root/$segment';

  @override
  Future<String?> getApplicationSupportPath() => _path('support');

  @override
  Future<String?> getTemporaryPath() => _path('temp');

  @override
  Future<String?> getApplicationCachePath() => _path('cache');

  @override
  Future<String?> getDownloadsPath() => _path('downloads');
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PathProviderPlatform.instance = _FakePathProvider();
  await testMain();
}
