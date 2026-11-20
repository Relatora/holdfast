import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../theme/motion.dart';
import 'region.dart';
import 'region_store.dart';

/// "Maps": what's on this device, then every region by size (city → whole
/// world), with a search across all of them. Download, switch between and
/// delete maps from here.
class RegionsScreen extends StatefulWidget {
  const RegionsScreen({super.key});

  @override
  State<RegionsScreen> createState() => _RegionsScreenState();
}

class _RegionsScreenState extends State<RegionsScreen> {
  final _search = TextEditingController();

  /// Opens on "On this device" when there is something there: people
  /// coming here with maps usually want to switch or tidy up. Without any,
  /// it opens on Cities, the quickest first download.
  late final int _initialTab = context.read<RegionStore>().deviceRegions.isEmpty ? 1 : 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RegionStore>();
    final searching = _search.text.trim().isNotEmpty;
    return DefaultTabController(
      length: RegionLevel.values.length + 1,
      initialIndex: _initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Maps'),
          actions: [
            IconButton(
              tooltip: 'Check the server again',
              onPressed: store.refreshHosted,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          // While searching, results span every level, so the tabs step aside.
          bottom: searching
              ? null
              : TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: 'On this device (${store.deviceRegions.length})'),
                    for (final level in RegionLevel.values) Tab(text: level.label),
                  ],
                ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SearchBar(
                controller: _search,
                hintText: 'Search cities, provinces, states, countries…',
                leading: const Icon(Icons.search_rounded),
                elevation: const WidgetStatePropertyAll(0),
                onChanged: (_) => setState(() {}),
                trailing: [
                  if (searching)
                    IconButton(
                      tooltip: 'Clear search',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
            ),
            const _StatusBanner(),
            Expanded(
              child: searching
                  ? _SearchResults(query: _search.text)
                  : TabBarView(
                      children: [
                        const _DeviceList(),
                        for (final level in RegionLevel.values) _RegionList(level: level),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RegionStore>();
    final scheme = Theme.of(context).colorScheme;
    final (icon, text) = !store.serverReachable
        ? (Icons.cloud_off_rounded, "Can't reach the map server. Maps already on this device still work.")
        : !store.files.storesOffline
            ? (Icons.public_rounded, 'Web preview: maps stream from the server. Install the app to keep them offline.')
            : store.prepareMaxBytes != null
                ? (
                    Icons.cloud_sync_rounded,
                    'Maps the server hasn\'t built yet are prepared when you ask for them '
                        '(up to ${formatBytes(store.prepareMaxBytes!)}), then downloaded.',
                  )
                : (Icons.offline_pin_rounded, '${store.readyRegions.length} map(s) stored on this device for offline use.');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer))),
        ],
      ),
    );
  }
}

/// Maps stored on this device, plus any on their way.
class _DeviceList extends StatelessWidget {
  const _DeviceList();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RegionStore>();
    final regions = store.deviceRegions;
    final theme = Theme.of(context);
    if (regions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_for_offline_outlined, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('No maps on this device yet', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text(
                'Pick one from Cities to start. A city takes a minute; a province can take a while.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final stored = store.readyRegions.fold<int>(0, (sum, r) => sum + store.sizeOf(r));
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: Text(
            store.files.storesOffline
                ? '${store.readyRegions.length} map(s), ${formatBytes(stored)} on this device. '
                    'They work with no network at all.'
                : 'Maps chosen for streaming in this browser.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        for (final region in regions) _RegionTile(region: region, showLevel: true),
      ],
    );
  }
}

/// Every region matching the search, across all levels.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RegionStore>();
    final results = store.search(query);
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text('No map matches “${query.trim()}”.', textAlign: TextAlign.center),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [for (final region in results) _RegionTile(region: region, showLevel: true)],
    );
  }
}

class _RegionList extends StatelessWidget {
  const _RegionList({required this.level});

  final RegionLevel level;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RegionStore>();
    final regions = store.atLevel(level);
    final animate = Motion.enabled(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: Text(level.hint, style: Theme.of(context).textTheme.bodyMedium),
        ),
        for (final (i, region) in regions.indexed) ...[
          // Long levels (65 provinces and states) get a heading per country.
          // The catalog lists regions grouped by parent, so a heading goes
          // wherever the parent changes.
          if (level == RegionLevel.province && (i == 0 || regions[i - 1].parentId != region.parentId))
            _GroupHeading(store.byId(region.parentId)?.name ?? 'Other'),
          // Only the first screenful animates in; staggering 65 tiles would
          // keep the last ones hidden for seconds.
          animate && i < 12
              ? _RegionTile(region: region)
                  .animate(delay: (40 * i).ms)
                  .fadeIn(duration: 260.ms)
                  .slideX(begin: 0.06, end: 0, curve: Curves.easeOutCubic)
              : _RegionTile(region: region),
        ],
      ],
    );
  }
}


