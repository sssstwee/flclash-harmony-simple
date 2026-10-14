import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/harmony_account.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/widgets/simple_connection.dart';
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
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  Timer? _sessionTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(harmonySimpleProvider.notifier).bootstrap();
    });
    _sessionTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => ref.read(harmonySimpleProvider.notifier).checkSession(),
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
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(harmonySimpleProvider.notifier).checkSession());
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final password = _password.text;
    _password.clear();
    await ref
        .read(harmonySimpleProvider.notifier)
        .login(_username.text, password);
  }

  Future<void> _showNodeSwitcher() async {
    final groups = ref.read(groupsProvider);
    final profile = ref.read(currentProfileProvider);
    final groupName = profile?.currentGroupName;
    final group = groups.getGroup(groupName ?? '');
    if (group == null || group.type != GroupType.Selector) return;
    if (!mounted) return;
    final texts = context.appLocalizations;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  texts.harmonySwitchNode,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (final proxy in group.all)
                if (proxy.type.toUpperCase() != 'DIRECT' &&
                    !proxy.type.toUpperCase().startsWith('REJECT'))
                  ListTile(
                    title: Text(proxy.name),
                    subtitle: Text(proxy.type),
                    onTap: () => Navigator.pop(context, proxy.name),
                  ),
            ],
          ),
        );
      },
    );
    if (selected == null || groupName == null) return;
    await ref
        .read(proxiesActionProvider.notifier)
        .changeProxy(groupName: groupName, proxyName: selected);
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, selected);
  }

  String? _activeNodeName() {
    final profile = ref.watch(currentProfileProvider);
    final groupName = profile?.currentGroupName;
    if (groupName == null) return null;
    return profile?.selectedMap[groupName];
  }

  int? _activeDelay(String? proxyName) {
    if (proxyName == null) return null;
    return ref.watch(delayProvider(proxyName: proxyName));
  }

  ConnectionPhase _phase(HarmonySimpleState ui, bool running) {
    if (ui.error != null && !ui.busy && !running) {
      return ConnectionPhase.error;
    }
    if (ui.busy) {
      return ui.disconnecting
          ? ConnectionPhase.disconnecting
          : ConnectionPhase.connecting;
    }
    return running ? ConnectionPhase.connected : ConnectionPhase.disconnected;
  }

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    final ui = ref.watch(harmonySimpleProvider);
    final session = ui.session;
    final ready = ref.watch(initProvider);
    final running = ref.watch(isStartProvider);
    final nodeName = _activeNodeName();
    final nodeDelay = _activeDelay(nodeName);
    final phase = _phase(ui, running);

    return CommonScaffold(
      title: appDisplayName,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: session != null
              ? SimpleConnectionPanel(
                  phase: phase,
                  username: session.username,
                  error: ui.error,
                  usingCachedConfig: ui.usingCachedConfig,
                  nodeName: nodeName,
                  nodeDelayMs: nodeDelay,
                  onToggle: ready && !ui.bootstrapping
                      ? () => ref.read(harmonySimpleProvider.notifier).toggleConnect()
                      : null,
                  onLogout: () => ref.read(harmonySimpleProvider.notifier).logout(),
                  onRetry: () => ref.read(harmonySimpleProvider.notifier).retryConnect(),
                  onSwitchNode: running ? _showNodeSwitcher : null,
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
                          enabled: !ui.busy && !ui.bootstrapping,
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
                          enabled: !ui.busy && !ui.bootstrapping,
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
                          onPressed: ui.busy || ui.bootstrapping || !ready
                              ? null
                              : _login,
                          child: ui.busy || ui.bootstrapping
                              ? const SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(texts.harmonyLogin),
                        ),
                        if (ui.error != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            ui.error!,
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
