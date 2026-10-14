import 'package:flutter/material.dart';

/// Fixed monochrome palette for the HarmonyOS client, independent of wallpaper.
final harmonyColorScheme =
    ColorScheme.fromSeed(
      seedColor: Colors.white,
      brightness: Brightness.dark,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    ).copyWith(
      primary: Colors.white,
      onPrimary: Colors.black,
      secondary: Colors.white,
      tertiary: Colors.white,
      surface: const Color(0xff0b0b0b),
      onSurface: Colors.white,
      onSurfaceVariant: const Color(0xffb8b8b8),
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xff191919),
      surfaceContainer: const Color(0xff202020),
      surfaceContainerHigh: const Color(0xff292929),
      surfaceContainerHighest: const Color(0xff333333),
      outlineVariant: const Color(0xff393939),
      surfaceTint: Colors.transparent,
      error: Colors.white,
      onError: Colors.black,
      errorContainer: const Color(0xff333333),
      onErrorContainer: Colors.white,
    );
