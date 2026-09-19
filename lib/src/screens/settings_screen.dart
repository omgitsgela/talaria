import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../diagnostics/error_report.dart';

import '../app_version.dart';
import '../gateway/client.dart';
import '../models/models.dart';
import '../models/reasoning_effort.dart';
import '../store/chat_store.dart';
import '../theme/markdown_preference.dart';
import '../theme/theme_preference.dart';
import '../widgets/reasoning_effort_selector.dart';

/// Settings surface (desktop parity): model switcher, profile list, the
/// toggle-style config keys (`config.get`/`config.set`), and a status block
/// (battery / verification / subscription / live sessions). Model switching
/// uses the gateway's live/deferred `config.set model` handshake; expensive
/// models require an explicit confirm (gateway returns `confirm_required`).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.store, this.configTransport});
  final ChatStore store;

  /// Config transport for the reasoning-effort card. Null in production: the
  /// card then opens its own short-lived connection from [store.config],
  /// because ChatStore does not expose its client. Tests inject a fake.
  final ConfigTransport? configTransport;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ChatStore get store => widget.store;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await Future.wait([
      store.loadModels(),
      store.loadProfiles(),
      store.pollBattery(),
      store.pollVerification(),
      store.pollSubscription(),
      store.loadActiveList(),
    ]);
    if (mounted) setState(() => _loaded = true);
    // Loading does not block the screen. ChatStore revision-guards the async
    // result so a first user tap cannot be overwritten by stale preferences.
    unawaited(store.loadPickerState());
  }

  Future<void> _pickModel(String slug) async {
    final res = await store.setModel(slug);
    if (!mounted) return;
    if (res.isConfirmRequired) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Model'),
          content: Text(res.confirmMessage.isNotEmpty
              ? res.confirmMessage
              : 'This model may be expensive. Confirm to proceed?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        final retry = await store.setModel(slug, confirmExpensive: true);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(retry.message.length > 120
                  ? '${retry.message.substring(0, 120)}…'
                  : retry.message)),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(res.message.length > 120
                ? '${res.message.substring(0, 120)}…'
                : res.message)),
      );
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _setToggle(String key, String value) async {
    final res = await store.configSet(key, value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(res.length > 120 ? '${res.substring(0, 120)}…' : res)),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              setState(() => _loaded = false);
              _load();
            },
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _AppearanceCard(),
                const SizedBox(height: 12),
                _SectionCard(
                    title: 'Model',
                    icon: Icons.smart_toy_outlined,
                    child: _ModelList(store: store, onPick: _pickModel)),
                const SizedBox(height: 12),
                _SectionCard(
                    title: 'Reasoning',
                    icon: Icons.psychology_outlined,
                    child: _ReasoningEffortCard(
                        store: store, transport: widget.configTransport)),
                const SizedBox(height: 12),
                _SectionCard(
                    title: 'Profiles',
                    icon: Icons.person_outlined,
                    child: _ProfileList(store: store)),
                const SizedBox(height: 12),
                _SectionCard(
                    title: 'Session',
                    icon: Icons.tune,
                    child: _ToggleList(store: store, onSet: _setToggle)),
                const SizedBox(height: 12),
                _SectionCard(
                    title: 'Status',
                    icon: Icons.monitor_heart_outlined,
                    child: _StatusCard(store: store)),
                const SizedBox(height: 12),
                _DisplayCard(),
                const SizedBox(height: 12),
                _DiagnosticsCard(store: store),
                const SizedBox(height: 12),
                _AboutCard(),
              ],
            ),
    );
  }
}

/// Bug-reporting support: a copyable bundle of facts about this install, plus
/// what the bundle contains and where to file it.
///
/// The capture itself lives in [ErrorReport] and is installed in EVERY build,
/// so someone running a released APK can hand back the details of a crash we
/// cannot reproduce. Paired with the README's "Reporting a bug" section.
class _DiagnosticsCard extends StatefulWidget {
  const _DiagnosticsCard({required this.store});
  final ChatStore store;

