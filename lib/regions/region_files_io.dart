import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'region_files.dart';

/// Phones and desktops: regions live under the app-support directory as
/// `<id>.pmtiles`, `<id>.pois.json` and one file per [SidePack].
///
/// Files download to a `.part` name and are renamed only when complete, so a
/// half-finished download can never be mistaken for a usable map. If the app
/// is killed mid-download, the next attempt sends an HTTP `Range` header and
/// continues from the bytes already on disk, which matters for multi-gigabyte
/// country and continent files on flaky connections.
class PlatformRegionFiles implements RegionFiles {
  PlatformRegionFiles({http.Client Function()? newClient}) : _newClient = newClient ?? http.Client.new;

  final http.Client Function() _newClient;
  Directory? _dir;

  Future<Directory> _regionsDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}regions');
    await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> _file(String name) async =>
      File('${(await _regionsDir()).path}${Platform.pathSeparator}$name');

  @override
  bool get storesOffline => true;

  @override
  Future<void> download({
    required String regionId,
    required Uri basemap,
    Uri? pois,
    Map<SidePack, Uri> packs = const {},
    required void Function(int received, int total) onProgress,
    required DownloadCancel cancel,
    bool restart = false,
  }) async {
    // Every file lands as "<name>.part" first. Only when all of them have
    // arrived are they renamed into place, so an update of the map on
    // screen swaps old for new in one step, and a cancelled or failed
    // update leaves the old map whole.
    final staged = <File>[];

    // The side packs are small, so fetch them first; then the basemap
    // reports progress for the part that actually takes time.
    final client = _newClient();
    cancel.onCancel(client.close);
    try {
      for (final (url, name) in [
        (pois, '$regionId.pois.json'),
        for (final MapEntry(key: pack, value: url) in packs.entries) (url, pack.fileName(regionId)),
      ]) {
        if (url == null) continue;
        if (cancel.isCancelled) throw const DownloadCancelledException();
        final response = await client.get(url);
        if (response.statusCode == 200) {
          final part = File('${(await _file(name)).path}.part');
          await part.writeAsBytes(response.bodyBytes, flush: true);
          staged.add(part);
        }
      }
    } on http.ClientException {
      if (cancel.isCancelled) throw const DownloadCancelledException();
      rethrow;
    } finally {
      client.close();
    }

    final basemapPart = File('${(await _file('$regionId.pmtiles')).path}.part');
    if (restart && await basemapPart.exists()) await basemapPart.delete();
    await _resumableDownload(basemap, basemapPart, onProgress, cancel);
    staged.add(basemapPart);

    for (final part in staged) {
      await replaceFile(part, File(part.path.substring(0, part.path.length - '.part'.length)));
    }
  }

  /// Downloads [url] into [part], continuing from whatever is already there.
  Future<void> _resumableDownload(
    Uri url,
    File part,
    void Function(int received, int total) onProgress,
    DownloadCancel cancel,
  ) async {
    var received = await part.exists() ? await part.length() : 0;

    final client = _newClient();
    cancel.onCancel(client.close);
    try {
      final request = http.Request('GET', url);
      if (received > 0) request.headers['Range'] = 'bytes=$received-';
      final response = await client.send(request);

      if (response.statusCode == 200) {
        received = 0; // server ignored the Range header: start over
      } else if (response.statusCode != 206) {
        throw HttpException('Download failed (${response.statusCode})', uri: url);
      }
      final total = received + (response.contentLength ?? 0);

      final sink = part.openWrite(mode: received > 0 ? FileMode.append : FileMode.write);
      try {
        var lastReport = DateTime.now();
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          // Throttle UI updates to ~10/s; a fast link delivers thousands of chunks.
          final now = DateTime.now();
          if (now.difference(lastReport).inMilliseconds > 100) {
            onProgress(received, total);
            lastReport = now;
          }
        }
      } finally {
        await sink.close();
      }
      onProgress(received, total);
    } on http.ClientException {
      if (cancel.isCancelled) throw const DownloadCancelledException();
      rethrow;
    } finally {
      client.close();
    }
  }

  @override
  Future<bool> isDownloaded(String regionId) async =>
      (await _file('$regionId.pmtiles')).exists();

  @override
  Future<String> basemapSource(String regionId) async => (await _file('$regionId.pmtiles')).path;

  @override
  Future<String?> readPois(String regionId) async {
    final file = await _file('$regionId.pois.json');
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<Uint8List?> readPack(String regionId, SidePack pack) async {
    final file = await _file(pack.fileName(regionId));
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<void> savePack(String regionId, SidePack pack, Uint8List bytes) async {
    final file = await _file(pack.fileName(regionId));
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await replaceFile(part, file);
  }

  @override
  Future<void> delete(String regionId) async {
    for (final name in [
      '$regionId.pmtiles',
      '$regionId.pois.json',
      for (final pack in SidePack.values) pack.fileName(regionId),
    ].expand((name) => [name, '$name.part'])) {
      final file = await _file(name);
      if (await file.exists()) await file.delete();
    }
  }
}

/// Renames [part] over [target].
///
/// On Windows a file can't be replaced while something is reading it, and
/// the map reads its archive a tile at a time (opening and closing the
/// file for each read). So a swap that collides with a read is retried a
/// few times; the reads are short, and the next one finds the new file.
Future<void> replaceFile(File part, File target) async {
  for (var attempt = 1;; attempt++) {
    try {
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      return;
    } on FileSystemException {
      if (attempt >= 10) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
    }
  }
}
