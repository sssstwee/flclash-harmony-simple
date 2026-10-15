import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/harmony_config_check.dart';
import 'package:fl_clash/common/harmony_connect.dart';
import 'package:fl_clash/common/harmony_remote_config.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/services.dart';

/// Production builds must set [CLASH_HARMONY_API_URL] (see `env.json.example`).
const harmonyApiUrl = String.fromEnvironment(
  'CLASH_HARMONY_API_URL',
  defaultValue: 'https://auth.example.com',
);

const harmonyConfigPath = '/v1/config';

const harmonyConfigVersionPath = '/v1/config/version';

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
  static const _etagKey = 'harmony_config_etag';
  static const _configVersionKey = 'harmony_config_version';
  static const _reconnectKey = 'harmony_vpn_reconnect';
  static const _configRefreshKey = 'harmony_config_refresh_sec';
  static const _minCheckKey = 'harmony_config_min_check_sec';

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

  Future<String?> readConfigEtag() =>
      _channel.invokeMethod<String>('read', _arguments(_etagKey));

  Future<void> writeConfigEtag(String value) =>
      _channel.invokeMethod<void>('write', _arguments(_etagKey, value));

  Future<void> deleteConfigEtag() =>
      _channel.invokeMethod<void>('delete', _arguments(_etagKey));

  Future<String?> readConfigVersion() =>
      _channel.invokeMethod<String>('read', _arguments(_configVersionKey));

  Future<void> writeConfigVersion(String value) => _channel.invokeMethod<void>(
    'write',
    _arguments(_configVersionKey, value),
  );

  Future<void> deleteConfigVersion() =>
      _channel.invokeMethod<void>('delete', _arguments(_configVersionKey));

  Future<bool> readReconnectOnLaunch() async {
    final raw = await _channel.invokeMethod<String>(
      'read',
      _arguments(_reconnectKey),
    );
    return raw == '1';
  }

  Future<void> writeReconnectOnLaunch(bool value) =>
      _channel.invokeMethod<void>(
        'write',
        _arguments(_reconnectKey, value ? '1' : '0'),
      );

  Future<void> deleteReconnectOnLaunch() =>
      _channel.invokeMethod<void>('delete', _arguments(_reconnectKey));

  Future<int?> readConfigRefreshSeconds() async {
    final raw = await _channel.invokeMethod<String>(
      'read',
      _arguments(_configRefreshKey),
    );
    return int.tryParse(raw ?? '');
  }

  Future<void> writeConfigRefreshSeconds(int seconds) => _channel
      .invokeMethod<void>('write', _arguments(_configRefreshKey, '$seconds'));

  Future<void> deleteConfigRefreshSeconds() =>
      _channel.invokeMethod<void>('delete', _arguments(_configRefreshKey));

  Future<int?> readMinCheckSeconds() async {
    final raw = await _channel.invokeMethod<String>(
      'read',
      _arguments(_minCheckKey),
    );
    return int.tryParse(raw ?? '');
  }

  Future<void> writeMinCheckSeconds(int seconds) => _channel.invokeMethod<void>(
    'write',
    _arguments(_minCheckKey, '$seconds'),
  );

  Future<void> deleteMinCheckSeconds() =>
      _channel.invokeMethod<void>('delete', _arguments(_minCheckKey));

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
      deleteConfigEtag,
      deleteConfigVersion,
      deleteReconnectOnLaunch,
      deleteConfigRefreshSeconds,
      deleteMinCheckSeconds,
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
    if (raw == null || raw.isEmpty || tokenFallback.isEmpty) {
      return null;
    }
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
      if (expiresAt == null) {
        return null;
      }
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
    if (raw == null) {
      return null;
    }
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
  final String? configVersion;
  final bool notModified;
  final Duration? profileUpdateInterval;

  const HarmonyConfigDownload({
    this.bytes,
    this.etag,
    this.lastModified,
    this.configVersion,
    this.notModified = false,
    this.profileUpdateInterval,
  });
}

class HarmonyAccountApi {
  final Dio _http;
  final HarmonySessionStore _storage;
  HarmonySession? session;
  int _generation = 0;
  bool _restoreBlocked = false;
  Future<void> _storageTail = Future<void>.value();

  /// When set (VPN running), config fetches retry via local mixed port after a direct failure.
  int? localMixedProxyPort;

