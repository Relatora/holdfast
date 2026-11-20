import 'package:flutter_map/flutter_map.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import '../theme/app_theme_mode.dart';
import 'basemap_style.dart';
import 'resilient_tile_provider.dart';

/// The vector basemap for one PMTiles source (a local file or a URL),
/// styled to match the app theme.
///
/// Opening an archive reads its header and directory, so it's done once per
/// source and cached; switching themes only swaps the style. Reads go through
/// [ResilientTileProvider], which recovers if the archive's cache is poisoned
/// by a failed read.
class BasemapLayer extends StatefulWidget {
  const BasemapLayer({super.key, required this.source, required this.mode});

  /// The closest the map can zoom. Shared with `MapOptions.maxZoom` so the
  /// basemap is drawn at every zoom the camera can reach (see [build]).
  static const maxMapZoom = 19.0;

  /// Path or URL accepted by `PmTilesArchive.from`.
  final String source;

  /// Already resolved (never [AppThemeMode.system]).
  final AppThemeMode mode;

  @override
  State<BasemapLayer> createState() => _BasemapLayerState();
}

class _BasemapLayerState extends State<BasemapLayer> {
  late Future<ResilientTileProvider> _provider = _open(widget.source);

  Future<ResilientTileProvider> _open(String source) async {
    final provider = await ResilientTileProvider.open(() => PmTilesTileArchive.open(source));
    _kickUntilFirstRequest(provider);
    return provider;
  }

  /// Works around a start-up race in the tile layer.
  ///
  /// The vector tile layer's own initial load never reaches the provider;
  /// only camera events after the layer has subscribed to them do. When
  /// nothing moves the camera after that moment (a cold start with the
  /// region already chosen), the map stays blank until someone pans. One
  /// nudge right after the layer appears usually works, but it can land
  /// before the layer subscribes. So: pan one pixel and back every 300 ms
  /// until the provider has received its first tile request, for up to 30
  /// seconds (a debug build cold-starting on an emulator was still not
  /// subscribed after the 6 s this used to allow). Each nudge is invisible,
  /// and the loop stops as soon as tiles flow.
  void _kickUntilFirstRequest(ResilientTileProvider provider, {int attempt = 0}) {
    Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 0 : 300), () {
      if (!mounted || provider.requestCount > 0 || attempt >= 100) return;
      final controller = MapController.maybeOf(context);
      final camera = MapCamera.maybeOf(context);
      if (controller != null && camera != null) {
        final center = camera.center;
        final shifted = camera.unprojectAtZoom(camera.projectAtZoom(center) + const Offset(1, 0));
        controller.move(shifted, camera.zoom);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) controller.move(center, camera.zoom);
        });
      }
      _kickUntilFirstRequest(provider, attempt: attempt + 1);
    });
  }

  @override
  void didUpdateWidget(BasemapLayer old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      _provider = _open(widget.source);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ResilientTileProvider>(
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
          // The layer renders in raster mode (the package default), where
          // this is the highest zoom the layer is *displayed* at, not the
          // archive's top zoom. Passing the archive's 14 made the basemap
          // vanish past street level (#45). Past z14 the package over-zooms:
          // raster tiles are still drawn from the z14 vectors, so streets
          // stay sharp all the way in.
          maximumZoom: BasemapLayer.maxMapZoom,
          // Rendered tiles are cheap to rebuild from a local archive, and a
          // style change must never show stale colours from the cache.
          fileCacheTtl: Duration.zero,
        );
      },
    );
  }
}
