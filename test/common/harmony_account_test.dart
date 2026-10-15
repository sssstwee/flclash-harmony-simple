import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStore extends HarmonySessionStore {
  String? token;
  String? meta;
  String? lastModified;
  String? cache;
  String? reconnect;
  String? refreshSeconds;
  String? etag;
  String? configVersion;
  String? minCheckSeconds;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async {
    token = value;
  }

  @override
  Future<void> delete() async {
    token = null;
  }

  @override
  Future<String?> readMeta() async => meta;

  @override
  Future<void> writeMeta(String value) async {
    meta = value;
  }

  @override
  Future<void> deleteMeta() async {
    meta = null;
  }

  @override
  Future<String?> readConfigLastModified() async => lastModified;

  @override
  Future<void> writeConfigLastModified(String value) async {
    lastModified = value;
  }

  @override
  Future<void> deleteConfigLastModified() async {
    lastModified = null;
  }

  @override
  Future<String?> readConfigCache() async => cache;

  @override
  Future<void> writeConfigCache(String value) async {
    cache = value;
  }

  @override
  Future<void> deleteConfigCache() async {
    cache = null;
  }

  @override
  Future<bool> readReconnectOnLaunch() async => reconnect == '1';

  @override
  Future<void> writeReconnectOnLaunch(bool value) async {
    reconnect = value ? '1' : '0';
  }

  @override
  Future<void> deleteReconnectOnLaunch() async {
    reconnect = null;
  }

  @override
  Future<int?> readConfigRefreshSeconds() async =>
      int.tryParse(refreshSeconds ?? '');

  @override
  Future<void> writeConfigRefreshSeconds(int seconds) async {
    refreshSeconds = '$seconds';
  }

  @override
  Future<void> deleteConfigRefreshSeconds() async {
    refreshSeconds = null;
  }

  @override
  Future<String?> readConfigEtag() async => etag;

  @override
  Future<void> writeConfigEtag(String value) async {
    etag = value;
  }

  @override
  Future<void> deleteConfigEtag() async {
    etag = null;
  }

  @override
  Future<String?> readConfigVersion() async => configVersion;

  @override
  Future<void> writeConfigVersion(String value) async {
    configVersion = value;
  }

  @override
  Future<void> deleteConfigVersion() async {
    configVersion = null;
  }

  @override
  Future<int?> readMinCheckSeconds() async =>
      int.tryParse(minCheckSeconds ?? '');

  @override
  Future<void> writeMinCheckSeconds(int seconds) async {
    minCheckSeconds = '$seconds';
  }

  @override
  Future<void> deleteMinCheckSeconds() async {
    minCheckSeconds = null;
  }

  @override
  Future<void> clearAll() async {
    cache = null;
    token = null;
    meta = null;
    lastModified = null;
    reconnect = null;
    refreshSeconds = null;
    etag = null;
    configVersion = null;
    minCheckSeconds = null;
  }
}

class Adapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) handler;
  Adapter(this.handler);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
  @override
  void close({bool force = false}) {}
}

class AsyncAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) handler;

  AsyncAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

class FailingStore extends MemoryStore {
  @override
  Future<void> write(String value) async => throw StateError('storage failed');
  @override
  Future<void> delete() async => throw StateError('storage failed');
  @override
  Future<void> clearAll() async => throw StateError('storage failed');
}

class WriteFailureStore extends MemoryStore {
  @override
  Future<void> write(String value) async => throw StateError('write failed');
}

class DeleteFailureStore extends MemoryStore {
  @override
  Future<void> clearAll() async => throw StateError('delete failed');
}

class BlockingCacheStore extends MemoryStore {
  final writing = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> writeConfigCache(String value) async {
    writing.complete();
    await release.future;
    cache = value;
  }
}