  /// `false` after a 404 on [harmonyConfigVersionPath]; no further version probes this run.
  bool? versionEndpointSupported;

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

  // Serialize persistence only. Network requests never hold the storage queue,
  // so logout can invalidate an in-flight login/restore immediately.
  Future<T> _store<T>(Future<T> Function() action) {
    final result = _storageTail.then((_) => action());
    _storageTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _checkGeneration(int generation) {
    if (_generation != generation) {
      throw HarmonyAccountError.expired;
    }
  }

  Future<String?> readConfigLastModified() =>
      _store(_storage.readConfigLastModified);

  Future<String?> readConfigEtag() => _store(_storage.readConfigEtag);

  Future<String?> readConfigVersion() => _store(_storage.readConfigVersion);

  Future<bool> readReconnectOnLaunch() =>
      _store(_storage.readReconnectOnLaunch);

  Future<void> setReconnectOnLaunch(bool value) =>
      _store(() => _storage.writeReconnectOnLaunch(value));

  Future<Duration> readConfigRefreshInterval({
    Duration fallback = const Duration(hours: 24),
  }) async {
    final seconds = await _store(_storage.readConfigRefreshSeconds);
    if (seconds == null || seconds <= 0) return fallback;
    return Duration(seconds: seconds);
  }

  Future<Duration> readMinCheckInterval() async {
    final seconds = await _store(_storage.readMinCheckSeconds);
    return harmonyMinCheckIntervalFromSeconds(seconds);
  }

  Future<void> saveConfigRefreshInterval(Duration interval) {
    final seconds = interval.inSeconds;
    if (seconds <= 0) {
      return _store(_storage.deleteConfigRefreshSeconds);
    }
    return _store(() => _storage.writeConfigRefreshSeconds(seconds));
  }

  Future<void> saveMinCheckInterval(Duration interval) {
    final seconds = interval.inSeconds;
    if (seconds <= 0) {
      return _store(_storage.deleteMinCheckSeconds);
    }
    return _store(() => _storage.writeMinCheckSeconds(seconds));
  }

  Future<HarmonyConfigCacheMetadata?> readConfigCache() async {
    final current = session;
    if (current == null || !isAuthorized) {
      return null;
    }
    final raw = await _store(_storage.readConfigCache);
    if (session?.token != current.token || !isAuthorized) {
      return null;
    }
    final metadata = HarmonyConfigCacheMetadata.fromJson(raw);
    return metadata?.username == current.username ? metadata : null;
  }

  Future<void> persistInstalledConfigValidators({
    required String expectedToken,
    String? lastModified,
    String? etag,
    String? configVersion,
  }) async {
    final generation = _generation;
    await _store(() async {
      _checkGeneration(generation);
      if (!isAuthorized || session?.token != expectedToken) {
        throw HarmonyAccountError.expired;
      }
      if (lastModified != null && lastModified.isNotEmpty) {
        await _storage.writeConfigLastModified(lastModified);
      } else {
        await _storage.deleteConfigLastModified();
      }
      if (etag != null && etag.isNotEmpty) {
        await _storage.writeConfigEtag(etag);
      } else {
        await _storage.deleteConfigEtag();
      }
      if (configVersion != null && configVersion.isNotEmpty) {
        await _storage.writeConfigVersion(configVersion);
      } else {
        await _storage.deleteConfigVersion();
      }
      _checkGeneration(generation);
    });
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
    if (_restoreBlocked) {
      return null;
    }
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
        String? raw;
        try {
          raw = await _store(_storage.readMeta);
        } catch (_) {
          _checkGeneration(generation);
          session = null;
          throw HarmonyAccountError.unavailable;
        }
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
    _restoreBlocked = true;
    session = null;
    String? issuedToken;
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
      final token = issuedToken = response.headers.value('set-auth-token');
      _checkGeneration(generation);
      if (token == null || token.isEmpty) {
        throw HarmonyAccountError.unavailable;
      }
      final data = response.data;
      final value = data is Map && data['session'] is Map
          ? _sessionFromResponse(token, data)
          : await _validate(token);
      _checkGeneration(generation);
      await _store(() async {
        _checkGeneration(generation);
        await _storage.write(token);
        await _storage.writeMeta(jsonEncode(value.toJson()));
        if (await _storage.read() != token) {
          throw HarmonyAccountError.unavailable;
        }
      });
      _checkGeneration(generation);
      _restoreBlocked = false;
      return session = value;
    } catch (error) {
      if (_generation == generation) {
        try {
          await clear();
        } catch (_) {}
      }
      if (issuedToken != null && issuedToken.isNotEmpty) {
        try {
          await _request(
            '/api/auth/sign-out',
            method: 'POST',
            data: {},
            token: issuedToken,
          );
        } catch (_) {}
      }
      if (error is HarmonyAccountError) {
        rethrow;
      }
      throw HarmonyAccountError.unavailable;
    }
  }

