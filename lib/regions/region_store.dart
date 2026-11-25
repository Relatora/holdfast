import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../net/network_gate.dart';
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

  /// Stored, and a newer build is downloading beside it. The map stays
  /// usable throughout; the new files replace the old ones at the end.
  updating,

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
enum UnavailableReason {
  /// The user turned on offline mode.
  offlineMode,
  serverUnreachable,
  tooBig,
  notHosted,
}

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
///
/// Downloaded maps age. The server rebuilds hosted regions from fresh
/// OpenStreetMap data and reports each one's `builtAt`; the store remembers
/// which build every map on this device came from and offers an update when
/// the server's is newer ([updateAvailable], [update]).
class RegionStore extends ChangeNotifier {
  RegionStore({RegionFiles? files, http.Client? client, this.network})
      : files = files ?? RegionFiles(),
        _client = client ?? http.Client() {
    network?.addListener(_onNetworkChanged);
  }

  final RegionFiles files;
  final http.Client _client;

  /// Offline mode: while it is on, nothing is downloaded, prepared or
  /// updated, and the server isn't asked what it hosts. Maps already on the
  /// device are unaffected.
  final NetworkGate? network;

  bool get offlineMode => network?.online == false;

  /// Back online: find out what changed while the app was offline.
  void _onNetworkChanged() {
    if (offlineMode) {
      for (final cancel in _cancels.values) {
        cancel.cancel();
      }
      notifyListeners();
    } else {
      refreshHosted();
    }
  }

  @override
  void dispose() {
    network?.removeListener(_onNetworkChanged);
    super.dispose();
  }

  static const _kReady = 'readyRegions';
  static const _kActive = 'activeRegion';

  /// The server build each downloaded map came from: {id: ISO time}.
  static const _kBuiltAt = 'regionBuiltAt';

  /// The server build a partial download belongs to: {id: ISO time}.
  static const _kPartOf = 'regionPartBuiltAt';

  List<Region> regions = const [];
  final Map<String, int> _hostedBytes = {};
  final Map<String, bool> _hostedPois = {};
  /// Side packs the server hosts, per region id.
  final Map<String, Set<SidePack>> _hostedPacks = {};

  /// When the server last built each region it hosts.
  final Map<String, DateTime> _hostedBuiltAt = {};

  /// Which server build each map on this device is.
  Map<String, DateTime> _builtAt = {};

  /// Which server build each partial download belongs to.
  Map<String, DateTime> _partOf = {};

  /// Counts the updates applied to each region in this session. Anything
  /// that caches a region's data keys it by [dataKey], which includes this,
  /// so an update makes the caches load the new files.
  final Map<String, int> _revisions = {};

  /// Why the last update of a region failed. The old map is still there.
  final Map<String, String> _updateErrors = {};
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
    _builtAt = _readTimes(prefs, _kBuiltAt);
    _partOf = _readTimes(prefs, _kPartOf);
    _activeId = prefs.getString(_kActive);
    if (_activeId != null && !_ready.contains(_activeId)) _activeId = null;
    _activeId ??= _ready.isEmpty ? null : _ready.first;

