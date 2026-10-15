import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/harmony_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, dynamic> envelope;
  setUp(() {
    envelope =
        jsonDecode(
              File(
                'backend/remote-config/config.example.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
  });
  Uint8List bytes() => Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  void mutatePayload(void Function(Map<String, dynamic>) change) {
    final payload =
        jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
    change(payload);
    envelope['payload'] = jsonEncode(payload);
    envelope['sha256'] = sha256
        .convert(utf8.encode(envelope['payload'] as String))
        .toString();
  }

  test('example preserves nodes, DNS, rules and cached runtime', () {
    final config = HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101206');
    expect(config.profile['rules'], contains('MATCH,Auto'));
    expect(config.profile['dns']['enable'], true);
    expect(
      HarmonyRemoteConfig.runtimeFromProfile(config.profileBytes),
      config.runtime,
    );
  });
  test('preserves hosted HTTP health checks and expected status', () {
    mutatePayload((data) {
      final group = data['profile']['proxy-groups'][0];
      group['url'] = 'https://api.example.test/v1/models';
      group['expected-status'] = 401;
    });
    final config = HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101503');
    final group = config.profile['proxy-groups'][0];
    expect(group['url'], 'https://api.example.test/v1/models');
    expect(group['expected-status'], 401);
  });
  test('health checks cannot load local files or executable resources', () {
    mutatePayload((data) {
      data['profile']['proxy-groups'][0]['url'] = 'file:///etc/passwd';
    });
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101503'),
      throwsFormatException,
    );
  });
  test('cached profile enforces minimum client after downgrade', () {
    final config = HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101206');
    expect(
      () => HarmonyRemoteConfig.runtimeFromProfile(
        config.profileBytes,
        clientVersion: '0.8.94+2026101205',
      ),
      throwsFormatException,
    );
  });
  test('tampered payload is rejected', () {
    envelope['payload'] = '${envelope['payload']} ';
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101206'),
      throwsFormatException,
    );
  });
  test('minimum client includes build number', () {
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101205'),
      throwsFormatException,
    );
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.95+1'),
      returnsNormally,
    );
  });
  test('unknown schema and fields are rejected', () {
    envelope['schemaVersion'] = 2;
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101206'),
      throwsFormatException,
    );
    envelope['schemaVersion'] = 1;
    envelope['script'] = 'alert(1)';
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101206'),
      throwsFormatException,
    );
  });
  test('executable and external resource fields are rejected', () {
    mutatePayload(
      (data) => data['profile']['proxies'][0]['plugin'] = {'command': 'sh'},
    );
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101206'),
      throwsFormatException,
    );
  });
  test('unknown runtime fields and unsafe interval are rejected', () {
    mutatePayload((data) => data['runtime']['features']['runCode'] = true);
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101206'),
      throwsFormatException,
    );
  });
  test('refresh interval bounds are enforced', () {
    mutatePayload((data) => data['runtime']['parameters']['checkSeconds'] = 1);
    expect(
      () => HarmonyRemoteConfig.decode(bytes(), '0.8.94+2026101206'),
      throwsFormatException,
    );
  });

  test(
    'homepage JSON and schema agree with the supported native display fields',
    () {
      final document = jsonDecode(
        File('backend/homepage/home.json').readAsStringSync(),
      );
      final schema = jsonDecode(
        File('backend/homepage/schema.json').readAsStringSync(),
      );
      final runtime = HarmonyRemoteConfig.decodeHome(document);
      expect(runtime['texts']['homeTitle'], 'CC保镖');
      expect(runtime['home']['sections'], HarmonyRemoteConfig.homeSections);
      expect(
        schema['properties']['texts']['propertyNames']['enum'],
        HarmonyRemoteConfig.textKeys.toList(),
      );
      expect(
        schema['properties']['home']['properties']['sections']['items']['enum'],
        HarmonyRemoteConfig.homeSections,
      );
      expect(
        schema['properties']['home']['properties']['details']['items']['enum'],
        HarmonyRemoteConfig.homeDetails,
      );
    },
  );

  test(
    'homepage display rejects unsupported layouts and executable fields',
    () {
      for (final bad in [
        {'schemaVersion': 2},
        {'schemaVersion': 1, 'html': '<script>run()</script>'},
        {
          'schemaVersion': 1,
          'home': {
            'sections': ['traffic'],
          },
        },
        {
          'schemaVersion': 1,
          'home': {
            'sections': ['connection', 'connection'],
          },
        },
        {
          'schemaVersion': 1,
          'home': {
            'sections': ['connection', 'unknown'],
          },
        },
        {
          'schemaVersion': 1,
          'home': {
            'details': ['network', 'unknown'],
          },
        },
        {
          'schemaVersion': 1,
          'texts': {'homeTitle': 'x' * 257},
        },
        {'schemaVersion': 1, 'announcement': 'x' * 4097},
      ]) {
        expect(
          () => HarmonyRemoteConfig.decodeHome(bad),
          throwsFormatException,
        );
      }
      expect(HarmonyRemoteConfig.decodeHome({'schemaVersion': 1}), isEmpty);
    },
  );
}
