import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

const harmonyApiUrl = String.fromEnvironment(
  'CLASH_HARMONY_API_URL',
  defaultValue: 'https://auth.example.com',
);

// Reuse the native secure-storage plugin's documented method channel. The
// upstream Dart package does not recognize HarmonyOS in its options selector.
class HarmonySessionStore {
  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  static const _key = 'harmony_session';

  Future<String?> read() => _channel.invokeMethod<String>('read', _arguments());
  Future<void> write(String value) =>
      _channel.invokeMethod<void>('write', _arguments(value));
  Future<void> delete() => _channel.invokeMethod<void>('delete', _arguments());

  Map<String, Object> _arguments([String? value]) => {
    'key': _key,
    if (value != null) 'value': value,
    'options': <String, String>{
      'ohosKeyCipherAlgorithm': 'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
      'ohosStorageCipherAlgorithm': 'AES_GCM_NoPadding',
    },
  };
}

enum HarmonyAccountError {
  credentials,
  expired,
  rateLimited,
  unavailable,
  config,
}

class HarmonySession {
  final String token;
  final String username;
  final DateTime expiresAt;

  const HarmonySession(this.token, this.username, this.expiresAt);
}

class HarmonyAccountApi {
  final Dio _http;
  final HarmonySessionStore _storage;
  HarmonySession? session;

  HarmonyAccountApi({Dio? http, HarmonySessionStore? storage})
    : _http =
          http ??
          Dio(
            BaseOptions(
              baseUrl: harmonyApiUrl,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 40),
              followRedirects: false,
            ),
          ),
      _storage = storage ?? HarmonySessionStore();

  bool get isAuthorized => session?.expiresAt.isAfter(DateTime.now()) == true;

  Future<HarmonySession?> restore() async {
    final token = await _storage.read();
    if (token == null || token.isEmpty) {
      session = null;
      return null;
    }
    try {
      return await _validate(token);
    } on HarmonyAccountError catch (error) {
      if (error == HarmonyAccountError.expired) await clear();
      rethrow;
    }
  }

  Future<HarmonySession> login(String username, String password) async {
    final response = await _request(
      '/api/auth/sign-in/username',
      method: 'POST',
      data: {'username': username.trim(), 'password': password},
      login: true,
    );
    final token = response.headers.value('set-auth-token');
    if (token == null || token.isEmpty) throw HarmonyAccountError.unavailable;
    final value = await _validate(token);
    try {
      await _storage.write(token);
      if (await _storage.read() != token) {
        throw HarmonyAccountError.unavailable;
      }
    } catch (_) {
      session = null;
      throw HarmonyAccountError.unavailable;
    }
    return value;
  }

  Future<HarmonySession> _validate(String token) async {
    final response = await _request('/api/auth/get-session', token: token);
    final data = response.data;
    if (data is! Map || data['session'] is! Map || data['user'] is! Map) {
      throw HarmonyAccountError.expired;
    }
    final expiresAt = DateTime.tryParse('${data['session']['expiresAt']}');
    if (expiresAt == null || !expiresAt.isAfter(DateTime.now())) {
      throw HarmonyAccountError.expired;
    }
    return session = HarmonySession(
      token,
      '${data['user']['username']}',
      expiresAt,
    );
  }

  Future<Uint8List> downloadConfig() async {
    if (!isAuthorized) throw HarmonyAccountError.expired;
    final response = await _request(
      '/v1/config',
      token: session!.token,
      responseType: ResponseType.bytes,
    );
    final bytes = Uint8List.fromList(List<int>.from(response.data as List));
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw HarmonyAccountError.config;
    }
    return bytes;
  }

  Future<void> logout() async {
    final token = session?.token;
    // Clearing local authorization must succeed even without a network.
    await clear();
    if (token == null) return;
    try {
      await _request(
        '/api/auth/sign-out',
        method: 'POST',
        data: {},
        token: token,
      );
    } catch (_) {
      // The server session also expires automatically.
    }
  }

  Future<void> clear() async {
    session = null;
    await _storage.delete();
  }

  Future<Response<dynamic>> _request(
    String path, {
    String method = 'GET',
    Object? data,
    String? token,
    bool login = false,
    ResponseType responseType = ResponseType.json,
  }) async {
    final uri = Uri.tryParse(_http.options.baseUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw HarmonyAccountError.unavailable;
    }
    try {
      return await _http.request<dynamic>(
        path,
        data: data,
        options: Options(
          method: method,
          responseType: responseType,
          headers: {if (token != null) 'Authorization': 'Bearer $token'},
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw login
            ? HarmonyAccountError.credentials
            : HarmonyAccountError.expired;
      }
      if (status == 429) throw HarmonyAccountError.rateLimited;
      if (path == '/v1/config') throw HarmonyAccountError.config;
      throw HarmonyAccountError.unavailable;
    }
  }
}

final harmonyAccount = HarmonyAccountApi();