class _GroupHeading extends StatelessWidget {
  const _GroupHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

class _RegionTile extends StatelessWidget {
  const _RegionTile({required this.region, this.showLevel = false});

  final Region region;

  /// In mixed lists (search results, On this device) say what kind of
  /// region it is, since the tab no longer does.
  final bool showLevel;

  /// Anything this big gets an "are you sure" with the size spelled out.
  static const _bigDownload = 5000000000; // 5 GB

  Future<void> _startDownload(BuildContext context, RegionStore store) async {
    final size = store.sizeOf(region);
    if (size >= _bigDownload && store.files.storesOffline) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.sd_storage_rounded),
          title: Text('Download ${formatBytes(size)}?'),
          content: Text(
            '${region.name} is a large map. Use Wi-Fi, keep the device charging, '
            'and make sure there is at least ${formatBytes((size * 1.1).round())} free. '
            '${store.isHosted(region) ? '' : 'The server prepares it first, which can take a while. '}'
            'If the download stops, it continues from where it left off.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await store.download(region);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RegionStore>();
    final state = store.stateOf(region);
    final scheme = Theme.of(context).colorScheme;
    final isActive = store.activeRegion?.id == region.id;
    final parent = store.byId(region.parentId);
    final size = '${store.isEstimate(region) ? '≈ ' : ''}${formatBytes(store.sizeOf(region))}';
    final where = [if (showLevel) region.level.singular, ?parent?.name].join(' in ');

    final subtitle = switch (state.phase) {
      RegionPhase.downloading =>
        '${formatBytes(state.received)} of ${formatBytes(state.total)}',
      RegionPhase.preparing => switch (state.step) {
          'queued' => 'Waiting for the server to finish another map…',
          'supplies' => 'Server is building the supply list…',
          _ => 'Server is preparing it: ${formatBytes(state.received)} of ${formatBytes(state.total)}',
        },
      RegionPhase.failed => '${state.error ?? 'Download failed'}. Tap to retry.',
      RegionPhase.unavailable => switch (store.unavailableReason(region)) {
          UnavailableReason.tooBig => '$size · too big for this server to prepare',
          UnavailableReason.serverUnreachable => '$size · server unreachable',
          _ => '$size · not on this server',
        },
      RegionPhase.ready => isActive ? 'Showing on the map' : '$size · ready',
      RegionPhase.available || RegionPhase.preparable => [
          if (where.isNotEmpty) where,
          size,
          if (state.phase == RegionPhase.preparable) 'prepared on request',
        ].join(' · '),
    };

    final Widget trailing = switch (state.phase) {
      RegionPhase.downloading || RegionPhase.preparing => _ProgressRing(
          progress: state.progress,
          onCancel: () => store.cancelDownload(region),
        ),
      RegionPhase.ready => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isActive)
              TextButton(onPressed: () => store.activate(region), child: const Text('Show')),
            IconButton(
              tooltip: 'Delete from this device',
              onPressed: () => store.remove(region),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      RegionPhase.unavailable => Icon(Icons.cloud_off_rounded, color: scheme.outline),
      RegionPhase.available || RegionPhase.preparable || RegionPhase.failed => IconButton.filledTonal(
          tooltip: 'Download',
          onPressed: () => _startDownload(context, store),
          icon: Icon(state.phase == RegionPhase.failed ? Icons.refresh_rounded : Icons.download_rounded),
        ),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      color: isActive ? scheme.primaryContainer.withValues(alpha: 0.6) : null,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        leading: CircleAvatar(
          backgroundColor: scheme.primary.withValues(alpha: 0.15),
          foregroundColor: scheme.primary,
          child: Icon(switch (region.level) {
            RegionLevel.city => Icons.location_city_rounded,
            RegionLevel.province => Icons.terrain_rounded,
            RegionLevel.country => Icons.flag_rounded,
            RegionLevel.continent => Icons.public_rounded,
            RegionLevel.world => Icons.language_rounded,
          }),
        ),
        title: Text(region.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: trailing,
        onTap: state.phase == RegionPhase.failed ? () => _startDownload(context, store) : null,
      ),
    );
  }
}

/// Circular progress with the percentage inside; tap to cancel.
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({required this.progress, required this.onCancel});

  final double progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Cancel download',
      child: InkResponse(
        onTap: onCancel,
        radius: 28,
        child: SizedBox(
          width: 48,
          height: 48,
          // Tweening the value makes coarse progress updates glide smoothly.
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: progress),
            duration: const Duration(milliseconds: 250),
            builder: (context, value, _) => Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(value: value == 0 ? null : value, strokeWidth: 4),
                Text('${(value * 100).round()}%', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
