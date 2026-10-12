import 'package:fl_clash/common/auto_proxy.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/default_routing.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/tools.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SimpleDashboardView extends ConsumerStatefulWidget {
  const SimpleDashboardView({super.key});

  @override
  ConsumerState<SimpleDashboardView> createState() =>
      _SimpleDashboardViewState();
}

class _SimpleDashboardViewState extends ConsumerState<SimpleDashboardView> {
  bool _busy = false;
  String? _error;

  Future<void> _import() async {
    final texts = context.appLocalizations;
    final url = await globalState.showCommonDialog<String>(
      child: InputDialog(
        title: texts.simpleImport,
        labelText: texts.url,
        value: '',
        autovalidateMode: AutovalidateMode.onUnfocus,
        inputFormatters: TextInputLimits.limit(TextInputLimits.url),
        validator: (value) {
          final uri = Uri.tryParse(value?.trim() ?? '');
          return uri != null &&
                  uri.host.isNotEmpty &&
                  (uri.scheme == 'https' || uri.scheme == 'http')
              ? null
              : texts.urlTip('').trim();
        },
      ),
    );
    if (url == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(coreActionProvider.notifier).tryStartCore();
      final profile = await Profile.normal(url: url.trim()).update();
      if (!mounted) return;
      ref.read(profilesActionProvider.notifier).putProfile(profile);
      ref.read(currentProfileIdProvider.notifier).value = profile.id;
      await ref.read(setupActionProvider.notifier).applyProfile(force: true);
    } catch (_) {
      if (mounted) setState(() => _error = texts.simpleImportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final texts = context.appLocalizations;
    final setup = ref.read(setupActionProvider.notifier);
    final running = ref.read(isStartProvider);
    final profile = ref.read(currentProfileProvider);
    if (!running && profile == null) {
      await _import();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (running) {
        await setup.updateStatus(false);
        return;
      }
      await ref.read(coreActionProvider.notifier).tryStartCore();
      if (profile!.id != ref.read(currentProfileIdProvider)) return;
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
    } catch (_) {
      if (mounted) {
        await setup.updateStatus(false);
        if (mounted) setState(() => _error = texts.simpleConnectFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final texts = context.appLocalizations;
    final profile = ref.watch(currentProfileProvider);
    final running = ref.watch(isStartProvider);
    final groupName = profile?.currentGroupName;
    final route = groupName == null
        ? null
        : ref.watch(selectedProxyNameProvider(groupName));
    return CommonScaffold(
      title: appDisplayName,
      actions: [
        IconButton(
          tooltip: texts.settings,
          onPressed: _busy
              ? null
              : () => BaseNavigator.push(context, const ToolsView()),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Icon(
                running ? Icons.shield_outlined : Icons.power_settings_new,
                size: 64,
                color: context.colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                _busy
                    ? texts.simpleWorking
                    : running
                    ? texts.simpleRunning
                    : texts.simpleReady,
                textAlign: TextAlign.center,
                style: context.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                profile == null
                    ? texts.simpleImportHint
                    : texts.simpleReadyHint,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.link),
                  title: Text(profile?.realLabel ?? texts.simpleNoSubscription),
                  subtitle: Text(
                    profile == null
                        ? texts.simpleImportHint
                        : texts.simpleSubscriptionReady,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy || running ? null : _import,
                ),
              ),
              if (profile != null) ...[
                const SizedBox(height: 12),
                Text(
                  '${texts.simpleRoute}: ${route ?? texts.simpleAutoRoute}',
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(64),
                ),
                onPressed: _busy ? null : _toggle,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(running ? Icons.stop : Icons.play_arrow),
                label: Text(
                  profile == null
                      ? texts.simpleImport
                      : running
                      ? texts.simpleDisconnect
                      : texts.simpleConnect,
                ),
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
    );
  }
}
