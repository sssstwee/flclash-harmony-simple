import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/providers/harmony_home_display.dart';
import 'package:fl_clash/providers/harmony_simple.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class HomeApi extends HarmonyAccountApi {
  String? cache;
  String? requestedEtag;
  int requests = 0;
  bool storageFails = false;
  Future<Response<dynamic>> Function()? response;

  @override
  Future<String?> readHomeDisplayCache() async => cache;

  @override
  Future<void> writeHomeDisplayCache(String value) async {
    if (storageFails) throw StateError('storage unavailable');
    cache = value;
  }

  @override
  Future<Response<dynamic>> fetchHomeDisplay({String? etag}) {
    requestedEtag = etag;
    requests++;
    return response!();
  }
}

Response<dynamic> reply(Object? body, {int status = 200, String? etag}) =>
    Response<dynamic>(
      data: body,
      statusCode: status,
      requestOptions: RequestOptions(path: harmonyHomeDisplayPath),
      headers: Headers.fromMap({
        if (etag != null) 'etag': [etag],
      }),
    );

const oldDocument = {
  'schemaVersion': 1,
  'texts': {'homeTitle': 'Cached title'},
};
const newDocument = {
  'schemaVersion': 1,
  'texts': {'homeTitle': 'Updated title'},
  'home': {
    'sections': ['connection', 'traffic'],
  },
};

void main() {
  late HomeApi api;
  late ProviderContainer container;
  setUp(() {
    api = HomeApi();
    api.session = HarmonySession(
      'fixture-token',
      'fixture-user',
      DateTime.now().add(const Duration(days: 1)),
    );
    container = ProviderContainer(
      overrides: [harmonyAccountApiProvider.overrideWithValue(api)],
    );
  });
  tearDown(() => container.dispose());

  test(
    'cached UI is displayed while the independent request is pending',
    () async {
      api.cache = jsonEncode({'etag': '"old"', 'document': oldDocument});
      final pending = Completer<Response<dynamic>>();
      api.response = () => pending.future;
      final refresh = container
          .read(harmonyHomeDisplayProvider.notifier)
          .refresh();
      await pumpEventQueue();
      expect(
        container.read(harmonyHomeDisplayProvider)['texts']['homeTitle'],
        'Cached title',
      );
      expect(api.requestedEtag, '"old"');
      pending.complete(reply(null, status: 304));
      await refresh;
      expect(api.session?.username, 'fixture-user');
      expect(jsonDecode(api.cache!)['document'], oldDocument);
    },
  );

  test(
    'successful UI changes persist separately and keep the login session',
    () async {
      api.response = () async => reply(newDocument, etag: '"new"');
      await container.read(harmonyHomeDisplayProvider.notifier).refresh();
      expect(
        container.read(harmonyHomeDisplayProvider)['texts']['homeTitle'],
        'Updated title',
      );
      expect(jsonDecode(api.cache!)['document'], newDocument);
      expect(jsonDecode(api.cache!)['etag'], '"new"');
      expect(api.session?.token, 'fixture-token');
    },
  );

  test(
    'network failures and invalid updates retain the verified cached UI',
    () async {
      api.cache = jsonEncode({'etag': '"old"', 'document': oldDocument});
      api.response = () async => throw StateError('offline');
      final notifier = container.read(harmonyHomeDisplayProvider.notifier);
      await notifier.refresh();
      expect(
        container.read(harmonyHomeDisplayProvider)['texts']['homeTitle'],
        'Cached title',
      );
      api.response = () async => reply({
        'schemaVersion': 1,
        'home': {
          'sections': ['traffic'],
        },
      });
      await notifier.refresh(force: true);
      expect(
        container.read(harmonyHomeDisplayProvider)['texts']['homeTitle'],
        'Cached title',
      );
      expect(jsonDecode(api.cache!)['document'], oldDocument);
      expect(api.session?.token, 'fixture-token');
    },
  );

  test(
    'corrupt cache cannot send a stale validator or prevent valid updates',
    () async {
      api.cache = '{bad';
      api.response = () async => reply(newDocument, etag: '"new"');
      await container.read(harmonyHomeDisplayProvider.notifier).refresh();
      expect(api.requestedEtag, isNull);
      expect(
        container.read(harmonyHomeDisplayProvider)['texts']['homeTitle'],
        'Updated title',
      );
    },
  );

  test(
    'storage failure does not block display or affect authentication',
    () async {
      api.storageFails = true;
      api.response = () async => reply(newDocument);
      await container.read(harmonyHomeDisplayProvider.notifier).refresh();
      expect(
        container.read(harmonyHomeDisplayProvider)['texts']['homeTitle'],
        'Updated title',
      );
      expect(api.session?.token, 'fixture-token');
    },
  );

  test('concurrent and frequent automatic checks share one request', () async {
    final pending = Completer<Response<dynamic>>();
    api.response = () => pending.future;
    final notifier = container.read(harmonyHomeDisplayProvider.notifier);
    final first = notifier.refresh();
    await notifier.refresh(force: true);
    await pumpEventQueue();
    expect(api.requests, 1);
    pending.complete(reply(newDocument));
    await first;
    await notifier.refresh();
    expect(api.requests, 1);
  });

  test('disposed providers cannot apply an old network response', () async {
    final pending = Completer<Response<dynamic>>();
    api.response = () => pending.future;
    final refresh = container
        .read(harmonyHomeDisplayProvider.notifier)
        .refresh();
    await pumpEventQueue();
    container.dispose();
    container = ProviderContainer();
    pending.complete(reply(newDocument));
    await refresh;
    expect(api.cache, isNull);
  });
}
