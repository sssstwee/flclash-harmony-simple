import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'harmony_account_test.dart' show MemoryStore;

class _Headers extends Mock implements HttpHeaders {
  @override
  void forEach(void Function(String, List<String>) action) {
    action('content-type', ['application/json']);
  }
}

class _Response extends Mock implements HttpClientResponse {
  final Object data;
  _Response(this.data);

  @override
  final headers = _ResponseHeaders();

  @override
  int get statusCode => 200;

  @override
  String get reasonPhrase => 'OK';

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  Stream<R> cast<R>() =>
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(data)))).cast<R>();
}

class _ResponseHeaders extends _Headers {
  @override
  void forEach(void Function(String, List<String>) action) {
    super.forEach(action);
    action('set-auth-token', ['signed-token']);
  }
}

class _Request extends Mock implements HttpClientRequest {
  final Object data;
  _Request(this.data);

  @override
  final headers = _Headers();

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<HttpClientResponse> close() async => _Response(data);
}

class _Transport extends HttpOverrides {
  final routes = <({String path, String route})>[];
  var directConfigFailed = false;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(this);

  Future<HttpClientRequest> openUrl(Uri url, String route) async {
    routes.add((path: url.path, route: route));
    if (route == 'STALE_PROXY') {
      throw const SocketException('test stale proxy has stopped');
    }
    if (url.path == harmonyConfigPath || url.path == harmonyHomeDisplayPath) {
      if (route == 'DIRECT' && !directConfigFailed) {
        directConfigFailed = true;
        throw const SocketException('test direct route unavailable');
      }
      return _Request(
        url.path == harmonyHomeDisplayPath
            ? {'schemaVersion': 1}
            : {'config': 'test'},
      );
    }
    return _Request({
      'user': {'username': 'harmony'},
      'session': {
        'expiresAt': DateTime.now()
            .add(const Duration(days: 1))
            .toIso8601String(),
      },
    });
  }
}

class _Client extends Mock implements HttpClient {
  final _Transport transport;
  String Function(Uri)? _proxy;
  _Client(this.transport);

  @override
  set findProxy(String Function(Uri)? value) => _proxy = value;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      transport.openUrl(url, _proxy?.call(url) ?? 'DEFAULT');
}

class _LoopbackTransport extends HttpOverrides {
  final int port;
  final closed = Completer<bool>();
  _LoopbackTransport(this.port);

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _LoopbackClient(super.createHttpClient(context), this);
}

class _LoopbackClient extends Mock implements HttpClient {
  final HttpClient client;
  final _LoopbackTransport transport;
  _LoopbackClient(this.client, this.transport);

