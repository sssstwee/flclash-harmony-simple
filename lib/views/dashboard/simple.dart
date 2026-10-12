import 'dart:async';

import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'widgets/simple_connection.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SimpleDashboardView extends ConsumerStatefulWidget {
  final HarmonyAccountApi? accountApi;
  const SimpleDashboardView({super.key, this.accountApi});

  @override
  ConsumerState<SimpleDashboardView> createState() =>
      _SimpleDashboardViewState();
}

class _SimpleDashboardViewState extends ConsumerState<SimpleDashboardView>
    with WidgetsBindingObserver {
  late final HarmonyAccountApi _api = widget.accountApi ?? harmonyAccount;
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = true;
  bool _disconnecting = false;
  String? _error;
  Profile? _remoteProfile;
  Timer? _sessionTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
    _sessionTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _checkSession(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionTimer?.cancel();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_checkSession());
  }

  Future<void> _restore() async {
    try {
      final session = await _api.restore();
      if (session != null && mounted) await _loadRemoteProfile();
    } catch (error) {
      if (mounted) _error = _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkSession() async {
    if (_busy || _api.session == null) return;
    try {
      if (await _api.restore() == null) await _logout(expired: true);
    } on HarmonyAccountError catch (error) {
      if (error == HarmonyAccountError.expired) await _logout(expired: true);
    } catch (_) {
      // A temporary network failure does not interrupt an active VPN.
    }
  }

  String _message(Object error) {
    final texts = context.appLocalizations;
    return switch (error) {
      HarmonyAccountError.credentials => texts.harmonyCredentialsError,
      HarmonyAccountError.expired => texts.harmonySessionExpired,
      HarmonyAccountError.rateLimited => texts.harmonyRateLimited,
      HarmonyAccountError.config => texts.harmonyConfigError,
      _ => texts.harmonyServiceError,
    };
  }

  Future<void> _login() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.login(_username.text, _password.text);
      _password.clear();
      if (mounted) await _loadRemoteProfile();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      _password.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadRemoteProfile() async {
    final bytes = await _api.downloadConfig();
    if (!mounted) return;
    await ref.read(coreActionProvider.notifier).tryStartCore();
    final old = ref
        .read(profilesProvider)
        .where((p) => p.url.isEmpty && p.label == appDisplayName)
        .firstOrNull;
    final profile = await (old ?? Profile.normal(label: appDisplayName))
        .saveFile(bytes);
    if (!mounted) return;
    ref
        .read(profilesActionProvider.notifier)
        .putProfile(profile.copyWith(autoUpdate: false));
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
    _remoteProfile = profile;
    await ref.read(setupActionProvider.notifier).applyProfile(force: true);
  }

  Future<void> _logout({bool expired = false}) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(setupActionProvider.notifier).updateStatus(false);
      await _api.logout();
      final profile = _remoteProfile;
      _remoteProfile = null;
      if (profile != null) {
        await ref
            .read(profilesActionProvider.notifier)
            .deleteProfile(profile.id);
        await (await profile.file).safeDelete();
      }
    } catch (_) {
      // Always remove local authorization, even if cache cleanup fails.
      await _api.clear();
      _remoteProfile = null;
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _error = expired
              ? context.appLocalizations.harmonySessionExpired
              : null;
        });
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final texts = context.appLocalizations;
    final setup = ref.read(setupActionProvider.notifier);
    final running = ref.read(isStartProvider);
    if (_api.session == null) return;
    setState(() {
      _busy = true;
      _disconnecting = running;
      _error = null;
    });
    try {
      if (running) {
        await setup.updateStatus(false);
        return;
      }
      // Fetch an authorized, current configuration for every new connection.
      await _loadRemoteProfile();
      final profile = _remoteProfile!;
      if (profile.id != ref.read(currentProfileIdProvider)) return;
      ref
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith(mode: Mode.rule));
      ref
          .read(vpnSettingProvider.notifier)
          .update((state) => state.copyWith(enable: true));
      await setup.applyProfile(force: true);
      final groups = ref.read(groupsProvider);
      final config = await coreController.getConfig(profile.id);
      final group = connectionGroup(
        groups,
        system.isOhos
            ? defaultRoutingRules(config)
            : List<String>.from(config['rules'] ?? const <String>[]),
      );
      final selected = group == null
          ? null
          : await autoSelectProxy(
              group,
              groups,
              (name) async => (await coreController.getDelay(
                group.testUrl ?? ref.read(appSettingProvider).testUrl,
                name,
              )).value,
            );
      if (!mounted) return;
      if (selected == null) {
        setState(() => _error = texts.simpleNoRoute);
        return;
      }
      // Persist child selectors before their parents, then apply once.
      for (final entry in selected.selections.entries.toList().reversed) {
        await ref
            .read(proxiesActionProvider.notifier)
            .changeProxy(groupName: entry.key, proxyName: entry.value);
        ref
            .read(profilesActionProvider.notifier)
            .updateCurrentSelectedMap(entry.key, entry.value);
      }
      ref
          .read(proxiesActionProvider.notifier)
          .updateCurrentGroupName(group!.name);
      await setup.updateStatus(true, isInit: true);
      if (mounted && !ref.read(isStartProvider)) {
        setState(() => _error = texts.simpleConnectFailed);
      }
    } catch (error) {
      if (mounted) {
        await setup.updateStatus(false);
        if (error == HarmonyAccountError.expired) {
          await _logout(expired: true);
        } else if (mounted) {
          setState(
            () => _error = error is HarmonyAccountError
                ? _message(error)
                : texts.simpleConnectFailed,
          );
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    final running = ref.watch(isStartProvider);
    final session = _api.session;
    final ready = ref.watch(initProvider);
    final phase = _busy
        ? _disconnecting
              ? ConnectionPhase.disconnecting
              : ConnectionPhase.connecting
        : running
        ? ConnectionPhase.connected
        : ConnectionPhase.disconnected;
    return CommonScaffold(
      title: appDisplayName,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: session != null
              ? SimpleConnectionPanel(
                  phase: phase,
                  username: session.username,
                  error: _error,
                  onToggle: ready ? _toggle : null,
                  onLogout: () => _logout(),
                )
              : AutofillGroup(
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(24),
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 64,
                          color: context.colorScheme.primary,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          texts.harmonyLogin,
                          textAlign: TextAlign.center,
                          style: context.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          texts.harmonyLoginHint,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                        TextFormField(
                          controller: _username,
                          enabled: !_busy,
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: texts.harmonyUsername,
                          ),
                          validator: (value) => value?.trim().isNotEmpty == true
                              ? null
                              : texts.harmonyRequired,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _password,
                          enabled: !_busy,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: texts.password,
                          ),
                          validator: (value) => value?.isNotEmpty == true
                              ? null
                              : texts.harmonyRequired,
                          onFieldSubmitted: (_) => _login(),
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                          ),
                          onPressed: _busy || !ready ? null : _login,
                          child: _busy
                              ? const SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(texts.harmonyLogin),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: context.colorScheme.error),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
