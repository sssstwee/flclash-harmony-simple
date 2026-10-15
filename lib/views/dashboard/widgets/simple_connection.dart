import 'dart:math' as math;

import 'package:fl_clash/common/harmony_remote_ui.dart';
import 'package:fl_clash/common/harmony_remote_config.dart';
import 'package:fl_clash/providers/harmony_home_display.dart';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/common/harmony_config_freshness.dart';
import 'package:fl_clash/common/harmony_home_status.dart';
import 'package:fl_clash/common/harmony_user_issue.dart';
import 'package:fl_clash/views/dashboard/widgets/harmony_issue_copy.dart';
import 'package:fl_clash/models/models.dart';
import 'package:intl/intl.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';

enum ConnectionPhase {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class SimpleConnectionPanel extends ConsumerWidget {
  final ConnectionPhase phase;
  final VoidCallback? onToggle;
  final VoidCallback? onLogout;
  final VoidCallback? onRetry;
  final String username;
  final String? error;
  final bool usingCachedConfig;
  final String? nodeName;
  final int? nodeDelayMs;
  final HarmonyHomeStatus homeStatus;
  final HarmonyUserIssue? issue;
  final HarmonyConfigFreshness configFreshness;
  final VoidCallback? onConfigRefresh;

  const SimpleConnectionPanel({
    super.key,
    required this.phase,
    required this.username,
    this.onToggle,
    this.onLogout,
    this.onRetry,
    this.error,
    this.usingCachedConfig = false,
    this.nodeName,
    this.nodeDelayMs,
    this.homeStatus = const HarmonyHomeStatus(),
    this.issue,
    this.configFreshness = const HarmonyConfigFreshness(),
    this.onConfigRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texts = context.appLocalizations;
    final runtime = ref.watch(harmonyDisplayRuntimeProvider);
    final busy =
        phase == ConnectionPhase.connecting ||
        phase == ConnectionPhase.disconnecting;
    final running = phase == ConnectionPhase.connected;
    final issueCopy = issue == null
        ? null
        : harmonyIssueCopy(
            texts,
            issue!,
            overrides: runtime['texts'] as Map? ?? {},
          );
    final hasError =
        phase == ConnectionPhase.error || error != null || issueCopy != null;
    final status =
        issueCopy?.title ??
        switch (phase) {
          ConnectionPhase.disconnected => remoteHarmonyText(
            ref,
            'simpleReady',
            texts.simpleReady,
          ),
          ConnectionPhase.connecting when homeStatus.configSyncInProgress =>
            remoteHarmonyText(
              ref,
              'harmonyConfigPreparing',
              texts.harmonyConfigPreparing,
            ),
          ConnectionPhase.connecting => remoteHarmonyText(
            ref,
            'harmonyConnecting',
            texts.harmonyConnecting,
          ),
          ConnectionPhase.connected => remoteHarmonyText(
            ref,
            'simpleRunning',
            texts.simpleRunning,
          ),
          ConnectionPhase.disconnecting => remoteHarmonyText(
            ref,
            'harmonyDisconnecting',
            texts.harmonyDisconnecting,
          ),
          ConnectionPhase.error => remoteHarmonyText(
            ref,
            'simpleErrorState',
            texts.simpleErrorState,
          ),
        };
    final traffic = ref.watch(totalTrafficProvider);
    final live = ref.watch(
      trafficsProvider.select((state) => state.list.safeLast(const Traffic())),
    );
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final actionLabel = busy
        ? status
        : running
        ? remoteHarmonyText(ref, 'simpleDisconnect', texts.simpleDisconnect)
        : remoteHarmonyText(ref, 'simpleConnect', texts.simpleConnect);

    final issueWidgets = <Widget>[
      if (issueCopy != null)
        _IssueExplanation(copy: issueCopy, emphasized: hasError)
      else if (usingCachedConfig)
        _IssueExplanation(
          copy: (
            title: remoteHarmonyText(
              ref,
              'harmonyIssueTitleOfflineCached',
              texts.harmonyIssueTitleOfflineCached,
            ),
            detail: remoteHarmonyText(
              ref,
              'harmonyIssueDetailOfflineCached',
              texts.harmonyIssueDetailOfflineCached,
            ),
            action: remoteHarmonyText(
              ref,
              'harmonyIssueActionOfflineCached',
              texts.harmonyIssueActionOfflineCached,
            ),
          ),
          emphasized: false,
        ),
      if (hasError && issueCopy == null && error != null)
        Material(
          color: context.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              remoteHarmonyError(ref, texts, error!),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colorScheme.onErrorContainer),
            ),
          ),
        ),
      if (hasError && onRetry != null)
        Center(
          child: TextButton(
            onPressed: onRetry,
            child: Text(
              remoteHarmonyText(ref, 'harmonyRetry', texts.harmonyRetry),
            ),
          ),
        ),
    ];
    final blocks = <String, Widget?>{
      'announcement': switch (runtime['announcement']) {
        final String value when value.isNotEmpty => Card(
          child: Padding(padding: const EdgeInsets.all(16), child: Text(value)),
        ),
        _ => null,
      },
      'connection': Column(
        children: [
          IconButton(
            key: const Key('harmony_primary_connect'),
            tooltip: actionLabel,
            padding: EdgeInsets.zero,
            iconSize: 64,
            constraints: const BoxConstraints.tightFor(width: 64, height: 64),
            onPressed: busy ? null : onToggle,
            icon: ConnectionIndicator(phase: phase),
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 240),
            child: Text(
              status,
              key: ValueKey(status),
              textAlign: TextAlign.center,
              style: context.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      'config': _ConfigFreshnessRow(
        freshness: configFreshness,
        configSyncInProgress: homeStatus.configSyncInProgress,
        onRefresh: onConfigRefresh,
      ),
      'issue': issueWidgets.isEmpty ? null : Column(children: issueWidgets),
      'node': _NodeSection(
        nodeName:
            nodeName ??
            remoteHarmonyText(ref, 'simpleAutoRoute', texts.simpleAutoRoute),
        delayMs: nodeDelayMs,
      ),
      'insights': _HomeInsightSection(homeStatus: homeStatus, running: running),
      'traffic': _TrafficCard(
        uploadTotal: traffic.up.traffic.show,
        downloadTotal: traffic.down.traffic.show,
        uploadSpeed: remoteHarmonyText(
          ref,
          'harmonySpeedValue',
          '${live.up.traffic.show}/s',
          parameters: {'value': live.up.traffic.show},
        ),
        downloadSpeed: remoteHarmonyText(
          ref,
          'harmonySpeedValue',
          '${live.down.traffic.show}/s',
          parameters: {'value': live.down.traffic.show},
        ),
      ),
      'account': _AccountFooter(
        username: username,
        onLogout: busy ? null : onLogout,
      ),
    };
    final layout = runtime['home'] as Map? ?? {};
    final sections = List<String>.from(
      layout['sections'] as List? ?? HarmonyRemoteConfig.homeSections,
    );
    final children = <Widget>[];
    for (var index = 0; index < sections.length; index++) {
      final section = sections[index];
      if (section == 'node' || section == 'insights') {
        final parts = <Widget>[blocks[section]!];
        // Adjacent route blocks retain the original shared card by default.
        while (index + 1 < sections.length &&
            {'node', 'insights'}.contains(sections[index + 1])) {
          parts.add(blocks[sections[++index]]!);
        }
        children.add(
          Material(
            color: context.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var part = 0; part < parts.length; part++) ...[
                  if (part > 0)
                    Divider(
                      height: 1,
                      indent: 14,
                      endIndent: 14,
                      color: context.colorScheme.outlineVariant.withValues(
                        alpha: 0.5,
                      ),
                    ),
                  parts[part],
                ],
              ],
            ),
          ),
        );
      } else if (blocks[section] case final widget?) {
        children.add(widget);
      }
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(height: 12),
          children[index],
        ],
      ],
    );
  }
}

