import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _Handler extends CoreHandlerInterface {
  final List<Map<String, dynamic>> requests = [];
  String? response;

  @override
  final Completer<void> completer = Completer<void>()..complete();

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async {
    requests.add({
      'method': method,
      'data': data == null ? null : json.decode(data as String),
      'timeout': timeout,
    });
    return response as T?;
  }

  @override
  Future<bool> destroy() async => true;

  @override
  Future<String> preload() async => '';

  @override
  Future<bool> shutdown(bool isUser) async => true;
}

void main() {
  tearDown(CoreController.resetInstance);

  test(
    'unacknowledged proxy change is an error, never silent success',
    () async {
      final handler = _Handler();
      final result = await handler.changeProxy(
        const ChangeProxyParams(groupName: 'managed', proxyName: 'leaf'),
      );
      expect(result, isNotEmpty);
    },
  );

  test(
    'strict health is distinct from latency and requests a bounded probe',
    () async {
      final handler = _Handler()
        ..response =
            '{"name":"DIRECT","url":"https://example.test","value":12}';
      final controller = CoreController.test(handler);
      final health = await controller.getHealthDelay(
        'https://example.test',
        'DIRECT',
      );
      expect(health.value, 12);
      expect(handler.requests.single['method'], ActionMethod.asyncTestDelay);
      expect(handler.requests.single['data'], {
        'proxy-name': 'DIRECT',
        'timeout': 4000,
        'test-url': 'https://example.test',
        'health-check': true,
      });
      expect(handler.requests.single['timeout'], const Duration(seconds: 5));
      handler.requests.clear();
      await controller.getDelay('https://example.test', 'DIRECT');
      expect((handler.requests.single['data'] as Map)['health-check'], isNull);
    },
  );

  test(
    'managed refresh is awaitable with an explicit unsuccessful fallback',
    () async {
      final handler = _Handler();
      final controller = CoreController.test(handler);
      expect(await controller.refreshHarmonyHealth(), isFalse);
      expect(handler.requests.single['data'], {'refresh-managed': true});
      expect(handler.requests.single['timeout'], const Duration(seconds: 15));
      handler.response = 'true';
      expect(await controller.refreshHarmonyHealth(), isTrue);
    },
  );

  test(
    'portal state requires an explicit native fact; missing state is unknown',
    () async {
      final handler = _Handler();
      final controller = CoreController.test(handler);
      expect(await controller.getHarmonyNetworkState(), (
        connected: null,
        captivePortal: false,
      ));
      handler.response = '{"connected":true,"captivePortal":true}';
      expect(await controller.getHarmonyNetworkState(), (
        connected: true,
        captivePortal: true,
      ));
    },
  );
}