ResponseBody jsonBody(
  Object? data, [
  int status = 200,
  Map<String, List<String>> headers = const {},
]) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
    ...headers,
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final suffix in ['', '/']) {
    test('API base preserves port and prefix with trailing "$suffix"', () async {
      final http = Dio(
        BaseOptions(baseUrl: 'https://69.17.3.174:8444/api$suffix'),
      );
      final urls = <String>[];
      http.httpClientAdapter = Adapter((request) {
        urls.add(request.uri.toString());
        if (request.path == '/api/auth/sign-in/username' ||
            request.path == '/api/auth/get-session') {
          return jsonBody({
            'session': {
              'expiresAt': DateTime.now()
                  .add(const Duration(days: 1))
                  .toIso8601String(),
            },
            'user': {'username': 'harmony'},
          }, 200, {
            'set-auth-token': ['session-token'],
          });
        }
        if (request.path == harmonyConfigPath) {
          return ResponseBody.fromString('profile', 200);
        }
        if (request.path == harmonyConfigVersionPath) {
          return jsonBody({}, 404);
        }
        return jsonBody({'success': true});
      });
      final api = HarmonyAccountApi(http: http, storage: MemoryStore());
      await api.login('harmony', 'password');
      await api.restore();
      await api.downloadConfig();
      await api.fetchConfigVersionInfo();
      await api.logout();
      expect(urls, [
        'https://69.17.3.174:8444/api/api/auth/sign-in/username',
        'https://69.17.3.174:8444/api/api/auth/get-session',
        'https://69.17.3.174:8444/api/v1/config',
        'https://69.17.3.174:8444/api/v1/config/version',
        'https://69.17.3.174:8444/api/api/auth/sign-out',
      ]);
    });
  }
  test(
    'storage failures fail closed and still revoke the server session',
    () async {
      final store = FailingStore();
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      var signOuts = 0;
      http.httpClientAdapter = Adapter((request) {
        if (request.path == '/api/auth/sign-in/username') {
          return jsonBody({}, 200, {
            'set-auth-token': ['signed-session'],
          });
        }
        if (request.path == '/api/auth/sign-out') {
          signOuts++;
          return jsonBody({'success': true});
        }
        return jsonBody({
          'session': {
            'expiresAt': DateTime.now()
                .add(const Duration(days: 7))
                .toIso8601String(),
          },
          'user': {'username': 'harmony'},
        });
      });
      final api = HarmonyAccountApi(http: http, storage: store);
      await expectLater(
        api.login('harmony', 'password'),
        throwsA(HarmonyAccountError.unavailable),
      );
      expect(api.isAuthorized, isFalse);
      api.session = HarmonySession(
        'signed-session',
        'harmony',
        DateTime.now().add(const Duration(days: 7)),
      );
      await expectLater(api.logout(), throwsStateError);
      expect(api.isAuthorized, isFalse);
      expect(signOuts, 1);
    },
  );
  test(
    'signed tokens are stored securely, config uses authorization, logout removes access',
    () async {
      final store = MemoryStore();
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      final calls = <RequestOptions>[];
      http.httpClientAdapter = Adapter((request) {
        calls.add(request);
        if (request.path == '/api/auth/sign-in/username') {
          expect((request.data as Map)['username'], 'harmony');
          return jsonBody({}, 200, {
            'set-auth-token': ['signed-session'],
          });
        }
        expect(request.headers['Authorization'], 'Bearer signed-session');
        return switch (request.path) {
          '/api/auth/get-session' => jsonBody({
            'session': {
              'expiresAt': DateTime.now()
                  .add(const Duration(days: 7))
                  .toIso8601String(),
            },
            'user': {'username': 'harmony'},
          }),
          '/v1/config' => ResponseBody.fromString('proxies: []', 200),
          _ => jsonBody({'success': true}),
        };
      });
      final api = HarmonyAccountApi(http: http, storage: store);
      await api.login(' harmony ', 'password');
      expect(store.token, 'signed-session');
      expect(api.isAuthorized, isTrue);
      final download = await api.downloadConfig();
      expect(utf8.decode(download.bytes!), 'proxies: []');
      expect(await api.restore(), isNotNull);
      await api.logout();
      expect(store.token, isNull);
      expect(api.isAuthorized, isFalse);
      await expectLater(
        api.downloadConfig(),
        throwsA(HarmonyAccountError.expired),
      );
      expect(
        calls.where((call) => call.path == '/api/auth/sign-out').length,
        1,
      );
    },
  );

  test(
    'login reuses server-created session metadata without a second request',
    () async {
      final store = MemoryStore();
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      final calls = <String>[];
      final expiresAt = DateTime.now().add(const Duration(days: 7));
      http.httpClientAdapter = Adapter((request) {
        calls.add(request.path);
        return jsonBody(
          {
            'token': 'unsigned-body-token',
            'user': {'username': 'harmony'},
            'session': {'expiresAt': expiresAt.toIso8601String()},
          },
          200,
          {
            'set-auth-token': ['signed-session'],
          },
        );
      });
      final api = HarmonyAccountApi(http: http, storage: store);
      final session = await api.login('harmony', 'password');
      expect(calls, ['/api/auth/sign-in/username']);
      expect(session.token, 'signed-session');
      expect(session.expiresAt, expiresAt);
      expect(store.token, 'signed-session');
      await api.restore();
      expect(calls.last, '/api/auth/get-session');
    },
  );

  for (final expiry in ['invalid', '2000-01-01T00:00:00.000Z']) {
    test('invalid inline session expiry $expiry fails closed', () async {
      final store = MemoryStore();
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      var signOuts = 0;
      http.httpClientAdapter = Adapter((request) {
        if (request.path == '/api/auth/sign-out') {
          signOuts++;
          return jsonBody({'success': true});
        }
        expect(request.path, '/api/auth/sign-in/username');
        return jsonBody(
          {
            'user': {'username': 'harmony'},
            'session': {'expiresAt': expiry},
          },
          200,
          {
            'set-auth-token': ['signed-session'],
          },
        );
      });
      final api = HarmonyAccountApi(http: http, storage: store);
      await expectLater(
        api.login('harmony', 'password'),
        throwsA(HarmonyAccountError.expired),
      );
      expect(api.isAuthorized, isFalse);
      expect(store.token, isNull);
      expect(signOuts, 1);
    });
  }

  test(
    'incorrect credentials do not create a session and expired persisted tokens are removed',
    () async {
      final store = MemoryStore();
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      http.httpClientAdapter = Adapter((_) => jsonBody({}, 401));
      final api = HarmonyAccountApi(http: http, storage: store);
      await expectLater(
        api.login('harmony', 'wrong'),
        throwsA(HarmonyAccountError.credentials),
      );
      expect(store.token, isNull);
      store.token = 'expired';
      // A new process may have a persisted token. The signed-out instance must
      // never restore after its own failed login/logout.
      final restartedApi = HarmonyAccountApi(http: http, storage: store);
      await expectLater(
        restartedApi.restore(),
        throwsA(HarmonyAccountError.expired),
      );
      expect(store.token, isNull);
      expect(restartedApi.isAuthorized, isFalse);
    },
  );

  test(
    'restore keeps cached session metadata when the service is unavailable',
    () async {
      final store = MemoryStore()
        ..token = 'saved-token'
        ..meta = jsonEncode({
          'token': 'saved-token',
          'username': 'offline-user',
          'expiresAt': DateTime.now()
              .add(const Duration(days: 2))
              .toIso8601String(),
        });
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      http.httpClientAdapter = Adapter(
        (_) => throw DioException(
          requestOptions: RequestOptions(path: '/api/auth/get-session'),
          type: DioExceptionType.connectionError,
        ),
      );
      final api = HarmonyAccountApi(http: http, storage: store);
      final session = await api.restore();
      expect(session?.username, 'offline-user');
      expect(api.isAuthorized, isTrue);
    },
  );

  test(
    'plaintext API endpoints are refused before credentials are sent',
    () async {
      final http = Dio(BaseOptions(baseUrl: 'http://api.example.test'));
      http.httpClientAdapter = Adapter(
        (_) => throw StateError('must not send'),
      );
      final api = HarmonyAccountApi(http: http, storage: MemoryStore());
      await expectLater(
        api.login('harmony', 'password'),
        throwsA(HarmonyAccountError.unavailable),
      );
    },
  );

  test(
    'downloading does not acknowledge a config before it is installed',
    () async {
      final store = MemoryStore()..lastModified = 'previous-version';
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      http.httpClientAdapter = Adapter(
        (_) => ResponseBody.fromString(
          'proxies: []',
          200,
          headers: {
            'last-modified': ['new-version'],
          },
        ),
      );
      final api = HarmonyAccountApi(http: http, storage: store)
        ..session = HarmonySession(
          'token',
          'harmony',
          DateTime.now().add(const Duration(days: 1)),
        );

      final download = await api.downloadConfig(
        ifModifiedSince: 'previous-version',
      );

      expect(download.lastModified, 'new-version');
      expect(download.bytes, isNotEmpty);
      expect(store.lastModified, 'previous-version');
    },
  );

  test('conditional config requests preserve the validator on 304', () async {
    final store = MemoryStore()..lastModified = 'installed-version';
    final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    http.httpClientAdapter = Adapter((request) {
      expect(request.headers['If-Modified-Since'], 'installed-version');
      expect(request.headers['Authorization'], 'Bearer token');
      return ResponseBody.fromString('', 304);
    });
    final api = HarmonyAccountApi(http: http, storage: store)
      ..session = HarmonySession(
        'token',
        'harmony',
        DateTime.now().add(const Duration(days: 1)),
      );

    final download = await api.downloadConfig(
      ifModifiedSince: 'installed-version',
    );

    expect(download.notModified, isTrue);
    expect(download.bytes, isNull);
    expect(download.lastModified, 'installed-version');
    expect(store.lastModified, 'installed-version');
  });

  for (final size in [0, harmonyConfigMaxBytes + 1]) {
    test(
      'rejects a $size byte config without changing its validator',
      () async {
        final store = MemoryStore()..lastModified = 'installed-version';
        final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
        http.httpClientAdapter = Adapter(
          (_) => ResponseBody.fromBytes(
            List<int>.filled(size, 65),
            200,
            headers: {
              'last-modified': ['bad-version'],
            },
          ),
        );
        final api = HarmonyAccountApi(http: http, storage: store)
          ..session = HarmonySession(
            'token',
            'harmony',
            DateTime.now().add(const Duration(days: 1)),
          );

        await expectLater(
          api.downloadConfig(),
          throwsA(HarmonyAccountError.config),
        );

        expect(store.lastModified, 'installed-version');
      },
    );
  }

  for (final status in [401, 403, 429, 500, 503]) {
    test(
      'config HTTP $status retains its distinct error classification',
      () async {
        final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
        http.httpClientAdapter = Adapter((_) => jsonBody({}, status));
        final api = HarmonyAccountApi(http: http, storage: MemoryStore())
          ..session = HarmonySession(
            'token',
            'harmony',
            DateTime.now().add(const Duration(days: 1)),
          );
        final expected = switch (status) {
          401 || 403 => HarmonyAccountError.expired,
          429 => HarmonyAccountError.rateLimited,
          _ => HarmonyAccountError.unavailable,
        };

        await expectLater(api.downloadConfig(), throwsA(expected));
      },
    );
  }

  test(
    'transport errors are unavailable rather than invalid configuration',
    () async {
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      http.httpClientAdapter = Adapter(
        (request) => throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        ),
      );
      final api = HarmonyAccountApi(http: http, storage: MemoryStore())
        ..session = HarmonySession(
          'token',
          'harmony',
          DateTime.now().add(const Duration(days: 1)),
        );

      await expectLater(
        api.downloadConfig(),
        throwsA(HarmonyAccountError.unavailable),
      );
    },
  );

  test('logout wins over an in-flight session restoration', () async {
    final store = MemoryStore()..token = 'saved-token';
    final validationStarted = Completer<void>();
    final validation = Completer<ResponseBody>();
    final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    http.httpClientAdapter = AsyncAdapter((request) async {
      if (request.path == '/api/auth/get-session') {
        validationStarted.complete();
        return validation.future;
      }
      return jsonBody({'success': true});
    });
    final api = HarmonyAccountApi(http: http, storage: store);
    // Consume cancellation errors immediately so no asynchronous error escapes.
    final restoring = api.restore().then<Object?>(
      (value) => value,
      onError: (Object error) => error,
    );
    await validationStarted.future;
    await api.logout();
    validation.complete(
      jsonBody({
        'session': {
          'expiresAt': DateTime.now()
              .add(const Duration(days: 1))
              .toIso8601String(),
        },
        'user': {'username': 'harmony'},
      }),
    );
    await restoring;

    expect(api.session, isNull);
    expect(api.isAuthorized, isFalse);
    expect(store.token, isNull);
    expect(store.meta, isNull);
  });

  test(
    'ETag and Last-Modified are forwarded without persisting downloads',
    () async {
      final store = MemoryStore();
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      http.httpClientAdapter = Adapter((request) {
        expect(request.headers['If-None-Match'], '"installed"');
        expect(request.headers['If-Modified-Since'], 'old-date');
        return ResponseBody.fromString(
          'proxies: []',
          200,
          headers: {
            'etag': ['"new"'],
            'last-modified': ['new-date'],
          },
        );
      });
      final api = HarmonyAccountApi(http: http, storage: store)
        ..session = HarmonySession(
          'token',
          'alice',
          DateTime.now().add(const Duration(days: 1)),
        );

      final downloaded = await api.downloadConfig(
        ifNoneMatch: '"installed"',
        ifModifiedSince: 'old-date',
      );

      expect(downloaded.etag, '"new"');
      expect(downloaded.lastModified, 'new-date');
      expect(store.cache, isNull);
      expect(store.lastModified, isNull);
    },
  );

  test(
    'cache metadata commits only for the current account and token',
    () async {
      final store = MemoryStore();
      final api = HarmonyAccountApi(storage: store)
        ..session = HarmonySession(
          'alice-token',
          'alice',
          DateTime.now().add(const Duration(days: 1)),
        );
      final metadata = HarmonyConfigCacheMetadata(
        username: 'alice',
        profileId: 7,
        contentHash: 'a' * 64,
        etag: '"version-1"',
        lastModified: 'accepted-date',
      );

      await api.commitConfigCache(metadata, expectedToken: 'alice-token');
      final saved = await api.readConfigCache();
      expect(saved?.profileId, 7);
      expect(saved?.contentHash, 'a' * 64);
      expect(saved?.etag, '"version-1"');
      expect(saved?.lastModified, 'accepted-date');

      api.session = HarmonySession(
        'bob-token',
        'bob',
        DateTime.now().add(const Duration(days: 1)),
      );
      expect(await api.readConfigCache(), isNull);
      await expectLater(
        api.commitConfigCache(metadata, expectedToken: 'alice-token'),
        throwsA(HarmonyAccountError.expired),
      );
      await api.clearConfigCache();
      expect(store.cache, isNull);
    },
  );

  for (final badMeta in <Map<String, Object?>>[
    {'token': 'other-token', 'username': 'alice'},
    {'username': 'alice'},
    {'token': 'saved-token', 'username': null},
    {'token': 'saved-token', 'username': ''},
    {'token': 'saved-token', 'username': 123},
  ]) {
    test('offline restore rejects metadata $badMeta', () async {
      final store = MemoryStore()
        ..token = 'saved-token'
        ..meta = jsonEncode({
          ...badMeta,
          'expiresAt': DateTime.now()
              .add(const Duration(days: 1))
              .toIso8601String(),
        });
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      http.httpClientAdapter = Adapter(
        (request) => throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        ),
      );
      final api = HarmonyAccountApi(http: http, storage: store);

      await expectLater(
        api.restore(),
        throwsA(HarmonyAccountError.unavailable),
      );

      expect(api.isAuthorized, isFalse);
      expect(api.session, isNull);
    });
  }

  test('offline restore never revives expired cached metadata', () async {
    final store = MemoryStore()
      ..token = 'saved-token'
      ..meta = jsonEncode({
        'token': 'saved-token',
        'username': 'alice',
        'expiresAt': DateTime.now()
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
      });
    final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    http.httpClientAdapter = Adapter(
      (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      ),
    );
    final api = HarmonyAccountApi(http: http, storage: store);

    await expectLater(api.restore(), throwsA(HarmonyAccountError.unavailable));

    expect(api.isAuthorized, isFalse);
  });

  test('logout wins over an in-flight successful login', () async {
    final store = MemoryStore();
    final signInStarted = Completer<void>();
    final signIn = Completer<ResponseBody>();
    var validations = 0;
    final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    http.httpClientAdapter = AsyncAdapter((request) async {
      if (request.path == '/api/auth/sign-in/username') {
        signInStarted.complete();
        return signIn.future;
      }
      if (request.path == '/api/auth/sign-out') {
        return jsonBody({'success': true});
      }
      validations++;
      return jsonBody({
        'session': {
          'expiresAt': DateTime.now()
              .add(const Duration(days: 1))
              .toIso8601String(),
        },
        'user': {'username': 'alice'},
      });
    });
    final api = HarmonyAccountApi(http: http, storage: store);
    final login = api
        .login('alice', 'password')
        .then<Object?>((value) => value, onError: (Object error) => error);
    await signInStarted.future;
    await api.logout();
    signIn.complete(
      jsonBody({}, 200, {
        'set-auth-token': ['late-token'],
      }),
    );
    await login;

    expect(api.session, isNull);
    expect(store.token, isNull);
    expect(store.meta, isNull);
    expect(validations, 0);
  });

  test('redirects cannot forward credentials to another endpoint', () async {
    final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    http.httpClientAdapter = Adapter((request) {
      expect(request.followRedirects, isFalse);
      return jsonBody({}, 307, {
        'location': ['https://other.example.test/steal'],
      });
    });
    final api = HarmonyAccountApi(http: http, storage: MemoryStore());

    await expectLater(
      api.login('alice', 'password'),
      throwsA(HarmonyAccountError.unavailable),
    );
    expect(api.isAuthorized, isFalse);
  });

  test(
    'failed keystore deletion cannot restore the logged-out session in this process',
    () async {
      final value = HarmonySession(
        'saved-token',
        'alice',
        DateTime.now().add(const Duration(days: 1)),
      );
      final store = DeleteFailureStore()
        ..token = value.token
        ..meta = jsonEncode(value.toJson());
      var validations = 0;
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      http.httpClientAdapter = Adapter((request) {
        if (request.path == '/api/auth/get-session') validations++;
        return jsonBody({'success': true});
      });
      final api = HarmonyAccountApi(http: http, storage: store)
        ..session = value;

      await expectLater(api.logout(), throwsStateError);
      expect(
        store.token,
        'saved-token',
        reason: 'Simulate a keystore that really failed to delete',
      );
      expect(await api.restore(), isNull);
      expect(await api.restore(), isNull);
      expect(validations, 0);
      expect(api.session, isNull);
    },
  );

  test(
    'a token issued to a login that cannot persist is revoked best-effort',
    () async {
      final store = WriteFailureStore();
      final revoked = <String?>[];
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      http.httpClientAdapter = Adapter((request) {
        if (request.path == '/api/auth/sign-in/username') {
          return jsonBody({}, 200, {
            'set-auth-token': ['unpersisted-token'],
          });
        }
        if (request.path == '/api/auth/sign-out') {
          revoked.add(request.headers['Authorization'] as String?);
          return jsonBody({'success': true});
        }
        return jsonBody({
          'session': {
            'expiresAt': DateTime.now()
                .add(const Duration(days: 1))
                .toIso8601String(),
          },
          'user': {'username': 'alice'},
        });
      });
      final api = HarmonyAccountApi(http: http, storage: store);

      await expectLater(
        api.login('alice', 'password'),
        throwsA(HarmonyAccountError.unavailable),
      );

      expect(revoked, ['Bearer unpersisted-token']);
      expect(store.token, isNull);
      expect(store.meta, isNull);
      expect(api.isAuthorized, isFalse);
    },
  );

  test('logout is ordered after a cache write already in progress', () async {
    final store = BlockingCacheStore();
    final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    http.httpClientAdapter = Adapter((_) => jsonBody({'success': true}));
    final api = HarmonyAccountApi(http: http, storage: store)
      ..session = HarmonySession(
        'token',
        'alice',
        DateTime.now().add(const Duration(days: 1)),
      );
    final committing = api
        .commitConfigCache(
          HarmonyConfigCacheMetadata(
            username: 'alice',
            profileId: 7,
            contentHash: 'a' * 64,
          ),
          expectedToken: 'token',
        )
        .then<Object?>((_) => null, onError: (Object error) => error);
    await store.writing.future;
    final loggingOut = api.logout();
    expect(api.isAuthorized, isFalse);
    store.release.complete();

    expect(await committing, HarmonyAccountError.expired);
    await loggingOut;

    expect(store.cache, isNull);
    expect(store.token, isNull);
    expect(api.session, isNull);
    expect(await api.restore(), isNull);
  });

  test('logout discards a config download that finishes afterward', () async {
    final response = Completer<ResponseBody>();
    final requested = Completer<void>();
    final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
    http.httpClientAdapter = AsyncAdapter((request) async {
      if (request.path == '/v1/config') {
        requested.complete();
        return response.future;
      }
      return jsonBody({'success': true});
    });
    final store = MemoryStore();
    final api = HarmonyAccountApi(http: http, storage: store)
      ..session = HarmonySession(
        'token',
        'alice',
        DateTime.now().add(const Duration(days: 1)),
      );
    final downloading = api.downloadConfig().then<Object?>(
      (value) => value,
      onError: (Object error) => error,
    );
    await requested.future;
    await api.logout();
    response.complete(ResponseBody.fromString('proxies: []', 200));

    expect(await downloading, HarmonyAccountError.expired);
    expect(store.cache, isNull);
    expect(api.session, isNull);
  });

  test(
    'native clear attempts every credential deletion after one failure',
    () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final deleted = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'delete') {
              final key = call.arguments['key'] as String;
              deleted.add(key);
              if (key == 'harmony_session') {
                throw PlatformException(code: 'storage_unavailable');
              }
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await expectLater(
        HarmonySessionStore().clearAll(),
        throwsA(isA<PlatformException>()),
      );

      expect(
        deleted,
        containsAll([
          'harmony_session',
          'harmony_session_meta',
          'harmony_config_lm',
        ]),
      );
    },
  );

  test(
    'native storage uses the maintained plugin channel with RSA OAEP and AES GCM',
    () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final calls = <MethodCall>[];
      String? saved;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'write') {
              saved = call.arguments['value'] as String;
            }
            if (call.method == 'delete') saved = null;
            return call.method == 'read' ? saved : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final store = HarmonySessionStore();
      await store.write('signed-token');
      expect(await store.read(), 'signed-token');
      await store.delete();
      expect(await store.read(), isNull);
      final options = calls.first.arguments['options'] as Map;
      expect(options['ohosStorageCipherAlgorithm'], 'AES_GCM_NoPadding');
      expect(
        options['ohosKeyCipherAlgorithm'],
        'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
      );
    },
  );
}
