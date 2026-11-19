import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'region.dart';
import 'region_files.dart';

/// Where one region stands from the user's point of view.
enum RegionPhase {
  /// The server has it; it can be downloaded.
  available,

  /// Listed in the catalog but not hosted yet (or the server is unreachable).
  unavailable,

  downloading,

  /// Stored on this device (or, on the web, selected for streaming).
  ready,

  failed,
}

@immutable
class RegionState {
  const RegionState(this.phase, {this.received = 0, this.total = 0, this.error});

  final RegionPhase phase;
  final int received;
  final int total;
  final String? error;

  double get progress => total == 0 ? 0 : received / total;
}

/// The catalog of regions, what the server hosts, and what's on this device.
///
/// Region availability comes from the server's `index.json`, which lists the
/// files it actually has with their real sizes. The catalog shipped inside
/// the app supplies names, bounding boxes and size estimates, so the list
/// still renders (marked unavailable) when the server can't be reached.
class RegionStore extends ChangeNotifier {
  RegionStore({RegionFiles? files, http.Client? client})
      : files = files ?? RegionFiles(),
        _client = client ?? http.Client();

  final RegionFiles files;
  final http.Client _client;

  static const _kReady = 'readyRegions';
  static const _kActive = 'activeRegion';

  List<Region> regions = const [];
  final Map<String, int> _hostedBytes = {};
  final Map<String, bool> _hostedPois = {};
  final Map<String, RegionState> _states = {};
  final Map<String, DownloadCancel> _cancels = {};
  Set<String> _ready = {};
  String? _activeId;
  bool loaded = false;
  bool serverReachable = false;

  /// Loads the bundled catalog and local state, then asks the server what it
  /// hosts. Never throws: a dead server just means fewer downloadable regions.
  Future<void> load({AssetBundle? bundle}) async {
    try {
      final raw = await (bundle ?? rootBundle).loadString('assets/regions/catalog.json');
      final json = jsonDecode(raw) as Map<String, Object?>;
      regions = [
        for (final item in json['regions']! as List<Object?>)
          Region.fromJson((item! as Map).cast<String, Object?>()),
      ];
    } catch (error) {
      // A broken catalog must not block start-up: the map, hazards and any
      // already-downloaded region keep working without it.
      debugPrint('Region catalog failed to load: $error');
    }

    final prefs = await SharedPreferences.getInstance();
    _ready = (prefs.getStringList(_kReady) ?? const []).toSet();
    if (files.storesOffline) {
      // Trust the disk over the preference: files may have been cleared.
      for (final id in _ready.toList()) {
        if (!await files.isDownloaded(id)) _ready.remove(id);
      }
    }
    _activeId = prefs.getString(_kActive);
    if (_activeId != null && !_ready.contains(_activeId)) _activeId = null;
    _activeId ??= _ready.isEmpty ? null : _ready.first;

    loaded = true;
    notifyListeners();
    await refreshHosted();
  }

  /// Re-reads the server's `index.json`.
  Future<void> refreshHosted() async {
    try {
      final response = await _client
          .get(Uri.parse('${Config.regionsUrl}/index.json'))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) throw StateError('HTTP ${response.statusCode}');
      final index = (jsonDecode(response.body) as Map<String, Object?>)['regions']! as Map;
      _hostedBytes.clear();
      _hostedPois.clear();
      index.forEach((id, value) {
        final entry = (value as Map).cast<String, Object?>();
        _hostedBytes[id as String] = (entry['pmtilesBytes']! as num).toInt();
        _hostedPois[id] = entry['poisBytes'] != null;
      });
      serverReachable = true;
    } catch (_) {
      serverReachable = false;
    }
    notifyListeners();
  }

  // ---- Queries -------------------------------------------------------------

  Region? byId(String? id) {
    for (final region in regions) {
      if (region.id == id) return region;
    }
    return null;
  }

  List<Region> atLevel(RegionLevel level) => [
        for (final region in regions)
          if (region.level == level) region,
      ];

  /// Regions on this device (or chosen for streaming on the web).
  List<Region> get readyRegions => [
        for (final region in regions)
          if (_ready.contains(region.id)) region,
      ];

  Region? get activeRegion => byId(_activeId);

  bool isHosted(Region region) => region.remoteUrl != null || _hostedBytes.containsKey(region.id);

  /// The real size if the server reported it, else the catalog estimate.
  int sizeOf(Region region) => _hostedBytes[region.id] ?? region.approxBytes;

  /// True when [sizeOf] is an estimate rather than the server's number.
  bool isEstimate(Region region) => !_hostedBytes.containsKey(region.id);

  RegionState stateOf(Region region) {
    final explicit = _states[region.id];
    if (explicit != null) return explicit;
    if (_ready.contains(region.id)) return const RegionState(RegionPhase.ready);
    return RegionState(isHosted(region) ? RegionPhase.available : RegionPhase.unavailable);
  }

  /// A path or URL the map can open for [region].
  Future<String> basemapSource(Region region) async {
    if (files.storesOffline && await files.isDownloaded(region.id)) {
      return files.basemapSource(region.id);
    }
    return region.remoteUrl ?? '${Config.regionsUrl}/${region.id}.pmtiles';
  }

  /// The region's POI pack, from disk or (on the web) from the server.
  Future<String?> poisJson(Region region) async {
    if (files.storesOffline) {
      final local = await files.readPois(region.id);
      if (local != null) return local;
    }
    try {
      final response = await _client
          .get(Uri.parse('${Config.regionsUrl}/${region.id}.pois.json'))
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200 ? utf8.decode(response.bodyBytes) : null;
    } catch (_) {
      return null;
    }
  }

  // ---- Actions -------------------------------------------------------------

  Future<void> download(Region region) async {
    if (stateOf(region).phase == RegionPhase.downloading) return;
    final cancel = _cancels[region.id] = DownloadCancel();
    _states[region.id] = RegionState(RegionPhase.downloading, total: sizeOf(region));
    notifyListeners();
    try {
      await files.download(
        regionId: region.id,
        basemap: Uri.parse(region.remoteUrl ?? '${Config.regionsUrl}/${region.id}.pmtiles'),
        pois: (_hostedPois[region.id] ?? false)
            ? Uri.parse('${Config.regionsUrl}/${region.id}.pois.json')
            : null,
        cancel: cancel,
        onProgress: (received, total) {
          _states[region.id] = RegionState(RegionPhase.downloading, received: received, total: total);
          notifyListeners();
        },
      );
      _states.remove(region.id);
      _ready.add(region.id);
      _activeId ??= region.id; // the first map becomes the active one
      await _persist();
    } on DownloadCancelledException {
      _states.remove(region.id);
    } catch (error) {
      _states[region.id] = RegionState(RegionPhase.failed, error: '$error');
    } finally {
      _cancels.remove(region.id);
      notifyListeners();
    }
  }

  void cancelDownload(Region region) => _cancels[region.id]?.cancel();

  Future<void> remove(Region region) async {
    await files.delete(region.id);
    _ready.remove(region.id);
    _states.remove(region.id);
    if (_activeId == region.id) _activeId = _ready.isEmpty ? null : _ready.first;
    await _persist();
    notifyListeners();
  }

  Future<void> activate(Region region) async {
    if (!_ready.contains(region.id)) return;
    _activeId = region.id;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kReady, _ready.toList());
    if (_activeId == null) {
      await prefs.remove(_kActive);
    } else {
      await prefs.setString(_kActive, _activeId!);
    }
  }
}
