import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

const harmonyApiUrl = String.fromEnvironment(
  'CLASH_HARMONY_API_URL',
  defaultValue: 'https://auth.example.com',
);

const harmonyConfigMaxBytes = 1024 * 1024;

/// Reuses flutter_secure_storage_ohos via its documented MethodChannel.
/// Pin: pubspec.yaml git ref 545fb022eed8ce7891028d4851a617b9a8328177 — changing
/// the plugin or channel name requires updating HarmonySessionStore together.
class HarmonySessionStore {
  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  static const _tokenKey = 'harmony_session';
  static const _metaKey = 'harmony_session_meta';
  static const _lastModifiedKey = 'harmony_config_lm';

  Future<String?> read() => _channel.invokeMethod<String>('read', _arguments(_tokenKey));

  Future<void> write(String value) =>
      _channel.invokeMethod<void>('write', _arguments(_tokenKey, value));

  Future<void> delete() => _channel.invokeMethod<void>('delete', _arguments(_tokenKey));

  Future<String?> readMeta() =>
      _channel.invokeMethod<String>('read', _arguments(_metaKey));

  Future<void> writeMeta(String value) =>
      _channel.invokeMethod<void>('write', _arguments(_metaKey, value));

  Future<void> deleteMeta() =>
      _channel.invokeMethod<void>('delete', _arguments(_metaKey));

  Future<String?> readConfigLastModified() =>
      _channel.invokeMethod<String>('read', _arguments(_lastModifiedKey));

  Future<void> writeConfigLastModified(String value) =>
      _channel.invokeMethod<void>('write', _arguments(_lastModifiedKey, value));

  Future<void> deleteConfigLastModified() =>
      _channel.invokeMethod<void>('delete', _arguments(_lastModifiedKey));

  Future<void> clearAll() async {
    await delete();
    await deleteMeta();
    await deleteConfigLastModified();
  }

  Map<String, Object?> _arguments(String key, [String? value]) => {
    'key': key,
    'value': ?value,
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

  Map<String, Object> toJson() => {
    'token': token,
    'username': username,
    'expiresAt': expiresAt.toIso8601String(),
  };

  static HarmonySession? fromJson(String? raw, String tokenFallback) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final expiresAt = DateTime.tryParse('${data['expiresAt']}');
      final username = '${data['username']}';
      if (expiresAt == null || username.isEmpty) return null;
      return HarmonySession(tokenFallback, username, expiresAt);
    } catch (_) {
      return null;
    }
  }
}

class HarmonyConfigDownload {
  final Uint8List? bytes;
  final String? lastModified;
  final bool notModified;

  const HarmonyConfigDownload({
    this.bytes,
    this.lastModified,
    this.notModified = false,
  });
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

  Future<String?> readConfigLastModified() => _storage.readConfigLastModified();

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
      if (error == HarmonyAccountError.unavailable) {
        final cached = HarmonySession.fromJson(await _storage.readMeta(), token);
        if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
          return session = cached;
        }
      }
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
      await _storage.writeMeta(jsonEncode(value.toJson()));
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
    final value = session = HarmonySession(
      token,
      '${data['user']['username']}',
      expiresAt,
    );
    await _storage.writeMeta(jsonEncode(value.toJson()));
    return value;
  }

  Future<HarmonyConfigDownload> downloadConfig({String? ifModifiedSince}) async {
    if (!isAuthorized) throw HarmonyAccountError.expired;
    final response = await _request(
      '/v1/config',
      token: session!.token,
      responseType: ResponseType.stream,
      headers: {
        if (ifModifiedSince != null) 'If-Modified-Since': ifModifiedSince,
      },
    );
    if (response.statusCode == 304) {
      return HarmonyConfigDownload(
        notModified: true,
        lastModified: ifModifiedSince ?? await _storage.readConfigLastModified(),
      );
    }
    final stream = response.data as ResponseBody;
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in stream.stream) {
      length += chunk.length;
      if (length > harmonyConfigMaxBytes) {
        throw HarmonyAccountError.config;
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) throw HarmonyAccountError.config;
    final lastModified = response.headers.value('last-modified');
    if (lastModified != null && lastModified.isNotEmpty) {
      await _storage.writeConfigLastModified(lastModified);
    }
    return HarmonyConfigDownload(bytes: Uint8List.fromList(bytes), lastModified: lastModified);
  }

  Future<void> logout() async {
    final token = session?.token;
    await clear();
    if (token != null) {
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
  }

  Future<void> clear() async {
    session = null;
    await _storage.clearAll();
  }

  Future<Response<dynamic>> _request(
    String path, {
    String method = 'GET',
    Object? data,
    String? token,
    bool login = false,
    ResponseType responseType = ResponseType.json,
    Map<String, String>? headers,
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
          validateStatus: (status) =>
              status != null && (status >= 200 && status < 300 || status == 304),
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
            ...?headers,
          },
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
