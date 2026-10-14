import 'package:fl_clash/common/harmony_account.dart';

/// Plain-language issue shown on the simple home screen (novice UX).
enum HarmonyUserIssue {
  /// Cached profile; server refresh failed or skipped (network).
  offlineCached,

  /// Could not download a fresh config from the backend.
  subscriptionUnreachable,

  /// Session token expired.
  authExpired,

  /// VPN / TUN failed to start after line selection.
  vpnStartFailed,

  /// No node passed latency selection.
  noRoute,

  /// Generic backend unreachable.
  serviceUnreachable,

  /// Rate limited on auth API.
  rateLimited,
}

HarmonyUserIssue? harmonyUserIssueFromAccount(HarmonyAccountError error) {
  return switch (error) {
    HarmonyAccountError.credentials => null,
    HarmonyAccountError.expired => HarmonyUserIssue.authExpired,
    HarmonyAccountError.rateLimited => HarmonyUserIssue.rateLimited,
    HarmonyAccountError.config => HarmonyUserIssue.subscriptionUnreachable,
    HarmonyAccountError.unavailable => HarmonyUserIssue.serviceUnreachable,
  };
}
