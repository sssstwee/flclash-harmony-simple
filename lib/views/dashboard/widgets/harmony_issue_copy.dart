import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/common/harmony_user_issue.dart';

typedef HarmonyIssueCopy = ({String title, String detail, String action});

HarmonyIssueCopy harmonyIssueCopy(
  AppLocalizations texts,
  HarmonyUserIssue issue,
) {
  return switch (issue) {
    HarmonyUserIssue.offlineCached => (
      title: texts.harmonyIssueTitleOfflineCached,
      detail: texts.harmonyIssueDetailOfflineCached,
      action: texts.harmonyIssueActionOfflineCached,
    ),
    HarmonyUserIssue.subscriptionUnreachable => (
      title: texts.harmonyIssueTitleSubscription,
      detail: texts.harmonyIssueDetailSubscription,
      action: texts.harmonyIssueActionSubscription,
    ),
    HarmonyUserIssue.authExpired => (
      title: texts.harmonyIssueTitleAuthExpired,
      detail: texts.harmonyIssueDetailAuthExpired,
      action: texts.harmonyIssueActionAuthExpired,
    ),
    HarmonyUserIssue.vpnStartFailed => (
      title: texts.harmonyIssueTitleVpnFailed,
      detail: texts.harmonyIssueDetailVpnFailed,
      action: texts.harmonyIssueActionVpnFailed,
    ),
    HarmonyUserIssue.noRoute => (
      title: texts.harmonyIssueTitleNoRoute,
      detail: texts.harmonyIssueDetailNoRoute,
      action: texts.harmonyIssueActionNoRoute,
    ),
    HarmonyUserIssue.serviceUnreachable => (
      title: texts.harmonyIssueTitleService,
      detail: texts.harmonyIssueDetailService,
      action: texts.harmonyIssueActionService,
    ),
    HarmonyUserIssue.rateLimited => (
      title: texts.harmonyIssueTitleRateLimit,
      detail: texts.harmonyIssueDetailRateLimit,
      action: texts.harmonyIssueActionRateLimit,
    ),
  };
}
