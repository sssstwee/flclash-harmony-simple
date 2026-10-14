import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStore extends HarmonySessionStore {
  String? token;
  String? meta;
  String? lastModified;
  String? reconnect;
  String? refreshSeconds;

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
  Future<int?> readConfigRefreshSeconds() async => int.tryParse(refreshSeconds ?? '');

  @override
  Future<void> writeConfigRefreshSeconds(int seconds) async {
    refreshSeconds = '$seconds';
  }

  @override
  Future<void> deleteConfigRefreshSeconds() async {
    refreshSeconds = null;
  }

  @override
  Future<void> clearAll() async {
    token = null;
    meta = null;
    lastModified = null;
    reconnect = null;
    refreshSeconds = null;
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

class FailingStore extends MemoryStore {
  @override
  Future<void> write(String value) async => throw StateError('storage failed');
  @override
  Future<void> delete() async => throw StateError('storage failed');
  @override
  Future<void> clearAll() async => throw StateError('storage failed');
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
      await expectLater(api.restore(), throwsA(HarmonyAccountError.expired));
      expect(store.token, isNull);
      expect(api.isAuthorized, isFalse);
    },
  );

  test('restore keeps cached session metadata when the service is unavailable', () async {
    final store = MemoryStore()
      ..token = 'saved-token'
      ..meta = jsonEncode({
        'username': 'offline-user',
        'expiresAt': DateTime.now().add(const Duration(days: 2)).toIso8601String(),
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
  });

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
