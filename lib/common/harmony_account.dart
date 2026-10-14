import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/harmony_config_check.dart';
import 'package:fl_clash/common/harmony_connect.dart';
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
/// Pin: pubspec.yaml git ref 545fb022eed8ce7891028d4851a617b9a8328177 — changing
/// the plugin or channel name requires updating HarmonySessionStore together.
class HarmonySessionStore {
  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  static const _tokenKey = 'harmony_session';
  static const _metaKey = 'harmony_session_meta';
  static const _lastModifiedKey = 'harmony_config_lm';
  static const _etagKey = 'harmony_config_etag';
  static const _configVersionKey = 'harmony_config_version';
  static const _reconnectKey = 'harmony_vpn_reconnect';
  static const _configRefreshKey = 'harmony_config_refresh_sec';
  static const _minCheckKey = 'harmony_config_min_check_sec';

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

  Future<String?> readConfigEtag() =>
      _channel.invokeMethod<String>('read', _arguments(_etagKey));

  Future<void> writeConfigEtag(String value) =>
      _channel.invokeMethod<void>('write', _arguments(_etagKey, value));

  Future<void> deleteConfigEtag() =>
      _channel.invokeMethod<void>('delete', _arguments(_etagKey));

  Future<String?> readConfigVersion() =>
      _channel.invokeMethod<String>('read', _arguments(_configVersionKey));

  Future<void> writeConfigVersion(String value) =>
      _channel.invokeMethod<void>('write', _arguments(_configVersionKey, value));

  Future<void> deleteConfigVersion() =>
      _channel.invokeMethod<void>('delete', _arguments(_configVersionKey));

  Future<bool> readReconnectOnLaunch() async {
    final raw = await _channel.invokeMethod<String>('read', _arguments(_reconnectKey));
    return raw == '1';
  }

  Future<void> writeReconnectOnLaunch(bool value) => _channel.invokeMethod<void>(
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

  Future<void> writeConfigRefreshSeconds(int seconds) =>
      _channel.invokeMethod<void>(
        'write',
        _arguments(_configRefreshKey, '$seconds'),
      );

  Future<void> deleteConfigRefreshSeconds() =>
      _channel.invokeMethod<void>('delete', _arguments(_configRefreshKey));

  Future<int?> readMinCheckSeconds() async {
    final raw = await _channel.invokeMethod<String>('read', _arguments(_minCheckKey));
    return int.tryParse(raw ?? '');
  }

  Future<void> writeMinCheckSeconds(int seconds) =>
      _channel.invokeMethod<void>('write', _arguments(_minCheckKey, '$seconds'));

  Future<void> deleteMinCheckSeconds() =>
      _channel.invokeMethod<void>('delete', _arguments(_minCheckKey));

  Future<void> clearAll() async {
    await delete();
    await deleteMeta();
    await deleteConfigLastModified();
    await deleteConfigEtag();
    await deleteConfigVersion();
    await deleteReconnectOnLaunch();
    await deleteConfigRefreshSeconds();
    await deleteMinCheckSeconds();
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
  final String? etag;
  final String? configVersion;
  final bool notModified;
  final Duration? profileUpdateInterval;

  const HarmonyConfigDownload({
    this.bytes,
    this.lastModified,
    this.etag,
    this.configVersion,
    this.notModified = false,
    this.profileUpdateInterval,
  });
}

class HarmonyAccountApi {
  final Dio _http;
  final HarmonySessionStore _storage;
  HarmonySession? session;

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

  Future<String?> readConfigLastModified() => _storage.readConfigLastModified();

  Future<String?> readConfigEtag() => _storage.readConfigEtag();

  Future<String?> readConfigVersion() => _storage.readConfigVersion();

  Future<bool> readReconnectOnLaunch() => _storage.readReconnectOnLaunch();

  Future<void> setReconnectOnLaunch(bool value) =>
      _storage.writeReconnectOnLaunch(value);

  Future<Duration> readConfigRefreshInterval({
    Duration fallback = const Duration(hours: 24),
  }) async {
    final seconds = await _storage.readConfigRefreshSeconds();
    if (seconds == null || seconds <= 0) return fallback;
    return Duration(seconds: seconds);
  }

  Future<Duration> readMinCheckInterval() async {
    final seconds = await _storage.readMinCheckSeconds();
    return harmonyMinCheckIntervalFromSeconds(seconds);
  }

  Future<void> saveConfigRefreshInterval(Duration interval) {
    final seconds = interval.inSeconds;
    if (seconds <= 0) return _storage.deleteConfigRefreshSeconds();
    return _storage.writeConfigRefreshSeconds(seconds);
  }

  Future<void> saveMinCheckInterval(Duration interval) {
    final seconds = interval.inSeconds;
    if (seconds <= 0) return _storage.deleteMinCheckSeconds();
    return _storage.writeMinCheckSeconds(seconds);
  }

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
      ifModifiedSince: await _storage.readConfigLastModified(),
      ifNoneMatch: await _storage.readConfigEtag(),
    );
    return download.notModified;
  }