  @override
  set findProxy(String Function(Uri)? value) => client.findProxy = value;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => client.openUrl(
    method,
    Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: transport.port,
      path: url.path,
    ),
  );

  @override
  void close({bool force = false}) {
    transport.closed.complete(force);
    client.close(force: force);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('homepage retries the local proxy after a direct failure', () async {
    final transport = _Transport();
    await HttpOverrides.runWithHttpOverrides(() async {
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      final api = HarmonyAccountApi(http: http, storage: MemoryStore())
        ..localMixedProxyPort = 7890;
      expect((await api.fetchHomeDisplay()).data, {'schemaVersion': 1});
      expect(transport.routes, [
        (path: harmonyHomeDisplayPath, route: 'DIRECT'),
        (path: harmonyHomeDisplayPath, route: 'PROXY localhost:7890'),
      ]);
      http.close(force: true);
    }, transport);
  });

  test(
    'a direct config transport failure opens a fresh direct request',
    () async {
      final transport = _Transport();
      await HttpOverrides.runWithHttpOverrides(() async {
        final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
        final api = HarmonyAccountApi(http: http, storage: MemoryStore())
          ..session = HarmonySession(
            'signed-token',
            'harmony',
            DateTime.now().add(const Duration(days: 1)),
          );
        // The response is intentionally invalid; this test verifies real IO
        // adapter routing before envelope validation.
        await expectLater(
          api.downloadConfig(),
          throwsA(HarmonyAccountError.config),
        );
        expect(transport.routes, [
          (path: harmonyConfigPath, route: 'DIRECT'),
          (path: harmonyConfigPath, route: 'DIRECT'),
        ]);
        http.close(force: true);
      }, transport);
    },
  );

  test('session validation stays direct during a config proxy retry', () async {
    final transport = _Transport();
    await HttpOverrides.runWithHttpOverrides(() async {
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      expect(http.httpClientAdapter, isA<IOHttpClientAdapter>());
      final sessionWaiting = Completer<void>();
      final releaseSession = Completer<void>();
      final retryWaiting = Completer<void>();
      final releaseRetry = Completer<void>();
      var configAttempts = 0;
      http.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.path == '/api/auth/get-session') {
              sessionWaiting.complete();
              await releaseSession.future;
            } else if (++configAttempts == 2) {
              retryWaiting.complete();
              await releaseRetry.future;
            }
            handler.next(options);
          },
        ),
      );
      final store = MemoryStore()..token = 'signed-token';
      final api = HarmonyAccountApi(http: http, storage: store)
        ..localMixedProxyPort = 7890
        ..session = HarmonySession(
          'signed-token',
          'harmony',
          DateTime.now().add(const Duration(days: 1)),
        );
      final validation = api.restore();
      await sessionWaiting.future;
      final download = api.downloadConfig();
      await retryWaiting.future;
      releaseSession.complete();
      await validation;
      releaseRetry.complete();
      // The fixture is deliberately not a valid remote envelope; route choice
      // happens before config decoding and is the behavior under test here.
      await expectLater(download, throwsA(HarmonyAccountError.config));
      expect(transport.routes, [
        (path: harmonyConfigPath, route: 'DIRECT'),
        (path: '/api/auth/get-session', route: 'DIRECT'),
        (path: harmonyConfigPath, route: 'PROXY localhost:7890'),
      ]);
      http.close(force: true);
    }, transport);
  });

  test(
    'an old config retry cannot send a new login to a stopped proxy',
    () async {
      final transport = _Transport();
      await HttpOverrides.runWithHttpOverrides(() async {
        final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
        http.httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () =>
              HttpClient()..findProxy = (_) => 'STALE_PROXY',
        );
        final retryWaiting = Completer<void>();
        final releaseRetry = Completer<void>();
        final loginWaiting = Completer<void>();
        final releaseLogin = Completer<void>();
        var configAttempts = 0;
        http.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              if (options.path == harmonyConfigPath && ++configAttempts == 2) {
                retryWaiting.complete();
                await releaseRetry.future;
              } else if (options.path == '/api/auth/sign-in/username') {
                loginWaiting.complete();
                await releaseLogin.future;
              }
              handler.next(options);
            },
          ),
        );
        final store = MemoryStore()..token = 'old-token';
        final api = HarmonyAccountApi(http: http, storage: store)
          ..localMixedProxyPort = 7890
          ..session = HarmonySession(
            'old-token',
            'harmony',
            DateTime.now().add(const Duration(days: 1)),
          );
        final oldDownload = expectLater(
          api.downloadConfig(),
          throwsA(HarmonyAccountError.expired),
        );
        await retryWaiting.future;
        await api.clear();
        final login = api.login('harmony', 'password');
        await loginWaiting.future;
        releaseRetry.complete();
        await oldDownload;
        releaseLogin.complete();
        final session = await login;
        expect(session.token, 'signed-token');
        expect(store.token, 'signed-token');
        expect(transport.routes, [
          (path: harmonyConfigPath, route: 'DIRECT'),
          (path: harmonyConfigPath, route: 'PROXY localhost:7890'),
          (path: '/api/auth/sign-in/username', route: 'DIRECT'),
        ]);
        http.close(force: true);
      }, transport);
    },
  );

  test('request cleanup keeps an active config response readable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = _LoopbackTransport(server.port);
    final releaseBody = Completer<void>();
    final serving = () async {
      final request = await server.first;
      request.response.write('proxies:\n');
      await request.response.flush();
      await releaseBody.future;
      request.response.write('  - name: example\n');
      await request.response.close();
    }();
    addTearDown(() => server.close(force: true));
    addTearDown(() {
      if (!releaseBody.isCompleted) releaseBody.complete();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      final http = Dio(BaseOptions(baseUrl: 'https://api.example.test'));
      final api = HarmonyAccountApi(http: http, storage: MemoryStore())
        ..session = HarmonySession(
          'signed-token',
          'harmony',
          DateTime.now().add(const Duration(days: 1)),
        );
      final download = api.downloadConfig();
      expect(await transport.closed.future, isFalse);
      releaseBody.complete();
      expect(
        utf8.decode((await download).bytes!),
        'proxies:\n  - name: example\n',
      );
      await serving;
      http.close(force: true);
    }, transport);
  });
}