  @override
  State<_DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends State<_DiagnosticsCard> {
  static const _issueTracker = 'https://github.com/omgitsgela/talaria/issues';
  bool _copied = false;

  /// Host only. The token and the full URL are never included.
  String get _host {
    final u = Uri.tryParse(widget.store.config.baseUrl);
    return (u == null || u.host.isEmpty) ? widget.store.config.url : u.host;
  }

  Map<String, String> get _facts => {
        'app': kAppVersionLabel,
        'platform': Platform.operatingSystem,
        'platform version': Platform.operatingSystemVersion,
        'gateway host': _host,
        'conversation open':
            widget.store.activeStoredSessionId == null ? 'no' : 'yes',
        'context usage': widget.store.contextUsage.label ?? 'not reported',
      };

  Future<void> _copyReport() async {
    final ok = await ErrorReport.copy(ErrorReport.bugReport(_facts));
    if (!mounted) return;
    setState(() => _copied = ok);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Bug report copied. Paste it into the issue.'
            : 'Could not copy the report'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return _SectionCard(
      title: 'Diagnostics',
      icon: Icons.bug_report_outlined,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Something misbehaving? Copy a report and paste it into an issue.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'It includes the app version, your platform, the gateway host '
              'and the most recent error. Your gateway token is never '
              'included. An error capture can quote text from the screen, so '
              'skim it before you post.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _copyReport,
                  icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                  label: Text(_copied ? 'Copied' : 'Copy bug report'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(_issueTracker),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open issues'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// About / version card. The version comes from [kAppVersion] (kept in
/// lockstep with `pubspec.yaml`'s `version:`), so the UI, the Android
/// package metadata, and the build receipt all agree.
class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _SectionCard(
      title: 'About',
      icon: Icons.info_outline,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Row(
          children: [
            Image(
              image: const AssetImage('assets/logo.png'),
              width: 36,
              height: 36,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Talaria',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  Text(kAppVersionLabel,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                  Text('Mobile companion for the Hermes Agent gateway',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Local app appearance (light / dark / auto). Distinct from the gateway's
/// own `theme` toggle in the Session section, which themes the remote
/// dashboard — this changes only how *this* app is rendered.
class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context) {
    // The provider is present in the app shell (see main.dart). It is absent
    // when this screen is pumped in isolation (widget tests) — render a
    // sensible default and disable the control rather than throw.
    final pref = ThemePreference.maybeOf(context);
    final mode = pref?.mode.value ?? ThemeMode.dark;
    return _SectionCard(
      title: 'Appearance',
      icon: Icons.brightness_6,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              label: Text('Auto'),
              icon: Icon(Icons.brightness_auto),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: Text('Light'),
              icon: Icon(Icons.light_mode),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              label: Text('Dark'),
              icon: Icon(Icons.dark_mode),
            ),
          ],
          selected: {mode},
          onSelectionChanged: pref == null ? null : (s) => pref.set(s.first),
        ),
      ),
    );
  }
}

/// Local display preferences. Currently: whether assistant messages render as
/// rich Markdown or as plain selectable text. Distinct from the gateway's
/// `theme` (which themes the remote dashboard) — this is a pure client-side UI
/// choice persisted under `talaria.markdown` and read live by the transcript.
class _DisplayCard extends StatelessWidget {
  const _DisplayCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // The provider is present in the app shell (see main.dart). When this
    // screen is pumped in isolation (widget tests) it is absent — render a
    // sensible default (on) and disable the control rather than throw.
    final pref = MarkdownPreference.maybeOf(context);
    final on = pref?.enabled.value ?? true;
    return _SectionCard(
      title: 'Display',
      icon: Icons.format_shapes,
      child: ListenableBuilder(
        listenable: pref?.enabled ??
            _neverListenable,
        builder: (context, _) {
          final value = pref?.enabled.value ?? on;
          return SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('Render Markdown in replies',
                style: theme.textTheme.bodyLarge),
            subtitle: Text(
              'Format headings, lists, code, and links in assistant messages. '
              'Turn off for plain text.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            secondary: Icon(Icons.format_list_bulleted, color: cs.primary),
            value: value,
            onChanged: pref == null ? null : pref.set,
          );
        },
      ),
    );
  }
}

/// No-op listenable used when the [MarkdownPreference] provider is absent
/// (e.g. the settings screen pumped in isolation in a widget test). A single
/// shared instance so the `??` fallback is cheap and stable.
final _neverListenable = ChangeNotifier();

class _SectionCard extends StatelessWidget {
  const _SectionCard(
      {required this.title, required this.icon, required this.child});
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            Divider(
                height: 20, color: cs.outlineVariant.withValues(alpha: 0.3)),
            child,
          ],
        ),
      ),
    );
  }
}

