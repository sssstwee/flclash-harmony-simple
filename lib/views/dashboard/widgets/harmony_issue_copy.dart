import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/common/harmony_user_issue.dart';

typedef HarmonyIssueCopy = ({String title, String detail, String action});

HarmonyIssueCopy harmonyIssueCopy(
  AppLocalizations texts,
  HarmonyUserIssue issue, {
  Map overrides = const {},
}) {
  return switch (issue) {
    HarmonyUserIssue.offlineCached => (
      title:
          (overrides['harmonyIssueTitleOfflineCached'] as String? ??
          texts.harmonyIssueTitleOfflineCached),
      detail:
          (overrides['harmonyIssueDetailOfflineCached'] as String? ??
          texts.harmonyIssueDetailOfflineCached),
      action:
          (overrides['harmonyIssueActionOfflineCached'] as String? ??
          texts.harmonyIssueActionOfflineCached),
    ),
    HarmonyUserIssue.subscriptionUnreachable => (
      title:
          (overrides['harmonyIssueTitleSubscription'] as String? ??
          texts.harmonyIssueTitleSubscription),
      detail:
          (overrides['harmonyIssueDetailSubscription'] as String? ??
          texts.harmonyIssueDetailSubscription),
      action:
          (overrides['harmonyIssueActionSubscription'] as String? ??
          texts.harmonyIssueActionSubscription),
    ),
    HarmonyUserIssue.authExpired => (
      title:
          (overrides['harmonyIssueTitleAuthExpired'] as String? ??
          texts.harmonyIssueTitleAuthExpired),
      detail:
          (overrides['harmonyIssueDetailAuthExpired'] as String? ??
          texts.harmonyIssueDetailAuthExpired),
      action:
          (overrides['harmonyIssueActionAuthExpired'] as String? ??
          texts.harmonyIssueActionAuthExpired),
    ),
    HarmonyUserIssue.vpnStartFailed => (
      title:
          (overrides['harmonyIssueTitleVpnFailed'] as String? ??
          texts.harmonyIssueTitleVpnFailed),
      detail:
          (overrides['harmonyIssueDetailVpnFailed'] as String? ??
          texts.harmonyIssueDetailVpnFailed),
      action:
          (overrides['harmonyIssueActionVpnFailed'] as String? ??
          texts.harmonyIssueActionVpnFailed),
    ),
    HarmonyUserIssue.noRoute => (
      title:
          (overrides['harmonyIssueTitleNoRoute'] as String? ??
          texts.harmonyIssueTitleNoRoute),
      detail:
          (overrides['harmonyIssueDetailNoRoute'] as String? ??
          texts.harmonyIssueDetailNoRoute),
      action:
          (overrides['harmonyIssueActionNoRoute'] as String? ??
          texts.harmonyIssueActionNoRoute),
    ),
    HarmonyUserIssue.serviceUnreachable => (
      title:
          (overrides['harmonyIssueTitleService'] as String? ??
          texts.harmonyIssueTitleService),
      detail:
          (overrides['harmonyIssueDetailService'] as String? ??
          texts.harmonyIssueDetailService),
      action:
          (overrides['harmonyIssueActionService'] as String? ??
          texts.harmonyIssueActionService),
    ),
    HarmonyUserIssue.rateLimited => (
      title:
          (overrides['harmonyIssueTitleRateLimit'] as String? ??
          texts.harmonyIssueTitleRateLimit),
      detail:
          (overrides['harmonyIssueDetailRateLimit'] as String? ??
          texts.harmonyIssueDetailRateLimit),
      action:
          (overrides['harmonyIssueActionRateLimit'] as String? ??
          texts.harmonyIssueActionRateLimit),
    ),
  };
}
