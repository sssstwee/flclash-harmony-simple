import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/widgets.dart';

/// Matches startup localization to Flutter's runtime locale resolution.
/// English is the first generated locale and the fallback for unsupported ones.
Locale resolveAppLocale(List<Locale>? preferredLocales) {
  return basicLocaleListResolution(
    preferredLocales,
    AppLocalizations.delegate.supportedLocales,
  );
}

AppLocalizations get currentAppLocalizations => AppLocalizations.current;