  Future<HarmonySession> _validate(String token) async {
    final response = await _request('/api/auth/get-session', token: token);
    return _sessionFromResponse(token, response.data);
  }

  HarmonySession _sessionFromResponse(String token, Object? data) {
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

  /// Lightweight version probe (GET only). Returns null when the server has no `/version` route.
  Future<HarmonyConfigVersionInfo?> fetchConfigVersionInfo() async {
    if (versionEndpointSupported == false) return null;
    if (!isAuthorized) throw HarmonyAccountError.expired;
    try {
      final response = await _request(
        harmonyConfigVersionPath,
        token: session!.token,
      );
      if (response.statusCode == 404) {
        versionEndpointSupported = false;
        return null;
      }
      versionEndpointSupported = true;
      return HarmonyConfigVersionInfo.fromJson(response.data);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        versionEndpointSupported = false;
        return null;
      }
      rethrow;
    }
  }

  /// Conditional GET (never HEAD). Returns true when config is unchanged (304).
  Future<bool> probeConfigNotModified() async {
    final download = await downloadConfig(
      ifModifiedSince: await readConfigLastModified(),
      ifNoneMatch: await readConfigEtag(),
    );
    return download.notModified;
  }

  Future<HarmonyConfigDownload> downloadConfig({
    String? ifNoneMatch,
    String? ifModifiedSince,
  }) async {
    if (!isAuthorized) {
      throw HarmonyAccountError.expired;
    }
    final token = session!.token;
    final generation = _generation;
    final response = await _request(
      harmonyConfigPath,
      token: token,
      responseType: ResponseType.stream,
      headers: {
        if (ifNoneMatch != null && ifNoneMatch.isNotEmpty)
          'If-None-Match': ifNoneMatch,
        if (ifModifiedSince != null && ifModifiedSince.isNotEmpty)
          'If-Modified-Since': ifModifiedSince,
      },
    );
    _checkGeneration(generation);
    if (session?.token != token || !isAuthorized) {
      throw HarmonyAccountError.expired;
    }
    if (response.statusCode == 304) {
      final etag = response.headers.value('etag');
      final version = response.headers.value('x-config-version');
      return HarmonyConfigDownload(
        notModified: true,
        etag: etag ?? ifNoneMatch,
        lastModified:
            response.headers.value('last-modified') ?? ifModifiedSince,
        configVersion: version,
        profileUpdateInterval: null,
      );
    }
    final stream = response.data;
    if (stream is! ResponseBody) {
      throw HarmonyAccountError.config;
    }
    final builder = BytesBuilder(copy: false);
    var length = 0;
    try {
      await for (final chunk in stream.stream) {
        _checkGeneration(generation);
        length += chunk.length;
        if (length > harmonyConfigMaxBytes) {
          throw HarmonyAccountError.config;
        }
        builder.add(chunk);
      }
    } on HarmonyAccountError {
      rethrow;
    } catch (_) {
      throw HarmonyAccountError.unavailable;
    }
    _checkGeneration(generation);
    if (session?.token != token || !isAuthorized) {
      throw HarmonyAccountError.expired;
    }
    var bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      throw HarmonyAccountError.config;
    }
    final lastModified = response.headers.value('last-modified');
    final etag = response.headers.value('etag');
    var configVersion = response.headers.value('x-config-version');
    if (utf8.decode(bytes).trimLeft().startsWith('{')) {
      try {
        final remote = HarmonyRemoteConfig.decode(
          bytes,
          '${globalState.packageInfo.version}+${globalState.packageInfo.buildNumber}',
        );
        if (configVersion != null && configVersion != remote.version) {
          throw const FormatException('Version mismatch');
        }
        configVersion = remote.version;
        bytes = remote.profileBytes;
      } catch (_) {
        throw HarmonyAccountError.config;
      }
    }
    final headerInterval = response.headers.value('profile-update-interval');
    return HarmonyConfigDownload(
      bytes: Uint8List.fromList(bytes),
      etag: etag,
      lastModified: lastModified,
      configVersion: configVersion,
      profileUpdateInterval: profileUpdateIntervalFromHeader(headerInterval),
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
    if (storageFailure != null) {
      Error.throwWithStackTrace(storageFailure, storageStackTrace!);
    }
  }

