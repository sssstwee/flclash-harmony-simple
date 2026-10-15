import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Data only. The payload is a UTF-8 JSON string hashed exactly as transmitted.
class HarmonyRemoteConfig {
  static const marker = 'harmony-runtime';
  static const profileKeys = {
    'proxies',
    'proxy-groups',
    'dns',
    'rules',
    'hosts',
  };
  static const textKeys = {
    'homeTitle',
    'ready',
    'running',
    'connecting',
    'disconnecting',
    'error',
    'login',
    'switchNode',
    'retry',
    'logout',
    'harmonyAccount',
    'harmonyAccountValue',
    'harmonyLatencyValue',
    'harmonySpeedValue',
    'harmonyConfigRefreshSuccess',
    'harmonyConfigRefreshFailed',
    'harmonyConfigRefreshDebounced',
    'harmonyRouteLabel',
    'harmonyAiRoutingLabel',
    'network',
    'harmonyHealthLabel',
    'harmonyCredentialsError',
    'harmonySessionExpired',
    'harmonyRateLimited',
    'harmonyServiceError',
    'harmonyConfigError',
    'simpleConnectFailed',
    'harmonyConfigCheckReasonOffline',
    'harmonyConfigCheckReasonRateLimit',
    'harmonyAiRoutingHint',
    'harmonyAutoReconnectOff',
    'harmonyAutoReconnectOn',
    'harmonyConfigCheckReasonServer',
    'harmonyConfigFreshAutoUpdated',
    'harmonyConfigFreshCheckFailed',
    'harmonyConfigFreshUpToDate',
    'harmonyConfigFreshUpdating',
    'harmonyConfigFreshUnknown',
    'harmonyConfigPreparing',
    'harmonyConfigRefreshTooltip',
    'harmonyConfigSyncedAt',
    'harmonyConnecting',
    'harmonyCurrentNode',
    'harmonyDisconnecting',
    'harmonyDownload',
    'harmonyHealthCheckFailed',
    'harmonyHealthCheckOk',
    'harmonyIssueActionAuthExpired',
    'harmonyIssueActionNoRoute',
    'harmonyIssueActionOfflineCached',
    'harmonyIssueActionRateLimit',
    'harmonyIssueActionService',
    'harmonyIssueActionSubscription',
    'harmonyIssueActionVpnFailed',
    'harmonyIssueDetailAuthExpired',
    'harmonyIssueDetailNoRoute',
    'harmonyIssueDetailOfflineCached',
    'harmonyIssueDetailRateLimit',
    'harmonyIssueDetailService',
    'harmonyIssueDetailSubscription',
    'harmonyIssueDetailVpnFailed',
    'harmonyIssueTitleAuthExpired',
    'harmonyIssueTitleNoRoute',
    'harmonyIssueTitleOfflineCached',
    'harmonyIssueTitleRateLimit',
    'harmonyIssueTitleService',
    'harmonyIssueTitleSubscription',
    'harmonyIssueTitleVpnFailed',
    'harmonyLatency',
    'harmonyLogin',
    'harmonyLoginHint',
    'harmonyLogout',
    'harmonyNetworkCellular',
    'harmonyNetworkOther',
    'harmonyNetworkUnknown',
    'harmonyNetworkWifi',
    'harmonyRequired',
    'harmonyRetry',
    'harmonyRouteReasonAuto',
    'harmonyRouteReasonManual',
    'harmonyRouteReasonTcp',
    'harmonySessionTraffic',
    'harmonyStatusSection',
    'harmonySwitchNode',
    'harmonyUpload',
    'harmonyUsername',
    'password',
    'simpleAutoRoute',
    'simpleConnect',
    'simpleDisconnect',
    'simpleErrorState',
    'simpleReady',
    'simpleRunning',
  };
  static const homeSections = [
    'announcement',
    'connection',
    'config',
    'issue',
    'node',
    'insights',
    'traffic',
    'account',
  ];
  static const homeDetails = ['route', 'ai', 'network', 'health'];
  static const homeMaxBytes = 64 * 1024;
  final String version;
  final String minClientVersion;
  final Map<String, dynamic> profile;
  final Map<String, dynamic> runtime;

  const HarmonyRemoteConfig(
    this.version,
    this.profile,
    this.runtime,
    this.minClientVersion,
  );

  static void _keys(Map<String, dynamic> map, Set<String> allowed) {
    if (map.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unsupported remote field');
    }
  }

