import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

/// Production builds must set [CLASH_HARMONY_API_URL] (see `env.json.example`).
const harmonyApiUrl = String.fromEnvironment(
  'CLASH_HARMONY_API_URL',
  defaultValue: 'https://auth.example.com',
);

const harmonyConfigMaxBytes = 1024 * 1024;

/// Reuses flutter_secure_storage_ohos via its documented MethodChannel.
/// Pin: pubspec.yaml git ref 545fb022eed8ce7891028d4851a617b9a8328177.
class HarmonySessionStore {
  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  static const _tokenKey = 'harmony_session';
  static const _metaKey = 'harmony_session_meta';
  static const _lastModifiedKey = 'harmony_config_lm';
  static const _configCacheKey = 'harmony_config_cache';

  Future<String?> read() =>
      _channel.invokeMethod<String>('read', _arguments(_tokenKey));

  Future<void> write(String value) =>
      _channel.invokeMethod<void>('write', _arguments(_tokenKey, value));

  Future<void> delete() =>
      _channel.invokeMethod<void>('delete', _arguments(_tokenKey));

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

  Future<String?> readConfigCache() =>
      _channel.invokeMethod<String>('read', _arguments(_configCacheKey));

  Future<void> writeConfigCache(String value) =>
      _channel.invokeMethod<void>('write', _arguments(_configCacheKey, value));

  Future<void> deleteConfigCache() =>
      _channel.invokeMethod<void>('delete', _arguments(_configCacheKey));

  Future<void> clearAll() async {
    Object? failure;
    StackTrace? failureStack;
    for (final remove in [
      delete,
      deleteMeta,
      deleteConfigLastModified,
      deleteConfigCache,
    ]) {
      try {
        await remove();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
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
    if (raw == null || raw.isEmpty || tokenFallback.isEmpty) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final username = data['username'];
      final expiry = data['expiresAt'];
      if (data['token'] != tokenFallback ||
          username is! String ||
          username.trim().isEmpty ||
          expiry is! String) {
        return null;
      }
      final expiresAt = DateTime.tryParse(expiry);
      if (expiresAt == null) return null;
      return HarmonySession(tokenFallback, username, expiresAt);
    } catch (_) {
      return null;
    }
  }
}

/// Describes bytes that have already been validated and durably installed.
/// A response validator alone never proves that a usable profile exists.
class HarmonyConfigCacheMetadata {
  final String username;
  final int profileId;
  final String contentHash;
  final String? etag;
  final String? lastModified;

  const HarmonyConfigCacheMetadata({
    required this.username,
    required this.profileId,
    required this.contentHash,
    this.etag,
    this.lastModified,
  });

  Map<String, Object?> toJson() => {
    'username': username,
    'profileId': profileId,
    'contentHash': contentHash,
    'etag': etag,
    'lastModified': lastModified,
  };