class _ConfigFreshnessRow extends ConsumerWidget {
  final HarmonyConfigFreshness freshness;
  final bool configSyncInProgress;
  final VoidCallback? onRefresh;

  const _ConfigFreshnessRow({
    required this.freshness,
    this.configSyncInProgress = false,
    this.onRefresh,
  });

  String _formatTime(DateTime time) {
    return DateFormat('HH:mm').format(time.toLocal());
  }

  String _message(AppLocalizations texts, WidgetRef ref) {
    if (configSyncInProgress &&
        freshness.kind == HarmonyConfigFreshnessKind.unknown) {
      return remoteHarmonyText(
        ref,
        'harmonyConfigPreparing',
        texts.harmonyConfigPreparing,
      );
    }
    final kind = freshness.displayKind;
    return switch (kind) {
      HarmonyConfigFreshnessKind.discoveringUpdate => remoteHarmonyText(
        ref,
        'harmonyConfigFreshUpdating',
        texts.harmonyConfigFreshUpdating,
      ),
      HarmonyConfigFreshnessKind.autoUpdated => remoteHarmonyText(
        ref,
        'harmonyConfigFreshAutoUpdated',
        texts.harmonyConfigFreshAutoUpdated,
      ),
      HarmonyConfigFreshnessKind.checkFailedUsingCache => remoteHarmonyText(
        ref,
        'harmonyConfigFreshCheckFailed',
        texts.harmonyConfigFreshCheckFailed(
          freshness.failureReason ??
              remoteHarmonyText(
                ref,
                'harmonyConfigCheckReasonServer',
                texts.harmonyConfigCheckReasonServer,
              ),
        ),
        parameters: {
          'reason': remoteHarmonyError(
            ref,
            texts,
            freshness.failureReason ?? texts.harmonyConfigCheckReasonServer,
          ),
        },
      ),
      HarmonyConfigFreshnessKind.unknown => remoteHarmonyText(
        ref,
        'harmonyConfigFreshUnknown',
        texts.harmonyConfigFreshUnknown,
      ),
      HarmonyConfigFreshnessKind.upToDate => remoteHarmonyText(
        ref,
        'harmonyConfigFreshUpToDate',
        texts.harmonyConfigFreshUpToDate(
          freshness.versionShort ?? '—',
          freshness.lastCheckedAt != null
              ? _formatTime(freshness.lastCheckedAt!)
              : '—',
        ),
        parameters: {
          'version': freshness.versionShort ?? '—',
          'time': freshness.lastCheckedAt != null
              ? _formatTime(freshness.lastCheckedAt!)
              : '—',
        },
      ),
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texts = context.appLocalizations;
    final busy = freshness.refreshInProgress || configSyncInProgress;
    final kind = freshness.displayKind;
    final color = kind == HarmonyConfigFreshnessKind.checkFailedUsingCache
        ? context.colorScheme.error
        : context.colorScheme.onSurfaceVariant;
    return Material(
      color: context.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                _message(texts, ref),
                style: context.textTheme.bodySmall?.copyWith(
                  color: color,
                  height: 1.35,
                ),
              ),
            ),
            IconButton(
              key: const Key('harmony_config_refresh'),
              tooltip: remoteHarmonyText(
                ref,
                'harmonyConfigRefreshTooltip',
                texts.harmonyConfigRefreshTooltip,
              ),
              onPressed: busy ? null : onRefresh,
              icon: busy
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.colorScheme.primary,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueExplanation extends StatelessWidget {
  final HarmonyIssueCopy copy;
  final bool emphasized;

  const _IssueExplanation({required this.copy, required this.emphasized});

  @override
  Widget build(BuildContext context) {
    final detailColor = emphasized
        ? context.colorScheme.onErrorContainer
        : context.colorScheme.onSurfaceVariant;
    final bg = emphasized
        ? context.colorScheme.errorContainer.withValues(alpha: 0.45)
        : context.colorScheme.surfaceContainerHighest;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              copy.detail,
              textAlign: TextAlign.start,
              style: context.textTheme.bodyMedium?.copyWith(
                color: detailColor,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              copy.action,
              style: context.textTheme.labelLarge?.copyWith(
                color: context.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeInsightSection extends ConsumerWidget {
  final HarmonyHomeStatus homeStatus;
  final bool running;

  const _HomeInsightSection({required this.homeStatus, required this.running});

  String _formatTime(DateTime time) {
    return DateFormat('HH:mm').format(time.toLocal());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texts = context.appLocalizations;
    final runtime = ref.watch(harmonyDisplayRuntimeProvider);
    final layout = runtime['home'] as Map? ?? {};
    final details = <String, ({String label, String value, bool warning})>{};
    if (homeStatus.routeKind != null) {
      details['route'] = (
        label: remoteHarmonyText(
          ref,
          'harmonyRouteLabel',
          texts.harmonyRouteLabel,
        ),
        value: switch (homeStatus.routeKind!) {
          HarmonyRouteKind.automaticGroup => remoteHarmonyText(
            ref,
            'harmonyRouteReasonAuto',
            texts.harmonyRouteReasonAuto,
          ),
          HarmonyRouteKind.tcpPreferred => remoteHarmonyText(
            ref,
            'harmonyRouteReasonTcp',
            texts.harmonyRouteReasonTcp,
          ),
          HarmonyRouteKind.manual => remoteHarmonyText(
            ref,
            'harmonyRouteReasonManual',
            texts.harmonyRouteReasonManual,
          ),
        },
        warning: false,
      );
    }
    final aiGroup = homeStatus.aiGroupName;
    if (aiGroup != null && aiGroup.isNotEmpty) {
      details['ai'] = (
        label: remoteHarmonyText(
          ref,
          'harmonyAiRoutingLabel',
          texts.harmonyAiRoutingLabel,
        ),
        value: remoteHarmonyText(
          ref,
          'harmonyAiRoutingHint',
          texts.harmonyAiRoutingHint,
        ),
        warning: false,
      );
    }
    details['network'] = (
      label: remoteHarmonyText(ref, 'network', texts.network),
      value: switch (homeStatus.networkKind) {
        HarmonyNetworkKind.wifi => remoteHarmonyText(
          ref,
          'harmonyNetworkWifi',
          texts.harmonyNetworkWifi,
        ),
        HarmonyNetworkKind.cellular => remoteHarmonyText(
          ref,
          'harmonyNetworkCellular',
          texts.harmonyNetworkCellular,
        ),
        HarmonyNetworkKind.other => remoteHarmonyText(
          ref,
          'harmonyNetworkOther',
          texts.harmonyNetworkOther,
        ),
        HarmonyNetworkKind.unknown => remoteHarmonyText(
          ref,
          'harmonyNetworkUnknown',
          texts.harmonyNetworkUnknown,
        ),
      },
      warning: false,
    );
    if (running && homeStatus.lastHealthCheckAt != null) {
      final time = _formatTime(homeStatus.lastHealthCheckAt!);
      details['health'] = (
        label: remoteHarmonyText(
          ref,
          'harmonyHealthLabel',
          texts.harmonyHealthLabel,
        ),
        value: homeStatus.lastHealthCheckOk == true
            ? remoteHarmonyText(
                ref,
                'harmonyHealthCheckOk',
                texts.harmonyHealthCheckOk(time),
                parameters: {'time': time},
              )
            : remoteHarmonyText(
                ref,
                'harmonyHealthCheckFailed',
                texts.harmonyHealthCheckFailed(time),
                parameters: {'time': time},
              ),
        warning: homeStatus.lastHealthCheckOk != true,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            remoteHarmonyText(
              ref,
              'harmonyStatusSection',
              texts.harmonyStatusSection,
            ),
            style: context.textTheme.labelMedium?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (final key
              in layout['details'] as List? ?? HarmonyRemoteConfig.homeDetails)
            if (details[key] case final detail?)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 72,
                      child: Text(
                        detail.label,
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        detail.value,
                        style: context.textTheme.bodySmall?.copyWith(
                          color: detail.warning
                              ? context.colorScheme.error
                              : context.colorScheme.onSurface,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _NodeSection extends ConsumerWidget {
  final String nodeName;
  final int? delayMs;

  const _NodeSection({required this.nodeName, this.delayMs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texts = context.appLocalizations;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            remoteHarmonyText(
              ref,
              'harmonyCurrentNode',
              texts.harmonyCurrentNode,
            ),
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
              remoteHarmonyText(
                ref,
                'harmonyLatencyValue',
                '${remoteHarmonyText(ref, 'harmonyLatency', texts.harmonyLatency)}: $delayMs ms',
                parameters: {
                  'label': remoteHarmonyText(
                    ref,
                    'harmonyLatency',
                    texts.harmonyLatency,
                  ),
                  'delay': '$delayMs',
                },
              ),
              style: context.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _TrafficCard extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final texts = context.appLocalizations;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: context.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              remoteHarmonyText(
                ref,
                'harmonySessionTraffic',
                texts.harmonySessionTraffic,
              ),
              style: context.textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _TrafficStat(
                    label: remoteHarmonyText(
                      ref,
                      'harmonyUpload',
                      texts.harmonyUpload,
                    ),
                    total: uploadTotal,
                    speed: uploadSpeed,
                    icon: Icons.arrow_upward_rounded,
                  ),
                ),
                SizedBox(
                  height: 58,
                  child: VerticalDivider(
                    width: 24,
                    color: context.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
                Expanded(
                  child: _TrafficStat(
                    label: remoteHarmonyText(
                      ref,
                      'harmonyDownload',
                      texts.harmonyDownload,
                    ),
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
            Text(label, style: context.textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          speed,
          style: context.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(total, style: context.textTheme.bodySmall),
      ],
    );
  }
}

class _AccountFooter extends ConsumerWidget {
  final String username;
  final VoidCallback? onLogout;

  const _AccountFooter({required this.username, this.onLogout});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texts = context.appLocalizations;
    return Row(
      children: [
        Icon(
          Icons.person_outline_rounded,
          size: 18,
          color: context.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            remoteHarmonyText(
              ref,
              'harmonyAccountValue',
              '${remoteHarmonyText(ref, 'harmonyAccount', texts.harmonyAccount)}: $username',
              parameters: {
                'label': remoteHarmonyText(
                  ref,
                  'harmonyAccount',
                  texts.harmonyAccount,
                ),
                'username': username,
              },
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: onLogout,
          child: Text(
            remoteHarmonyText(ref, 'harmonyLogout', texts.harmonyLogout),
          ),
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
    duration: const Duration(milliseconds: 2400),
  );

  void _syncAnimation() {
    if (widget.phase != ConnectionPhase.error &&
        !MediaQuery.disableAnimationsOf(context)) {
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
    final awake = connected || widget.phase == ConnectionPhase.connecting;
    final errored = widget.phase == ConnectionPhase.error;
    final busy =
        widget.phase == ConnectionPhase.connecting ||
        widget.phase == ConnectionPhase.disconnecting;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    const ringColor = Color(0xffb0b0b0);
    return Center(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final pulse = (1 - math.cos(_pulse.value * math.pi * 2)) / 2;
          return Transform.scale(
            scale: reducedMotion || errored
                ? 1
                : 1 + pulse * (busy ? 0.025 : 0.015),
            child: DecoratedBox(
              key: const Key('harmony_connection_glow'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: reducedMotion || errored
                    ? const []
                    : [
                        BoxShadow(
                          color: scheme.primary.withValues(
                            alpha: (connected ? 0.12 : 0.06) + pulse * 0.08,
                          ),
                          blurRadius: 10 + pulse * 8,
                          spreadRadius: 1 + pulse * 2,
                        ),
                      ],
              ),
              child: AnimatedContainer(
                duration: reducedMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 360),
                curve: Curves.easeOutCubic,
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: awake
                      ? const Color(0xff1765f6)
                      : const Color(0xff0e3d94),
                  border: Border.all(color: ringColor, width: 1.5),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (busy)
                      SizedBox.square(
                        dimension: 56,
                        child: CircularProgressIndicator(
                          value: reducedMotion ? 0.65 : null,
                          color: const Color(0xfff8fbff),
                          strokeWidth: 3,
                        ),
                      ),
                    AnimatedSwitcher(
                      duration: reducedMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.85,
                            end: 1,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: Opacity(
                        key: ValueKey(
                          awake
                              ? 'harmony_guardian_active'
                              : 'harmony_guardian_idle',
                        ),
                        opacity: awake ? 1 : 0.6,
                        child: SvgPicture.asset(
                          'assets/images/cc_guardian.svg',
                          width: 56,
                          height: 56,
                          excludeFromSemantics: true,
                        ),
                      ),
                    ),
                    if (errored)
                      const Positioned(
                        right: 3,
                        bottom: 3,
                        child: Icon(
                          Icons.error_rounded,
                          key: Key('harmony_connection_error'),
                          size: 18,
                          color: Color(0xfff8fbff),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