  static void _data(Object? value, {bool group = false}) {
    if (value is Map) {
      for (final entry in value.entries) {
        // Health checks are ordinary HTTP requests, not external config/code.
        if (group && entry.key == 'url') {
          final uri = entry.value is String
              ? Uri.tryParse(entry.value as String)
              : null;
          if (uri == null ||
              !uri.hasAuthority ||
              uri.host.isEmpty ||
              !{'http', 'https'}.contains(uri.scheme)) {
            throw const FormatException('Invalid health check URL');
          }
          continue;
        }
        if (entry.key is! String ||
            RegExp(
              r'script|command|external|path|url|provider',
              caseSensitive: false,
            ).hasMatch(entry.key as String)) {
          throw const FormatException('Executable or external resource field');
        }
        _data(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _data(item);
      }
    } else if (value != null &&
        value is! String &&
        value is! num &&
        value is! bool) {
      throw const FormatException('Invalid data');
    }
  }

  static Map<String, dynamic> validateRuntime(Object? value) {
    final runtime = Map<String, dynamic>.from(value as Map);
    _keys(runtime, {
      'announcement',
      'texts',
      'defaults',
      'features',
      'parameters',
      'home',
    });
    final announcement = runtime['announcement'];
    if (announcement != null &&
        (announcement is! String || announcement.runes.length > 4096)) {
      throw const FormatException('Invalid announcement');
    }
    final texts = Map<String, dynamic>.from(runtime['texts'] as Map? ?? {});
    _keys(texts, textKeys);
    if (texts.values.any(
      (text) => text is! String || text.runes.length > 256,
    )) {
      throw const FormatException('Invalid text');
    }
    for (final section in ['defaults', 'features']) {
      final values = Map<String, dynamic>.from(runtime[section] as Map? ?? {});
      _keys(
        values,
        section == 'defaults'
            ? {'showReconnectHint'}
            : {'nodeSwitcher', 'manualRefresh'},
      );
      if (values.values.any((value) => value is! bool)) {
        throw const FormatException('Invalid option');
      }
    }
    final parameters = Map<String, dynamic>.from(
      runtime['parameters'] as Map? ?? {},
    );
    _keys(parameters, {'refreshSeconds', 'checkSeconds'});
    for (final entry in parameters.entries) {
      if (entry.value is! int ||
          (entry.value as int) < 60 ||
          (entry.value as int) > 86400) {
        throw const FormatException('Invalid interval');
      }
    }
    final home = runtime['home'];
    if (home != null) {
      if (home is! Map) throw const FormatException('Invalid home layout');
      final layout = Map<String, dynamic>.from(home);
      _keys(layout, {'sections', 'details'});
      for (final entry in layout.entries) {
        final choices = entry.key == 'sections' ? homeSections : homeDetails;
        final values = entry.value;
        if (values is! List ||
            values.any(
              (value) => value is! String || !choices.contains(value),
            ) ||
            values.toSet().length != values.length ||
            (entry.key == 'sections' && !values.contains('connection'))) {
          throw const FormatException('Invalid home layout');
        }
      }
    }
    return runtime;
  }

  /// Homepage display is independent of the private proxy configuration.
  static Map<String, dynamic> decodeHome(Object? value) {
    if (value is! Map || utf8.encode(jsonEncode(value)).length > homeMaxBytes) {
      throw const FormatException('Invalid home configuration');
    }
    final document = Map<String, dynamic>.from(value);
    _keys(document, {'schemaVersion', 'announcement', 'texts', 'home'});
    if (document.remove('schemaVersion') != 1) {
      throw const FormatException('Unsupported home schema');
    }
    if ((document.containsKey('announcement') &&
            document['announcement'] is! String) ||
        (document.containsKey('texts') && document['texts'] is! Map) ||
        (document.containsKey('home') && document['home'] is! Map)) {
      throw const FormatException('Invalid home configuration');
    }
    return validateRuntime(document);
  }

  static List<int> _version(String value) {
    if (!RegExp(r'^\d+\.\d+\.\d+(\+\d+)?$').hasMatch(value)) {
      throw const FormatException('Invalid client version');
    }
    final parts = value.split(RegExp(r'[.+]')).map(int.parse).toList();
    return [...parts.take(3), parts.length > 3 ? parts[3] : 0];
  }

  static void checkClientVersion(String minimumVersion, String clientVersion) {
    final minimum = _version(minimumVersion);
    final current = _version(clientVersion);
    for (var i = 0; i < current.length; i++) {
      if (current[i] < minimum[i]) {
        throw const FormatException('Client update required');
      }
      if (current[i] > minimum[i]) break;
    }
  }

  static HarmonyRemoteConfig decode(Uint8List bytes, String clientVersion) {
    final envelope = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    _keys(envelope, {
      'schemaVersion',
      'version',
      'minClientVersion',
      'sha256',
      'payload',
    });
    if (envelope['schemaVersion'] != 1 ||
        envelope['version'] is! String ||
        (envelope['version'] as String).isEmpty ||
        envelope['payload'] is! String) {
      throw const FormatException('Invalid envelope');
    }
    checkClientVersion(envelope['minClientVersion'] as String, clientVersion);
    final payload = envelope['payload'] as String;
    if (sha256.convert(utf8.encode(payload)).toString() != envelope['sha256']) {
      throw const FormatException('Remote hash mismatch');
    }
    final data = Map<String, dynamic>.from(jsonDecode(payload) as Map);
    _keys(data, {'profile', 'runtime'});
    final profile = Map<String, dynamic>.from(data['profile'] as Map);
    _keys(profile, profileKeys);
    for (final entry in profile.entries) {
      if (entry.key == 'proxy-groups' && entry.value is List) {
        for (final group in entry.value as List) {
          _data(group, group: true);
        }
      } else {
        _data(entry.value);
      }
    }
    _keys(Map<String, dynamic>.from(profile['dns'] as Map), {
      'enable',
      'listen',
      'ipv6',
      'enhanced-mode',
      'fake-ip-range',
      'fake-ip-filter',
      'fake-ip-filter-mode',
      'nameserver',
      'fallback',
      'default-nameserver',
      'nameserver-policy',
      'fallback-filter',
      'proxy-server-nameserver',
      'direct-nameserver',
      'respect-rules',
      'use-hosts',
      'use-system-hosts',
      'direct-nameserver-follow-policy',
    });
    for (final proxy in profile['proxies'] as List) {
      _keys(Map<String, dynamic>.from(proxy as Map), {
        'name',
        'type',
        'server',
        'port',
        'password',
        'cipher',
        'udp',
        'uuid',
        'alterId',
        'security',
        'tls',
        'sni',
        'servername',
        'skip-cert-verify',
        'network',
        'flow',
        'client-fingerprint',
        'fingerprint',
        'alpn',
        'ws-opts',
        'grpc-opts',
        'http-opts',
        'h2-opts',
        'reality-opts',
        'packet-encoding',
        'tfo',
        'mptcp',
        'username',
        'auth-str',
        'auth',
        'up',
        'down',
        'obfs',
        'obfs-password',
        'version',
        'protocol',
        'protocol-param',
        'obfs-param',
        'private-key',
        'public-key',
        'pre-shared-key',
        'ip',
        'ipv6',
        'reserved',
        'mtu',
        'token',
        'congestion-controller',
        'disable-sni',
        'reduce-rtt',
        'heartbeat-interval',
        'udp-relay-mode',
        'udp-over-tcp',
        'udp-over-tcp-version',
        'dialer-proxy',
      });
      if (!{
        'ss',
        'ssr',
        'vmess',
        'vless',
        'trojan',
        'hysteria',
        'hysteria2',
        'tuic',
        'wireguard',
        'socks5',
        'http',
        'snell',
        'anytls',
        'direct',
        'reject',
      }.contains(proxy['type'])) {
        throw const FormatException('Unsupported proxy protocol');
      }
    }
    for (final group in profile['proxy-groups'] as List) {
      final map = Map<String, dynamic>.from(group as Map);
      _keys(map, {
        'name',
        'type',
        'proxies',
        'interval',
        'tolerance',
        'lazy',
        'disable-udp',
        'hidden',
        'strategy',
        'timeout',
        'max-failed-times',
        'expected-status',
        'url',
        'include-all-proxies',
      });
      if (!{
        'select',
        'url-test',
        'fallback',
        'load-balance',
      }.contains(map['type'])) {
        throw const FormatException('Unsupported group type');
      }
    }
    if (profile['proxies'] is! List ||
        profile['proxy-groups'] is! List ||
        profile['rules'] is! List ||
        profile['dns'] is! Map ||
        (profile['dns'] as Map)['enable'] != true ||
        (profile['rules'] as List).any(
          (rule) => rule is! String || rule.startsWith('RULE-SET,'),
        )) {
      throw const FormatException('Invalid remote profile');
    }
    final runtime = validateRuntime(data['runtime'] ?? <String, dynamic>{});
    return HarmonyRemoteConfig(
      envelope['version'] as String,
      profile,
      runtime,
      envelope['minClientVersion'] as String,
    );
  }

  Uint8List get profileBytes => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        ...profile,
        marker: runtime,
        'harmony-min-client-version': minClientVersion,
      }),
    ),
  );

  static Map<String, dynamic> runtimeFromProfile(
    Uint8List bytes, {
    String? clientVersion,
  }) {
    final text = utf8.decode(bytes).trimLeft();
    if (!text.startsWith('{')) return {};
    final map = jsonDecode(text) as Map;
    if (clientVersion != null &&
        map.containsKey('harmony-min-client-version')) {
      checkClientVersion(
        map['harmony-min-client-version'] as String,
        clientVersion,
      );
    }
    return map.containsKey(marker) ? validateRuntime(map[marker]) : {};
  }
}