  static HarmonyConfigCacheMetadata? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final username = data['username'];
      final profileId = data['profileId'];
      final hash = data['contentHash'];
      final etag = data['etag'];
      final lastModified = data['lastModified'];
      if (username is! String ||
          username.trim().isEmpty ||
          profileId is! int ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          (etag != null && etag is! String) ||
          (lastModified != null && lastModified is! String)) {
        return null;
      }
      return HarmonyConfigCacheMetadata(
        username: username,
        profileId: profileId,
        contentHash: hash,
        etag: etag as String?,
        lastModified: lastModified as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

class HarmonyConfigDownload {
  final Uint8List? bytes;
  final String? etag;
  final String? lastModified;
  final bool notModified;

  const HarmonyConfigDownload({
    this.bytes,
    this.etag,
    this.lastModified,
    this.notModified = false,
  });
}

class HarmonyAccountApi {
  final Dio _http;
  final HarmonySessionStore _storage;
  HarmonySession? session;
  int _generation = 0;
  Future<void> _storageTail = Future<void>.value();

  HarmonyAccountApi({Dio? http, HarmonySessionStore? storage})
    : _http = http ?? Dio(
        BaseOptions(
          baseUrl: harmonyApiUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 40),
          followRedirects: false,
        ),
      ),
      _storage = storage ?? HarmonySessionStore();

  bool get isAuthorized => session?.expiresAt.isAfter(DateTime.now()) == true;

  // Serialize persistence only. Network requests never hold the storage queue,
  // so logout can invalidate an in-flight login/restore immediately.
  Future<T> _store<T>(Future<T> Function() action) {
    final result = _storageTail.then((_) => action());
    _storageTail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _checkGeneration(int generation) {
    if (_generation != generation) throw HarmonyAccountError.expired;
  }

  Future<String?> readConfigLastModified() =>
      _store(_storage.readConfigLastModified);

  Future<HarmonyConfigCacheMetadata?> readConfigCache() async {
    final current = session;
    if (current == null || !isAuthorized) return null;
    final raw = await _store(_storage.readConfigCache);
    if (session?.token != current.token || !isAuthorized) return null;
    final metadata = HarmonyConfigCacheMetadata.fromJson(raw);
    return metadata?.username == current.username ? metadata : null;
  }

  Future<void> commitConfigCache(
    HarmonyConfigCacheMetadata metadata, {
    required String expectedToken,
  }) async {
    final generation = _generation;
    await _store(() async {
      _checkGeneration(generation);
      if (!isAuthorized ||
          session?.token != expectedToken ||
          session?.username != metadata.username) {
        throw HarmonyAccountError.expired;
      }
      await _storage.writeConfigCache(jsonEncode(metadata.toJson()));
      _checkGeneration(generation);
    });
  }

  Future<void> clearConfigCache() => _store(() async {
    try {
      await _storage.deleteConfigCache();
    } finally {
      await _storage.deleteConfigLastModified();
    }
  });

  Future<HarmonySession?> restore() async {
    final generation = _generation;
    String? token;
    try {
      token = await _store(_storage.read);
      _checkGeneration(generation);
      if (token == null || token.isEmpty) {
        session = null;
        return null;
      }
      final value = await _validate(token);
      _checkGeneration(generation);
      await _store(() async {
        _checkGeneration(generation);
        await _storage.writeMeta(jsonEncode(value.toJson()));
      });
      _checkGeneration(generation);
      return session = value;
    } on HarmonyAccountError catch (error) {
      _checkGeneration(generation);
      if (error == HarmonyAccountError.expired) {
        try {
          await clear();
        } catch (_) {
          // In-memory authorization is already gone even if storage is broken.
        }
      } else if (error == HarmonyAccountError.unavailable && token != null) {
        final raw = await _store(_storage.readMeta);
        _checkGeneration(generation);
        final cached = HarmonySession.fromJson(raw, token);
        if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
          return session = cached;
        }
        session = null;
      }
      rethrow;
    } catch (_) {
      _checkGeneration(generation);
      session = null;
      throw HarmonyAccountError.unavailable;
    }
  }

  Future<HarmonySession> login(String username, String password) async {
    final generation = ++_generation;
    session = null;
    try {
      await _store(() async {
        _checkGeneration(generation);
        await _storage.clearAll();
      });
      _checkGeneration(generation);
      final response = await _request(
        '/api/auth/sign-in/username',
        method: 'POST',
        data: {'username': username.trim(), 'password': password},
        login: true,
      );
      _checkGeneration(generation);
      final token = response.headers.value('set-auth-token');
      if (token == null || token.isEmpty) throw HarmonyAccountError.unavailable;
      final value = await _validate(token);
      _checkGeneration(generation);
      await _store(() async {
        _checkGeneration(generation);
        await _storage.write(token);
        await _storage.writeMeta(jsonEncode(value.toJson()));
        if (await _storage.read() != token) throw HarmonyAccountError.unavailable;
      });
      _checkGeneration(generation);
      return session = value;
    } catch (error) {
      if (_generation == generation) {
        try {
          await clear();
        } catch (_) {}
      }
      if (error is HarmonyAccountError) rethrow;
      throw HarmonyAccountError.unavailable;
    }
  }

  Future<HarmonySession> _validate(String token) async {
    final response = await _request('/api/auth/get-session', token: token);
    final data = response.data;
    if (data is! Map || data['session'] is! Map || data['user'] is! Map) {
      throw HarmonyAccountError.expired;
    }
    final username = data['user']['username'];
    final expiresAt = DateTime.tryParse('${data['session']['expiresAt']}');
    if (expiresAt == null ||
        !expiresAt.isAfter(DateTime.now()) ||
        username is! String ||
        username.trim().isEmpty) {
      throw HarmonyAccountError.expired;
    }
    return HarmonySession(token, username, expiresAt);
  }

  Future<HarmonyConfigDownload> downloadConfig({
    String? ifNoneMatch,
    String? ifModifiedSince,
  }) async {
    if (!isAuthorized) throw HarmonyAccountError.expired;
    final token = session!.token;
    final generation = _generation;
    final response = await _request(
      '/v1/config',
      token: token,
      responseType: ResponseType.stream,
      headers: {
        'If-None-Match': ?ifNoneMatch,
        'If-Modified-Since': ?ifModifiedSince,
      },
    );
    _checkGeneration(generation);
    if (session?.token != token || !isAuthorized) throw HarmonyAccountError.expired;
    if (response.statusCode == 304) {
      return HarmonyConfigDownload(
        notModified: true,
        etag: response.headers.value('etag') ?? ifNoneMatch,
        lastModified: response.headers.value('last-modified') ?? ifModifiedSince,
      );
    }
    final stream = response.data;
    if (stream is! ResponseBody) throw HarmonyAccountError.config;
    final builder = BytesBuilder(copy: false);
    var length = 0;
    try {
      await for (final chunk in stream.stream) {
        _checkGeneration(generation);
        length += chunk.length;
        if (length > harmonyConfigMaxBytes) throw HarmonyAccountError.config;
        builder.add(chunk);
      }
    } on HarmonyAccountError {
      rethrow;
    } catch (_) {
      throw HarmonyAccountError.unavailable;
    }
    _checkGeneration(generation);
    if (session?.token != token || !isAuthorized) throw HarmonyAccountError.expired;
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) throw HarmonyAccountError.config;
    return HarmonyConfigDownload(
      bytes: bytes,
      etag: response.headers.value('etag'),
      lastModified: response.headers.value('last-modified'),
    );
  }

  Future<void> logout() async {
    final token = session?.token;
    Object? storageFailure;
    StackTrace? storageStackTrace;
    try {
      await clear();
    } catch (error, stackTrace) {
      storageFailure = error;
      storageStackTrace = stackTrace;
    }
    if (token != null) {
      try {
        await _request('/api/auth/sign-out', method: 'POST', data: {}, token: token);
      } catch (_) {
        // The server session also expires automatically.
      }
    }
    if (storageFailure != null) {
      Error.throwWithStackTrace(storageFailure, storageStackTrace!);
    }
  }

  Future<void> clear() {
    ++_generation;
    session = null;
    return _store(_storage.clearAll);
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
          followRedirects: false,
          validateStatus: (status) => status != null &&
              (status >= 200 && status < 300 || path == '/v1/config' && status == 304),
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
            ...?headers,
          },
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw login ? HarmonyAccountError.credentials : HarmonyAccountError.expired;
      }
      if (status == 429) throw HarmonyAccountError.rateLimited;
      if (status == null || status >= 500) throw HarmonyAccountError.unavailable;
      if (path == '/v1/config') throw HarmonyAccountError.config;
      throw HarmonyAccountError.unavailable;
    }
  }
}

final harmonyAccount = HarmonyAccountApi();
