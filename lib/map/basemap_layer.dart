import 'package:material_ui/material_ui.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';

import '../theme/app_theme_mode.dart';
import 'basemap_style.dart';

/// The vector basemap for one PMTiles source (a local file or a URL),
/// styled to match the app theme.
///
/// Opening an archive reads its header and directory, so it's done once per
/// source and cached; switching themes only swaps the style.
class BasemapLayer extends StatefulWidget {
  const BasemapLayer({super.key, required this.source, required this.mode});

  /// Path or URL accepted by `PmTilesArchive.from`.
  final String source;

  /// Already resolved (never [AppThemeMode.system]).
  final AppThemeMode mode;

  @override
  State<BasemapLayer> createState() => _BasemapLayerState();
}

class _BasemapLayerState extends State<BasemapLayer> {
  late Future<PmTilesVectorTileProvider> _provider = PmTilesVectorTileProvider.fromSource(widget.source);

  @override
  void didUpdateWidget(BasemapLayer old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      _provider = PmTilesVectorTileProvider.fromSource(widget.source);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PmTilesVectorTileProvider>(
      future: _provider,
      builder: (context, snapshot) {
        final provider = snapshot.data;
        if (provider == null) return const SizedBox.shrink();
        return VectorTileLayer(
          // The layer caches rendered tiles, so a new source *or* a new style
          // needs a new key; otherwise old-coloured tiles linger after a
          // theme switch (night vision would keep a grey map).
          key: ValueKey('${widget.source}|${widget.mode.name}'),
          theme: basemapStyleFor(widget.mode),
          tileProviders: TileProviders({'protomaps': provider}),
          // Tiles past the archive's max zoom are scaled up from the last level.
          maximumZoom: provider.maximumZoom.toDouble(),
          // Rendered tiles are cheap to rebuild from a local archive, and a
          // style change must never show stale colours from the cache.
          fileCacheTtl: Duration.zero,
        );
      },
    );
  }
}
