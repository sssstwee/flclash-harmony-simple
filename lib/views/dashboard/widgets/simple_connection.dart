import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ConnectionPhase {
  disconnected,
  connecting,
  checking,
  connected,
  reconnecting,
  degraded,
  offline,
  captivePortal,
  loginRequired,
  noRoute,
  disconnecting,
  error,
}

class SimpleConnectionPanel extends ConsumerWidget {
  final ConnectionPhase phase;
  final VoidCallback? onToggle;
  final VoidCallback? onLogout;
  final VoidCallback? onRetry;
  final VoidCallback? onSwitchNode;
  final String username;
  final String? error;
  final bool usingCachedConfig;
  final String? nodeName;
  final int? nodeDelayMs;
  final bool busy;
  final bool connectionRequested;
  final bool? domesticHealthy;
  final bool? foreignHealthy;

  const SimpleConnectionPanel({
    super.key,
    required this.phase,
    required this.username,
    this.onToggle,
    this.onLogout,
    this.onRetry,
    this.onSwitchNode,
    this.error,
    this.usingCachedConfig = false,
    this.nodeName,
    this.nodeDelayMs,
    this.busy = false,
    this.connectionRequested = false,
    this.domesticHealthy,
    this.foreignHealthy,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texts = context.appLocalizations;
    // Health checks/recovery do not disable the user's disconnect action.
    final actionsBlocked =
        busy ||
        phase == ConnectionPhase.connecting ||
        phase == ConnectionPhase.disconnecting;
    final canDisconnect =
        connectionRequested || phase == ConnectionPhase.connected;
    final status = switch (phase) {
      ConnectionPhase.disconnected => texts.simpleReady,
      ConnectionPhase.connecting => texts.harmonyConnecting,
      ConnectionPhase.checking => texts.harmonyChecking,
      ConnectionPhase.connected => texts.harmonyConnected,
      ConnectionPhase.reconnecting => texts.harmonyReconnecting,
      ConnectionPhase.degraded => texts.harmonyDegraded,
      ConnectionPhase.offline => texts.harmonyOffline,
      ConnectionPhase.captivePortal => texts.harmonyCaptivePortal,
      ConnectionPhase.loginRequired => texts.harmonyLoginRequired,
      ConnectionPhase.noRoute => texts.harmonyNoRoute,
      ConnectionPhase.disconnecting => texts.harmonyDisconnecting,
      ConnectionPhase.error => texts.simpleErrorState,
    };
    final guidance = switch (phase) {
      ConnectionPhase.connected => texts.harmonyHealthyHint,
      ConnectionPhase.checking => texts.harmonyCheckingHint,
      ConnectionPhase.reconnecting => texts.harmonyReconnectingHint,
      ConnectionPhase.degraded
          when domesticHealthy == false && foreignHealthy == true =>
        texts.harmonyDomesticUnavailable,
      ConnectionPhase.degraded
          when foreignHealthy == false && domesticHealthy == true =>
        texts.harmonyForeignUnavailable,
      ConnectionPhase.degraded => texts.harmonyDegradedHint,
      ConnectionPhase.offline => texts.harmonyOfflineHint,
      ConnectionPhase.captivePortal => texts.harmonyCaptivePortalHint,
      ConnectionPhase.loginRequired => texts.harmonyLoginRequiredHint,
      ConnectionPhase.noRoute => texts.harmonyNoRouteHint,
      ConnectionPhase.disconnecting => null,
      _ => texts.harmonyVpnConsentHint,
    };
    final showChecks = canDisconnect && phase != ConnectionPhase.disconnecting;
    final traffic = ref.watch(totalTrafficProvider);
    final live = ref.watch(
      trafficsProvider.select((state) => state.list.safeLast(const Traffic())),
    );
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      children: [
        ExcludeSemantics(child: ConnectionIndicator(phase: phase)),
        const SizedBox(height: 20),
        Semantics(
          liveRegion: true,
          label: status,
          child: ExcludeSemantics(
            child: AnimatedSwitcher(
              duration: reducedMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 240),
              child: Text(
                status,
                key: ValueKey(status),
                textAlign: TextAlign.center,
                style: context.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        if (guidance != null) ...[
          const SizedBox(height: 12),
          Text(guidance, textAlign: TextAlign.center),
        ],
        if (usingCachedConfig) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.history_rounded,
                size: 16,
                color: context.colorScheme.tertiary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  texts.harmonyOfflineConfig,
                  textAlign: TextAlign.center,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colorScheme.tertiary,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(72),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          onPressed: actionsBlocked ? null : onToggle,
          child: Text(
            actionsBlocked
                ? status
                : canDisconnect
                ? texts.simpleDisconnect
                : texts.simpleConnect,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 16),
          Material(
            color: context.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  if (onRetry != null) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: actionsBlocked ? null : onRetry,
                      child: Text(texts.harmonyRetry),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (showChecks) ...[
          const SizedBox(height: 16),
          _ConnectionChecks(
            domesticHealthy: domesticHealthy,
            foreignHealthy: foreignHealthy,
          ),
        ],
        const SizedBox(height: 16),
        _NodeCard(
          nodeName: nodeName ?? texts.simpleAutoRoute,
          delayMs: foreignHealthy == true ? nodeDelayMs : null,
          onSwitch: actionsBlocked ? null : onSwitchNode,
        ),
        const SizedBox(height: 16),
        _TrafficCard(
          uploadTotal: traffic.up.traffic.show,
          downloadTotal: traffic.down.traffic.show,
          uploadSpeed: '${live.up.traffic.show}/s',
          downloadSpeed: '${live.down.traffic.show}/s',
        ),
        const SizedBox(height: 24),
        _AccountFooter(
          username: username,
          onLogout: actionsBlocked ? null : onLogout,
        ),
      ],
    );
  }
}

class _ConnectionChecks extends StatelessWidget {
  final bool? domesticHealthy;
  final bool? foreignHealthy;

  const _ConnectionChecks({this.domesticHealthy, this.foreignHealthy});

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    return Card(
      elevation: 0,
      color: context.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CheckResult(
              label: texts.harmonyDomesticCheck,
              healthy: domesticHealthy,
            ),
            const SizedBox(height: 12),
            _CheckResult(
              label: texts.harmonyForeignCheck,
              healthy: foreignHealthy,
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckResult extends StatelessWidget {
  final String label;
  final bool? healthy;

  const _CheckResult({required this.label, required this.healthy});

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    final result = switch (healthy) {
      true => texts.harmonyCheckPassed,
      false => texts.harmonyCheckFailed,
      null => texts.harmonyCheckPending,
    };
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            switch (healthy) {
              true => Icons.check_circle_outline_rounded,
              false => Icons.error_outline_rounded,
              null => Icons.help_outline_rounded,
            },
            size: 20,
            color: healthy == false
                ? context.colorScheme.error
                : context.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text('$label: $result')),
        ],
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  final String nodeName;
  final int? delayMs;
  final VoidCallback? onSwitch;

  const _NodeCard({required this.nodeName, this.delayMs, this.onSwitch});

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    return Card(
      elevation: 0,
      color: context.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    texts.harmonyCurrentNode,
                    style: context.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    nodeName,
                    style: context.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (delayMs != null && delayMs! > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${texts.harmonyLatency}: $delayMs ms',
                      style: context.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            if (onSwitch != null)
              IconButton.filledTonal(
                onPressed: onSwitch,
                icon: const Icon(Icons.swap_horiz_rounded),
                tooltip: texts.harmonySwitchNode,
              ),
          ],
        ),
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  final String uploadTotal;
  final String downloadTotal;
  final String uploadSpeed;
  final String downloadSpeed;

  const _TrafficCard({
    required this.uploadTotal,
    required this.downloadTotal,
    required this.uploadSpeed,
    required this.downloadSpeed,
  });

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    return Card(
      elevation: 0,
      color: context.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              texts.harmonySessionTraffic,
              style: context.textTheme.labelMedium,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _TrafficStat(
                    label: texts.harmonyUpload,
                    total: uploadTotal,
                    speed: uploadSpeed,
                    icon: Icons.arrow_upward_rounded,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TrafficStat(
                    label: texts.harmonyDownload,
                    total: downloadTotal,
                    speed: downloadSpeed,
                    icon: Icons.arrow_downward_rounded,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TrafficStat extends StatelessWidget {
  final String label;
  final String total;
  final String speed;
  final IconData icon;

  const _TrafficStat({
    required this.label,
    required this.total,
    required this.speed,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 4),
            Expanded(child: Text(label, style: context.textTheme.labelSmall)),
          ],
        ),
        const SizedBox(height: 4),
        Text(speed, style: context.textTheme.titleSmall),
        Text(total, style: context.textTheme.bodySmall),
      ],
    );
  }
}

class _AccountFooter extends StatelessWidget {
  final String username;
  final VoidCallback? onLogout;

  const _AccountFooter({required this.username, this.onLogout});

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    return Column(
      children: [
        Text(
          '${texts.harmonyAccount}: $username',
          style: context.textTheme.bodySmall?.copyWith(
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
        TextButton(onPressed: onLogout, child: Text(texts.harmonyLogout)),
      ],
    );
  }
}

class ConnectionIndicator extends StatefulWidget {
  final ConnectionPhase phase;
  const ConnectionIndicator({super.key, required this.phase});

  @override
  State<ConnectionIndicator> createState() => _ConnectionIndicatorState();
}

class _ConnectionIndicatorState extends State<ConnectionIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  void _syncAnimation() {
    final busy =
        widget.phase == ConnectionPhase.connecting ||
        widget.phase == ConnectionPhase.checking ||
        widget.phase == ConnectionPhase.reconnecting ||
        widget.phase == ConnectionPhase.disconnecting;
    if (busy && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ConnectionIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final connected = widget.phase == ConnectionPhase.connected;
    final errored = switch (widget.phase) {
      ConnectionPhase.error ||
      ConnectionPhase.degraded ||
      ConnectionPhase.offline ||
      ConnectionPhase.captivePortal ||
      ConnectionPhase.loginRequired ||
      ConnectionPhase.noRoute => true,
      _ => false,
    };
    final busy =
        widget.phase == ConnectionPhase.connecting ||
        widget.phase == ConnectionPhase.checking ||
        widget.phase == ConnectionPhase.reconnecting ||
        widget.phase == ConnectionPhase.disconnecting;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final ringColor = errored
        ? scheme.error
        : connected || busy
        ? scheme.primary
        : scheme.outlineVariant;
    return Center(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => Transform.scale(
          scale: busy ? 1 + math.sin(_pulse.value * math.pi * 2) * 0.04 : 1,
          child: AnimatedContainer(
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: connected
                  ? LinearGradient(
                      colors: [scheme.primary, scheme.tertiary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              color: connected
                  ? null
                  : errored
                  ? scheme.errorContainer
                  : scheme.surfaceContainerHighest,
              border: Border.all(color: ringColor, width: 3),
              boxShadow: connected
                  ? [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.35),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (busy)
                  SizedBox.square(
                    dimension: 152,
                    child: CircularProgressIndicator(
                      value: reducedMotion ? 0.65 : null,
                      strokeWidth: 3,
                    ),
                  ),
                AnimatedSwitcher(
                  duration: reducedMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  child: Icon(
                    errored
                        ? Icons.error_outline_rounded
                        : connected
                        ? Icons.shield_rounded
                        : Icons.power_settings_new_rounded,
                    key: ValueKey('${connected}_$errored'),
                    size: 64,
                    color: connected
                        ? scheme.onPrimary
                        : errored
                        ? scheme.onErrorContainer
                        : scheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
