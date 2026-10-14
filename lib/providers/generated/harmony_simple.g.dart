// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../harmony_simple.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(harmonyAccountApi)
final harmonyAccountApiProvider = HarmonyAccountApiProvider._();

final class HarmonyAccountApiProvider
    extends
        $FunctionalProvider<
          HarmonyAccountApi,
          HarmonyAccountApi,
          HarmonyAccountApi
        >
    with $Provider<HarmonyAccountApi> {
  HarmonyAccountApiProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'harmonyAccountApiProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$harmonyAccountApiHash();

  @$internal
  @override
  $ProviderElement<HarmonyAccountApi> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  HarmonyAccountApi create(Ref ref) {
    return harmonyAccountApi(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(HarmonyAccountApi value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<HarmonyAccountApi>(value),
    );
  }
}

String _$harmonyAccountApiHash() => r'97ec83b9712a134eef562a50703b478a122486cd';

@ProviderFor(HarmonySimple)
final harmonySimpleProvider = HarmonySimpleProvider._();

final class HarmonySimpleProvider
    extends $NotifierProvider<HarmonySimple, HarmonySimpleState> {
  HarmonySimpleProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'harmonySimpleProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$harmonySimpleHash();

  @$internal
  @override
  HarmonySimple create() => HarmonySimple();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(HarmonySimpleState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<HarmonySimpleState>(value),
    );
  }
}

String _$harmonySimpleHash() => r'da5f04142e6ff646626d09a5a671b600294f71cd';

abstract class _$HarmonySimple extends $Notifier<HarmonySimpleState> {
  HarmonySimpleState build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<HarmonySimpleState, HarmonySimpleState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<HarmonySimpleState, HarmonySimpleState>,
              HarmonySimpleState,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
