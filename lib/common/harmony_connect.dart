/// Parses Mihomo `profile-update-interval` (seconds) from config YAML text.
Duration? profileUpdateIntervalFromYaml(String yamlText) {
  final match = RegExp(
    r'^profile-update-interval:\s*(\d+)\s*$',
    multiLine: true,
  ).firstMatch(yamlText);
  if (match == null) return null;
  return profileUpdateIntervalFromValue(match.group(1));
}

Duration? profileUpdateIntervalFromValue(Object? value) {
  if (value == null) return null;
  final int? seconds = switch (value) {
    final int v => v,
    final double v => v.round(),
    final String v => int.tryParse(v.trim()),
    _ => null,
  };
  if (seconds == null || seconds <= 0) return null;
  return Duration(seconds: seconds);
}

/// Clash subscription `profile-update-interval` response header (seconds).
Duration? profileUpdateIntervalFromHeader(String? header) {
  if (header == null || header.trim().isEmpty) return null;
  return profileUpdateIntervalFromValue(header.trim());
}
