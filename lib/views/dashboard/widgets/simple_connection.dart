import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:flutter/material.dart';

enum ConnectionPhase { disconnected, connecting, connected, disconnecting }

class SimpleConnectionPanel extends StatelessWidget {
  final ConnectionPhase phase;
  final VoidCallback? onToggle;
  final VoidCallback? onLogout;
  final String username;
  final String? error;

  const SimpleConnectionPanel({
    super.key,
    required this.phase,
    required this.username,
    this.onToggle,
    this.onLogout,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    final busy =
        phase == ConnectionPhase.connecting ||
        phase == ConnectionPhase.disconnecting;
    final running = phase == ConnectionPhase.connected;
    final status = switch (phase) {
      ConnectionPhase.disconnected => texts.simpleReady,
      ConnectionPhase.connecting => texts.harmonyConnecting,
      ConnectionPhase.connected => texts.simpleRunning,
      ConnectionPhase.disconnecting => texts.harmonyDisconnecting,
    };
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.all(24),
      children: [
        ConnectionIndicator(phase: phase),
        const SizedBox(height: 24),
        AnimatedSwitcher(
          duration: reducedMotion
              ? Duration.zero
              : const Duration(milliseconds: 240),
          child: Text(
            status,
            key: ValueKey(status),
            textAlign: TextAlign.center,
            style: context.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 12),
        Text(texts.harmonyAutomaticHint, textAlign: TextAlign.center),
        const SizedBox(height: 40),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
          onPressed: busy ? null : onToggle,
          icon: Icon(
            running ? Icons.stop_rounded : Icons.power_settings_new_rounded,
          ),
          label: Text(
            busy
                ? status
                : running
                ? texts.simpleDisconnect
                : texts.simpleConnect,
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 16),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        Text(
          username,
          textAlign: TextAlign.center,
          style: context.textTheme.bodySmall,
        ),
        TextButton(
          onPressed: busy ? null : onLogout,
          child: Text(texts.harmonyLogout),
        ),
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
    final busy =
        widget.phase == ConnectionPhase.connecting ||
        widget.phase == ConnectionPhase.disconnecting;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Center(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => Transform.scale(
          scale: busy ? 1 + math.sin(_pulse.value * math.pi * 2) * 0.025 : 1,
          child: AnimatedContainer(
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
            width: 144,
            height: 144,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              border: Border.all(
                color: connected || busy
                    ? scheme.primary
                    : scheme.outlineVariant,
                width: 2,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (busy)
                  SizedBox.square(
                    dimension: 132,
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
                    connected
                        ? Icons.shield_rounded
                        : Icons.power_settings_new_rounded,
                    key: ValueKey(connected),
                    size: 60,
                    color: connected
                        ? scheme.onPrimaryContainer
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