    loaded = true;
    notifyListeners();
    await refreshHosted();
  }

  /// Re-reads the server's `index.json`.
  Future<void> refreshHosted() async {
    if (offlineMode) {
      notifyListeners();
      return;
    }
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
      _hostedBuiltAt.clear();
      index.forEach((id, value) {
        final entry = (value as Map).cast<String, Object?>();
        _hostedBytes[id as String] = (entry['pmtilesBytes']! as num).toInt();
        // Servers before 0.4 don't send it: no updates are offered.
        if (DateTime.tryParse(entry['builtAt'] as String? ?? '') case final built?) {
          _hostedBuiltAt[id] = built;
        }
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
      // Maps downloaded before the app tracked builds have no record. Take
      // them to be the build the server has now: the alternative, offering
      // every old map as an update at once, would ask for gigabytes on the
      // strength of a guess. The next real rebuild is then offered as usual.
      var adopted = false;
      for (final id in _ready) {
        if (!_builtAt.containsKey(id) && _hostedBuiltAt[id] != null) {
          _builtAt[id] = _hostedBuiltAt[id]!;
          adopted = true;
        }
      }
      if (adopted) await _persist();
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

  /// True when the server has a newer build of a map stored on this device.
  /// Never on the web, which streams the server's current files anyway.
  bool updateAvailable(Region region) {
    if (offlineMode || !files.storesOffline || !_ready.contains(region.id)) return false;
    final hosted = _hostedBuiltAt[region.id];
    final local = _builtAt[region.id];
    return hosted != null && local != null && hosted.isAfter(local);
  }

  /// Maps on this device with an update waiting, in [deviceRegions] order.
  List<Region> get updatable => [
        for (final region in deviceRegions)
          if (updateAvailable(region) && stateOf(region).phase == RegionPhase.ready) region,
      ];

  /// When the copy of [region] on this device was built by the server, if
  /// known.
  DateTime? builtAt(Region region) => _builtAt[region.id];

  /// Why the last update of [region] failed, if it did.
  String? updateError(Region region) => _updateErrors[region.id];

  /// Changes whenever [region]'s files on this device are replaced. Use it
  /// (not the id) as the key for anything decoded from them.
  String dataKey(Region region) => '${region.id}#${_revisions[region.id] ?? 0}';

  RegionState stateOf(Region region) {
    final explicit = _states[region.id];
    if (explicit != null) return explicit;
    if (_ready.contains(region.id)) return const RegionState(RegionPhase.ready);
    if (offlineMode) return const RegionState(RegionPhase.unavailable);
    if (isHosted(region)) return const RegionState(RegionPhase.available);
    return RegionState(unavailableReason(region) == null ? RegionPhase.preparable : RegionPhase.unavailable);
  }

  /// Why [region] can be neither downloaded nor prepared, or null if it can.
  UnavailableReason? unavailableReason(Region region) {
    if (offlineMode) return UnavailableReason.offlineMode;
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
    if (phase case RegionPhase.downloading || RegionPhase.preparing || RegionPhase.updating) return;
    if (offlineMode) return;
    // Downloading a map that is already here is an update: it keeps working
    // (and showing as ready) while the new build arrives beside it.
    final updating = _ready.contains(region.id);
    if (!updating && (!isHosted(region) || _missingSupplies(region))) {
      final prepared = await _prepare(region);
      if (!prepared) return;
    }
    final downloadingPhase = updating ? RegionPhase.updating : RegionPhase.downloading;
    _updateErrors.remove(region.id);

    // A partial download of an older build can't be continued: its bytes
    // and the new build's would make one corrupt file.
    final build = _hostedBuiltAt[region.id];
    final restart = build != null && _partOf[region.id] != null && _partOf[region.id] != build;
    if (build != null) {
      _partOf[region.id] = build;
      await _persist();
    }

    final cancel = _cancels[region.id] = DownloadCancel();
    _states[region.id] = RegionState(downloadingPhase, total: sizeOf(region));
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
        restart: restart,
        onProgress: (received, total) {
          _states[region.id] = RegionState(downloadingPhase, received: received, total: total);
          notifyListeners();
        },
      );
      _states.remove(region.id);
      _ready.add(region.id);
      _activeId ??= region.id; // the first map becomes the active one
      _partOf.remove(region.id);
      if (build != null) _builtAt[region.id] = build;
      if (updating) _revisions[region.id] = (_revisions[region.id] ?? 0) + 1;
      await _persist();
    } on DownloadCancelledException {
      _states.remove(region.id);
    } catch (error) {
      if (updating) {
        // The old map is untouched: keep it usable and say why the update
        // didn't happen.
        _states.remove(region.id);
        _updateErrors[region.id] = '$error';
      } else {
        _states[region.id] = RegionState(RegionPhase.failed, error: '$error');
      }
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

  /// Replaces [region]'s files with the server's newer build.
  Future<void> update(Region region) => download(region);

  /// Updates every map in [updatable], one after another: they share one
  /// connection, so running them side by side would only slow each down.
  Future<void> updateAll() async {
    for (final region in updatable) {
      await update(region);
    }
  }

  void cancelDownload(Region region) => _cancels[region.id]?.cancel();

  Future<void> remove(Region region) async {
    await files.delete(region.id);
    _ready.remove(region.id);
    _states.remove(region.id);
    _builtAt.remove(region.id);
    _partOf.remove(region.id);
    _updateErrors.remove(region.id);
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

  static Map<String, DateTime> _readTimes(SharedPreferences prefs, String key) {
    try {
      final raw = jsonDecode(prefs.getString(key) ?? '{}') as Map<String, Object?>;
      return {
        for (final MapEntry(:key, :value) in raw.entries) key: ?DateTime.tryParse(value as String? ?? ''),
      };
    } on FormatException {
      return {};
    }
  }

  static String _writeTimes(Map<String, DateTime> times) =>
      jsonEncode({for (final MapEntry(:key, :value) in times.entries) key: value.toUtc().toIso8601String()});

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kReady, _ready.toList());
    await prefs.setString(_kBuiltAt, _writeTimes(_builtAt));
    await prefs.setString(_kPartOf, _writeTimes(_partOf));
    if (_activeId == null) {
      await prefs.remove(_kActive);
    } else {
      await prefs.setString(_kActive, _activeId!);
    }
  }
}
