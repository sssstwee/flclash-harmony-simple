---
name: localization
description: Use when changing FlClash UI text, scanning for hardcoded Chinese strings, updating ARB localization, or fixing generated locale output in this repository.
---

# Localization

## When To Use

Use this for localization work inside `/Users/Shared/follow/FlClash`, especially hardcoded UI text in `lib/`, ARB updates, missing translations, or generated `lib/l10n/` output that does not match source ARB values.

Do not use this for README translation sync or manual edits to generated localization Dart.

## Workflow

1. Confirm `pubspec.yaml` still uses `flutter_intl`, source ARBs under `arb/`, and generated output under `lib/l10n/`.
2. Scan user-facing Dart text before opening many files:

   ```bash
   rg -n "[\\p{Han}]" lib -g '!lib/l10n/intl/**' -g '!lib/**/generated/**'
   ```

3. Inspect the smallest relevant call sites and nearby ARB keys.
4. Add or update every source ARB:
   - `arb/intl_en.arb`
   - `arb/intl_zh_CN.arb`
   This app supports only English and Chinese. Do not add other locale ARBs.
5. Replace inline strings with existing project accessors:
   - Widgets with `BuildContext`: `context.appLocalizations.key` from `common.dart`.
   - Controllers/providers/non-widget code: `currentAppLocalizations.key` from `app_localizations.dart`.
6. Regenerate:

   ```bash
   dart run intl_utils:generate
   ```

7. Verify changed Dart files with `flutter analyze` when practical.
8. Re-run the Han-text scan for targeted strings.

## Pitfalls

- Keep the generated supported locales in sync with the English and Chinese source ARBs. Remove obsolete locale resources when removing a language; do not edit generated Dart by hand.
- Ignore `lib/l10n/intl/**` and `lib/**/generated/**` during text scans.
- If generator or analyzer hits local cache permission friction, rerun serially before treating it as a code issue.
