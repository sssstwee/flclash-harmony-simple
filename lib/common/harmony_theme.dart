import 'package:flutter/material.dart';

/// Monochrome palettes for the HarmonyOS client, independent of wallpaper.
final harmonyLightColorScheme =
    ColorScheme.fromSeed(
      seedColor: Colors.black,
      brightness: Brightness.light,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    ).copyWith(
      primary: Colors.black,
      onPrimary: Colors.white,
      secondary: Colors.black,
      tertiary: Colors.black,
      surface: Colors.white,
      onSurface: Colors.black,
      onSurfaceVariant: const Color(0xff626262),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xfff5f5f5),
      surfaceContainer: const Color(0xffeeeeee),
      surfaceContainerHigh: const Color(0xffe7e7e7),
      surfaceContainerHighest: const Color(0xffdddddd),
      outlineVariant: const Color(0xffdedede),
      surfaceTint: Colors.transparent,
      error: Colors.black,
      onError: Colors.white,
      errorContainer: const Color(0xffeeeeee),
      onErrorContainer: Colors.black,
    );

final harmonyDarkColorScheme =
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

ColorScheme harmonyColorScheme(Brightness brightness) =>
    brightness == Brightness.light
    ? harmonyLightColorScheme
    : harmonyDarkColorScheme;