/// Model picker grouped by provider. Each provider is a collapsible category
/// header (with its model count); a search field filters by model slug or
/// provider name. The active provider's group is pinned to the top and starts
/// expanded; tapping a model row (or its "Use" button) applies the switch.
/// The value sent to the gateway is preserved verbatim: the bare model slug,
/// with the provider routed via the `--provider` flag (prefixing the slug
/// would corrupt slash-containing model IDs).
class _ModelList extends StatefulWidget {
  const _ModelList({required this.store, required this.onPick});
  final ChatStore store;
  final void Function(String slug) onPick;

  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  final _search = TextEditingController();
  String _query = '';

  ChatStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearch);
    // Rebuild when the store's live state changes: a model switch moves the
    // checkmark, a bookmark reorder/ collapse persists through the store.
    store.addListener(_onStoreChanged);
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _onSearch() {
    final q = _search.text.trim();
    if (q != _query) setState(() => _query = q);
  }

  @override
  void dispose() {
    store.removeListener(_onStoreChanged);
    _search.dispose();
    super.dispose();
  }

  bool _matches(ModelOption m) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return m.slug.toLowerCase().contains(q) ||
        (m.provider?.toLowerCase().contains(q) ?? false) ||
        (m.providerName?.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final groups = store.providerGroups;
    if (groups.isEmpty) {
      return Text('No model options returned by the gateway.',
          style:
              theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant));
    }

    final searching = _query.isNotEmpty;
    // Bookmarked models pin above every provider group, in bookmark order.
    // They remain selectable even when the search filters out the provider
    // group they belong to.
    final visibleBookmarks = searching
        ? store.bookmarkedModels.where(_matches).toList()
        : store.bookmarkedModels;
    // Filter groups by the search query (a group shows if any model matches).
    final visible = <ProviderGroup>[];
    for (final g in groups) {
      final matches = g.models.where(_matches).toList();
      if (matches.isEmpty) continue;
      visible.add(matches == g.models
          ? g
          : ProviderGroup(slug: g.slug, name: g.name, models: matches));
    }
    // The search field lives outside the result list on purpose: an early
    // return for "no matches" used to drop it from the tree, which left the
    // user staring at an empty result with no way to correct the query that
    // caused it (and no keyboard, since focus died with the field).
    final searchField = Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: TextField(
        controller: _search,
        minLines: 1,
        maxLines: 1,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search models…',
          prefixIcon: const Icon(Icons.search, size: 18),
          isDense: true,
          filled: true,
          fillColor: cs.surfaceContainerHighest,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );

    if (visible.isEmpty && visibleBookmarks.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          searchField,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                Icon(Icons.search_off,
                    size: 32, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
                const SizedBox(height: 10),
                Text('No models match “$_query”.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _search.clear,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Clear search'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search field.
        searchField,
        // Bookmarked models pin above every provider group.
        if (visibleBookmarks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(Icons.star_rounded, size: 16, color: cs.tertiary),
                const SizedBox(width: 6),
                Text('Bookmarked',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Material(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final m in visibleBookmarks)
                  _ModelRow(model: m, store: store, onPick: widget.onPick),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
        // Per-provider collapsible categories.
        for (final g in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Builder(
              builder: (context) {
                final isExpanded =
                    searching || !store.isProviderCollapsed(g.slug);
                return _ProviderSection(
                  store: store,
                  group: g,
                  onPick: widget.onPick,
                  searching: searching,
                  expanded: isExpanded,
                  onToggle: () =>
                      store.setProviderCollapsed(g.slug, isExpanded),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _ProviderSection extends StatelessWidget {
  const _ProviderSection({
    required this.store,
    required this.group,
    required this.onPick,
    required this.searching,
    required this.expanded,
    required this.onToggle,
  });
  final ChatStore store;
  final ProviderGroup group;
  final void Function(String slug) onPick;
  final bool searching;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final count = group.models.length;
    // The live current-provider flag (the store tracks model switches), not
    // the gateway's load-time flag — this is what makes the header's
    // "cloud_done" + pin follow an in-app switch.
    final liveCurrent = store.providerIsCurrent(group);
    final lockedOpen = searching || expanded;
    // A Material (not a backgrounded Container) so the child ListTiles paint
    // their background/ink on THIS ancestor — a backgrounded DecoratedBox
    // between a ListTile and its Material is rejected by Flutter's
    // "ink splashes may be invisible" check.
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Category header.
          InkWell(
            onTap: searching ? null : onToggle,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    liveCurrent ? Icons.cloud_done : Icons.cloud_outlined,
                    size: 18,
                    color: liveCurrent ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(group.name,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Text('$count',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                  if (group.allUnauthenticated) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.lock_outline,
                        size: 16, color: cs.onSurfaceVariant),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    searching
                        ? Icons.expand_more
                        : (lockedOpen ? Icons.expand_less : Icons.expand_more),
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (lockedOpen)
            Column(
              children: [
                for (final m in group.models)
                  _ModelRow(model: m, store: store, onPick: onPick),
              ],
            ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow(
      {required this.model, required this.store, required this.onPick});
  final ModelOption model;
  final ChatStore store;
  final void Function(String slug) onPick;

  /// The store's identifier for this model (`provider:slug`); the same key
  /// the picker persists for bookmarks.
  String get _bookKey => '${model.provider ?? ''}:${model.slug}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // The live current check: the store tracks the model actually selected
    // (updated by config.set and gateway session.info). This is in contrast
    // to the frozen ModelOption.isCurrent, which was computed once at load
    // time and never moved after an in-app switch.
    final current = store.modelIsCurrent(model);
    final bookmarked = store.bookmarked.contains(_bookKey);
    // Keep the model ID as-is; provider routing is a separate gateway model-
    // switch flag, not a prefix to an arbitrary model ID.
    final provider = model.provider;
    final fullSlug = provider != null && provider.isNotEmpty
        ? '${model.slug} --provider $provider'
        : model.slug;
    final pickable = !current && model.authenticated;
    // Use the ListTile's own selected styling rather than wrapping it in a
    // backgrounded Container — a DecoratedBox between a ListTile and its
    // Material is rejected by Flutter's "ink splashes may be invisible" check.
    return ListTile(
      minTileHeight: 48,
      contentPadding: const EdgeInsets.only(left: 28, right: 4),
      selected: current,
      selectedTileColor: cs.primaryContainer.withValues(alpha: 0.35),
      leading: Icon(
        current ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: current ? cs.primary : cs.onSurfaceVariant,
      ),
      title: Text(model.label,
          style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: current ? FontWeight.w600 : FontWeight.w400),
          overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: bookmarked ? 'Remove bookmark' : 'Bookmark this model',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              bookmarked ? Icons.star_rounded : Icons.star_outline,
              size: 18,
              color: bookmarked ? cs.tertiary : cs.onSurfaceVariant,
            ),
            onPressed: () => store.toggleBookmark(_bookKey),
          ),
          if (!current)
            TextButton(
              onPressed: pickable ? () => onPick(fullSlug) : null,
              child: const Text('Use'),
            ),
        ],
      ),
      onTap: pickable ? () => onPick(fullSlug) : null,
      onLongPress: () => store.toggleBookmark(_bookKey),
    );
  }
}

class _ProfileList extends StatelessWidget {
  const _ProfileList({required this.store});
  final ChatStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final profiles = store.profiles;
    if (profiles.isEmpty) {
      return Text('No profiles on this gateway.',
          style:
              theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant));
    }
    return Column(
      children: profiles.map((p) {
        return ListTile(
          minTileHeight: 48,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(
            p.isDefault ? Icons.star : Icons.person,
            size: 18,
            color: p.isDefault ? cs.tertiary : cs.onSurfaceVariant,
          ),
          title: Text(p.name, style: theme.textTheme.bodyMedium),
          subtitle: p.description.isNotEmpty
              ? Text(p.description, style: theme.textTheme.bodySmall)
              : null,
        );
      }).toList(),
    );
  }
}

class _ToggleList extends StatefulWidget {
  const _ToggleList({required this.store, required this.onSet});
  final ChatStore store;
  final Future<void> Function(String key, String value) onSet;

  @override
  State<_ToggleList> createState() => _ToggleListState();
}

class _ToggleListState extends State<_ToggleList> {
  ChatStore get store => widget.store;

  /// One `config.get` per toggle key per version. The futures are created
  /// HERE, not in build — the old code put `future: store.configGet(key)`
  /// inside build, so every rebuild of the settings screen (each snackbar,
  /// each model switch, …) re-fired one RPC per toggle.
  final Map<String, Future<String?>> _futures = {};
  int _version = 0;

  Future<String?> _fetch(String key) {
    return _futures.putIfAbsent(key, () => store.configGet(key));
  }

  void _bump() {
    _futures.clear();
    setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      children: ChatStore.configToggles.entries.map((e) {
        final key = e.key;
        final values = e.value;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 110,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(key,
                        style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: cs.onSurfaceVariant)),
                  )),
              Expanded(
                child: FutureBuilder<String?>(
                  // [key, _version] pins the cached future per build cycle.
                  key: ValueKey('$key$_version'),
                  future: _fetch(key),
                  builder: (context, snap) {
                    final current = snap.data ?? '';
                    return Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: values.map((v) {
                        final selected = v == current;
                        return ActionChip(
                          label: Text(v,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: selected
                                    ? cs.onPrimaryContainer
                                    : cs.onSurfaceVariant,
                              )),
                          backgroundColor: selected
                              ? cs.primaryContainer
                              : cs.surfaceContainerHighest,
                          side: BorderSide.none,
                          onPressed: () async {
                            // Fire the set, then re-read: the gateway's
                            // current value is the source of truth, so a
                            // failed set simply shows the value that is
                            // actually in force.
                            await widget.onSet(key, v);
                            if (mounted) _bump();
                          },
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// Reasoning-effort control (issue #14). Reads the live value with
/// `config.get reasoning`, writes through `config.set reasoning` with global
/// scope (persisting `agent.reasoning_effort`, the Desktop parity behavior),
/// then re-reads so a write that did not stick is shown as a failure.
///
/// ChatStore keeps its GatewayClient private, so in production this card
/// opens its own short-lived connection (auto-reconnect off) for the load
/// and the writes, and closes it on dispose. The store refreshes
/// `config.oauthToken` in place, so a fresh connect picks up a rotated
/// token. Tests inject [transport] and skip the socket entirely.
class _ReasoningEffortCard extends StatefulWidget {
  const _ReasoningEffortCard({required this.store, this.transport});
  final ChatStore store;
  final ConfigTransport? transport;

  @override
  State<_ReasoningEffortCard> createState() => _ReasoningEffortCardState();
}

class _ReasoningEffortCardState extends State<_ReasoningEffortCard> {
  ConfigTransport? _transport;
  GatewayClient? _ownedClient;
  ReasoningEffort? _effort;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    final client = _ownedClient;
    _ownedClient = null;
    if (client != null) unawaited(client.dispose());
    super.dispose();
  }

  Future<ConfigTransport> _resolveTransport() async {
    final injected = widget.transport;
    if (injected != null) return injected;
    final client = GatewayClient(widget.store.config, autoReconnect: false);
    try {
      await client.connect();
    } catch (_) {
      await client.dispose();
      rethrow;
    }
    _ownedClient = client;
    return client.request;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final t = await _resolveTransport();
      final effort = await ReasoningEffort.load(t);
      if (!mounted) return;
      setState(() {
        _transport = t;
        _effort = effort;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _select(String level) async {
    final t = _transport;
    final effort = _effort;
    if (t == null || effort == null || _busy) return;
    setState(() => _busy = true);
    try {
      final res = await effort.write(t, level);
      if (!mounted) return;
      if (res.refused) {
        _showSnack(res.refusal!);
      } else {
        // The re-read value is the truth either way; only the message differs.
        setState(() => _effort = ReasoningEffort(res.actual));
        _showSnack(res.applied
            ? 'reasoning = ${res.actual}'
            : 'Gateway kept reasoning at '
                "'${res.actual.isEmpty ? 'unknown' : res.actual}'");
      }
    } catch (e) {
      if (mounted) _showSnack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(message.length > 120
              ? '${message.substring(0, 120)}…'
              : message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
            child: SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (_error != null) {
      return Row(
        children: [
          Expanded(
            child: Text('Could not read the reasoning effort: $_error',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: cs.error)),
          ),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    final effort = _effort;
    if (effort == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: ReasoningEffortSelector(
        effort: effort,
        busy: _busy,
        onSelect: _select,
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.store});
  final ChatStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final b = store.battery;
    final v = store.verification;
    final sub = store.subscription;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                  width: 110,
                  child: Text(label,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w500))),
              Expanded(
                  child: Text(value.isEmpty ? '—' : value,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis)),
            ],
          ),
        );

    final batteryText = b['level'] == null
        ? 'n/a'
        : '${(b['level'] is num ? (b['level'] as num).toInt() : 0)}%'
            '${b['charging'] == true ? ' (charging)' : ''}';
    final vStatus = (v['status'] ?? 'unknown').toString();
    final subSummary = sub['plan'] != null
        ? '${sub['plan']}'
            '${sub['seat_type'] != null ? ' · ${sub['seat_type']}' : ''}'
        : (sub['ok'] == true ? 'active' : 'n/a');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('Battery (host)', batteryText),
        row('Verification', vStatus),
        row('Subscription', subSummary),
        row('Model', store.currentModel),
        if (store.activeList.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8, color: cs.primary),
                const SizedBox(width: 6),
                Text('Live sessions: ${store.activeList.length}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
      ],
    );
  }
}