  Future<void> clear() {
    ++_generation;
    // A broken keystore must not silently sign this process back in. Only a
    // subsequent successful explicit login lifts this barrier.
    _restoreBlocked = true;
    session = null;
    versionEndpointSupported = null;
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
    assert(
      method != 'HEAD',
      'HEAD is not allowed for Harmony config endpoints',
    );
    final uri = Uri.tryParse(_http.options.baseUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw HarmonyAccountError.unavailable;
    }
    final configPath =
        path == harmonyConfigPath || path == harmonyConfigVersionPath;
    try {
      return await _requestWithRouteFallback(
        path,
        method: method,
        data: data,
        token: token,
        login: login,
        responseType: responseType,
        headers: headers,
        configPath: configPath,
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw login
            ? HarmonyAccountError.credentials
            : HarmonyAccountError.expired;
      }
      if (status == 429) throw HarmonyAccountError.rateLimited;
      if (configPath && (status == null || status >= 500)) {
        throw HarmonyAccountError.unavailable;
      }
      if (configPath) throw HarmonyAccountError.config;
      throw HarmonyAccountError.unavailable;
    }
  }

  Future<Response<dynamic>> _requestWithRouteFallback(
    String path, {
    required String method,
    Object? data,
    String? token,
    required bool login,
    required ResponseType responseType,
    Map<String, String>? headers,
    required bool configPath,
  }) async {
    try {
      return await _dioRequest(
        path: path,
        method: method,
        data: data,
        token: token,
        responseType: responseType,
        headers: headers,
        viaLocalProxy: false,
      );
    } on DioException catch (error) {
      if (!configPath ||
          localMixedProxyPort == null ||
          !_shouldRetryViaProxy(error)) {
        rethrow;
      }
    }
    return _dioRequest(
      path: path,
      method: method,
      data: data,
      token: token,
      responseType: responseType,
      headers: headers,
      viaLocalProxy: true,
    );
  }

  Future<Response<dynamic>> _dioRequest({
    required String path,
    required String method,
    Object? data,
    String? token,
    required ResponseType responseType,
    Map<String, String>? headers,
    required bool viaLocalProxy,
  }) async {
    final options = Options(
      method: method,
      responseType: responseType,
      validateStatus: (status) =>
          status != null && (status >= 200 && status < 300 || status == 304),
      headers: {
        if (token != null) 'Authorization': 'Bearer $token',
        ...?headers,
      },
    );
    if (_http.httpClientAdapter is! IOHttpClientAdapter) {
      return _http.request<dynamic>(path, data: data, options: options);
    }
    return _performRequest(
      path,
      method: method,
      data: data,
      token: token,
      responseType: responseType,
      headers: headers,
      viaLocalProxy: viaLocalProxy,
    );
  }

  bool _shouldRetryViaProxy(DioException error) {
    if (error.response != null) return false;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout;
  }

  Future<Response<dynamic>> _performRequest(
    String path, {
    required String method,
    Object? data,
    String? token,
    required ResponseType responseType,
    Map<String, String>? headers,
    required bool viaLocalProxy,
  }) async {
    final port = localMixedProxyPort;
    final previousAdapter = _http.httpClientAdapter;
    _http.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        if (viaLocalProxy && port != null) {
          client.findProxy = (_) => 'PROXY localhost:$port';
        } else {
          client.findProxy = (_) => 'DIRECT';
        }
        return client;
      },
    );
    try {
      return await _http.request<dynamic>(
        path,
        data: data,
        options: Options(
          method: method,
          responseType: responseType,
          followRedirects: false,
          validateStatus: (status) =>
              status != null &&
              (status >= 200 && status < 300 ||
                  path == harmonyConfigPath && status == 304),
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
            ...?headers,
          },
        ),
      );
    } finally {
      _http.httpClientAdapter = previousAdapter;
    }
  }
}

final harmonyAccount = HarmonyAccountApi();
