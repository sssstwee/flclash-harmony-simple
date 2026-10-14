import 'package:fl_clash/providers/harmony_simple.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

String remoteHarmonyText(WidgetRef ref, String key, String fallback) {
  final runtime = ref.watch(
    harmonySimpleProvider.select((state) => state.remoteRuntime),
  );
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
  return texts[key] as String? ?? texts[aliases[key]] as String? ?? fallback;
}
