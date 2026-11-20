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

  /// The server doesn't have it yet but can build it on request.
  preparable,

  /// The server is building it; the download follows automatically.
  preparing,

  /// Can't be had right now: see [RegionStore.unavailableReason].
  unavailable,

  downloading,

  /// Stored on this device (or, on the web, selected for streaming).
  ready,

  failed,
}

@immutable
class RegionState {
  const RegionState(this.phase, {this.received = 0, this.total = 0, this.error, this.step});

  final RegionPhase phase;
  final int received;
  final int total;
  final String? error;

  /// While preparing: "queued", "map" or "supplies".
  final String? step;

  double get progress => total == 0 ? 0 : received / total;
}

/// Why a region can't be downloaded right now.
enum UnavailableReason { serverUnreachable, tooBig, notHosted }

/// The catalog of regions, what the server hosts, and what's on this device.
///
/// Region availability comes from the server's `index.json`, which lists the
/// files it actually has with their real sizes, plus how large a region it
/// is willing to build on request. The catalog shipped inside the app
/// supplies names, bounding boxes and measured sizes, so the list still
/// renders (marked unavailable) when the server can't be reached.
///
/// Getting a region the server doesn't host yet is two steps that look like
/// one to the user: ask the server to prepare it (following its progress),
/// then download it as usual. See [download].
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
  /// Side packs the server hosts, per region id.
  final Map<String, Set<SidePack>> _hostedPacks = {};
  final Map<String, RegionState> _states = {};
  final Map<String, DownloadCancel> _cancels = {};

  /// Regions whose server-side preparation this store is following.
  final Set<String> _watching = {};

  /// Largest region the server builds on demand; null when it doesn't.
  int? prepareMaxBytes;

  /// How often to ask the server how a preparation is going.
  @visibleForTesting
  static Duration pollInterval = const Duration(seconds: 1);
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
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final index = body['regions']! as Map;
      _hostedBytes.clear();
      _hostedPois.clear();
      _hostedPacks.clear();
      index.forEach((id, value) {
        final entry = (value as Map).cast<String, Object?>();
        _hostedBytes[id as String] = (entry['pmtilesBytes']! as num).toInt();
        _hostedPois[id] = entry['poisBytes'] != null;
        _hostedPacks[id] = {
          for (final pack in SidePack.values)
            if (entry[pack.indexKey] != null) pack,
        };
      });
      // Older servers send neither key: no on-demand preparation.
      final prepare = (body['prepare'] as Map?)?.cast<String, Object?>();
      prepareMaxBytes = prepare?['enabled'] == true ? (prepare!['maxBytes'] as num?)?.toInt() : null;
      serverReachable = true;
      // Pick up work started before the app last closed, so its progress
      // shows instead of a plain download button.
      final jobs = (body['jobs'] as Map?)?.cast<String, Object?>() ?? const {};
      jobs.forEach((id, value) {
        final state = (value as Map)['state'];
        final region = byId(id);
        if (region != null && (state == 'queued' || state == 'running') && !_watching.contains(id)) {
          download(region);
        }
      });
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
    if (isHosted(region)) return const RegionState(RegionPhase.available);
    return RegionState(unavailableReason(region) == null ? RegionPhase.preparable : RegionPhase.unavailable);
  }

  /// Why [region] can be neither downloaded nor prepared, or null if it can.
  UnavailableReason? unavailableReason(Region region) {
    if (isHosted(region)) return null;
    if (!serverReachable) return UnavailableReason.serverUnreachable;
    final max = prepareMaxBytes;
    if (max == null) return UnavailableReason.notHosted;
    if (region.approxBytes > max) return UnavailableReason.tooBig;
    return null;
  }

  /// Regions stored on, or on their way to, this device: the "On this
  /// device" list, with the active map first.
  List<Region> get deviceRegions {
    final list = [
      for (final region in regions)
        if (_ready.contains(region.id) || _states.containsKey(region.id)) region,
    ];
    // Stable sort: only the active map moves; the rest keep catalog order.
    final active = list.where((r) => r.id == _activeId).toList();
    return [...active, ...list.where((r) => r.id != _activeId)];
  }

  /// Regions whose name, or whose parent's name, contains [query]
  /// ("ontario" also finds Ottawa and Sarnia).
  List<Region> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    bool matches(Region? r) => r != null && r.name.toLowerCase().contains(needle);
    return [
      for (final region in regions)
        if (matches(region) || matches(byId(region.parentId))) region,
    ];
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

  /// One of the region's side packs, from disk or (on the web) from the
  /// server. Null when the region has none.
  Future<Uint8List?> sidePack(Region region, SidePack pack) async {
    if (files.storesOffline) {
      final local = await files.readPack(region.id, pack);
      if (local != null) return local;
    }
    try {
      final response = await _client
          .get(Uri.parse('${Config.regionsUrl}/${pack.fileName(region.id)}'))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      // Keep it: next time it works with no network.
      if (files.storesOffline && _ready.contains(region.id)) {
        await files.savePack(region.id, pack, response.bodyBytes);
      }
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  // ---- Actions -------------------------------------------------------------

  /// Downloads [region], first asking the server to prepare it when it
  /// doesn't host it yet.
  Future<void> download(Region region) async {
    final phase = stateOf(region).phase;
    if (phase == RegionPhase.downloading || phase == RegionPhase.preparing) return;
    if (!isHosted(region) || _missingSupplies(region)) {
      final prepared = await _prepare(region);
      if (!prepared) return;
    }
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
        packs: {
          for (final pack in _hostedPacks[region.id] ?? const <SidePack>{})
            pack: Uri.parse('${Config.regionsUrl}/${pack.fileName(region.id)}'),
        },
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

  /// A hosted region missing a side pack the server can build for it: a
  /// city or province without its supply list, or a city without its
  /// routing or population pack (Overpass is a shared service and
  /// sometimes overloaded).
  /// Asking the server to prepare it again builds just what is missing, so
  /// the download isn't a map with no supplies or directions.
  bool _missingSupplies(Region region) {
    if (prepareMaxBytes == null || region.remoteUrl != null || !_hostedBytes.containsKey(region.id)) return false;
    final city = region.level == RegionLevel.city;
    final supplies = city || region.level == RegionLevel.province;
    final packs = _hostedPacks[region.id] ?? const <SidePack>{};
    return (supplies && !(_hostedPois[region.id] ?? false)) ||
        (city && !packs.contains(SidePack.routing)) ||
        (supplies && !packs.contains(SidePack.population));
  }

  /// Asks the server to build [region] and follows its progress. Returns
  /// true once the files are hosted.
  ///
  /// The server-side job can't be cancelled from here (another device may
  /// want the same region), so cancelling only stops waiting; the region
  /// then shows as available once the server finishes.
  Future<bool> _prepare(Region region) async {
    final cancel = _cancels[region.id] = DownloadCancel();
    _watching.add(region.id);
    _states[region.id] = RegionState(RegionPhase.preparing, total: region.approxBytes, step: 'queued');
    notifyListeners();
    final url = Uri.parse('${Config.regionsUrl}/${region.id}/prepare');
    try {
      var response = await _client.post(url).timeout(const Duration(seconds: 15));
      while (true) {
        final job = (jsonDecode(response.body) as Map).cast<String, Object?>();
        if (response.statusCode >= 400) {
          throw StateError(job['error'] as String? ?? 'HTTP ${response.statusCode}');
        }
        switch (job['state']) {
          case 'done':
            _states.remove(region.id);
            await refreshHosted();
            return isHosted(region);
          case 'failed':
            throw StateError(job['error'] as String? ?? 'Preparation failed');
        }
        _states[region.id] = RegionState(
          RegionPhase.preparing,
          received: (job['bytesDone'] as num? ?? 0).toInt(),
          total: (job['bytesTotal'] as num? ?? region.approxBytes).toInt(),
          step: job['state'] == 'queued' ? 'queued' : job['step'] as String?,
        );
        notifyListeners();
        await Future<void>.delayed(pollInterval);
        if (cancel.isCancelled) {
          _states.remove(region.id);
          return false;
        }
        response = await _client.get(url).timeout(const Duration(seconds: 15));
      }
    } catch (error) {
      _states[region.id] = RegionState(RegionPhase.failed, error: '$error');
      return false;
    } finally {
      _watching.remove(region.id);
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
