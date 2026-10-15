import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/harmony_home_display.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

String remoteHarmonyText(
  WidgetRef ref,
  String key,
  String fallback, {
  Map<String, String> parameters = const {},
}) {
  final runtime = ref.watch(harmonyDisplayRuntimeProvider);
  final texts = runtime['texts'] as Map? ?? {};
  const aliases = {
    'simpleReady': 'ready',
    'simpleRunning': 'running',
    'harmonyConnecting': 'connecting',
    'harmonyDisconnecting': 'disconnecting',
    'simpleErrorState': 'error',
    'harmonyLogin': 'login',
    'harmonySwitchNode': 'switchNode',
    'harmonyRetry': 'retry',
    'harmonyLogout': 'logout',
  };
  final template = texts[key] as String? ?? texts[aliases[key]] as String?;
  if (template == null) return fallback;
  return template.replaceAllMapped(
    RegExp(r'\{(\w+)\}'),
    (match) => parameters[match[1]] ?? match[0]!,
  );
}

String remoteHarmonyError(
  WidgetRef ref,
  AppLocalizations texts,
  String message,
) {
  final keys = {
    texts.harmonyCredentialsError: 'harmonyCredentialsError',
    texts.harmonySessionExpired: 'harmonySessionExpired',
    texts.harmonyRateLimited: 'harmonyRateLimited',
    texts.harmonyServiceError: 'harmonyServiceError',
    texts.harmonyConfigError: 'harmonyConfigError',
    texts.simpleConnectFailed: 'simpleConnectFailed',
    texts.harmonyConfigCheckReasonOffline: 'harmonyConfigCheckReasonOffline',
    texts.harmonyConfigCheckReasonRateLimit:
        'harmonyConfigCheckReasonRateLimit',
    texts.harmonyConfigCheckReasonServer: 'harmonyConfigCheckReasonServer',
  };
  final key = keys[message];
  return key == null ? message : remoteHarmonyText(ref, key, message);
}