  Future<HarmonyConfigDownload> downloadConfig({
    String? ifModifiedSince,
    String? ifNoneMatch,
  }) async {
    if (!isAuthorized) throw HarmonyAccountError.expired;
    final response = await _request(
      harmonyConfigPath,
      token: session!.token,
      responseType: ResponseType.stream,
      headers: {
        if (ifModifiedSince != null && ifModifiedSince.isNotEmpty)
          'If-Modified-Since': ifModifiedSince,
        if (ifNoneMatch != null && ifNoneMatch.isNotEmpty)
          'If-None-Match': ifNoneMatch,
      },
    );
    if (response.statusCode == 304) {
      final etag = response.headers.value('etag');
      final version = response.headers.value('x-config-version');
      if (etag != null && etag.isNotEmpty) {
        await _storage.writeConfigEtag(etag);
      }
      if (version != null && version.isNotEmpty) {
        await _storage.writeConfigVersion(version);
      }
      return HarmonyConfigDownload(
        notModified: true,
        lastModified:
            response.headers.value('last-modified') ??
            ifModifiedSince ??
            await _storage.readConfigLastModified(),
        etag: etag ?? await _storage.readConfigEtag(),
        configVersion: version ?? await _storage.readConfigVersion(),
        profileUpdateInterval: null,
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
    final etag = response.headers.value('etag');
    if (etag != null && etag.isNotEmpty) {
      await _storage.writeConfigEtag(etag);
    }
    final configVersion = response.headers.value('x-config-version');
    if (configVersion != null && configVersion.isNotEmpty) {
      await _storage.writeConfigVersion(configVersion);
    }
    final headerInterval = response.headers.value('profile-update-interval');
    return HarmonyConfigDownload(
      bytes: Uint8List.fromList(bytes),
      lastModified: lastModified,
      etag: etag,
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
      session = null;
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
      Error.throwWithStackTrace(
        storageFailure,
        storageStackTrace ?? StackTrace.current,
      );
    }
  }

  Future<void> clear() async {
    session = null;
    versionEndpointSupported = null;
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
    assert(method != 'HEAD', 'HEAD is not allowed for Harmony config endpoints');
    final uri = Uri.tryParse(_http.options.baseUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw HarmonyAccountError.unavailable;
    }
    final configPath = path == harmonyConfigPath || path == harmonyConfigVersionPath;
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
      return await _performRequest(
        path,
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
    return _performRequest(
      path,
      method: method,
      data: data,
      token: token,
      responseType: responseType,
      headers: headers,
      viaLocalProxy: true,
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
        client.badCertificateCallback = (_, _, _) => true;
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
          validateStatus: (status) =>
              status != null && (status >= 200 && status < 300 || status == 304),
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
