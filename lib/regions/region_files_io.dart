import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'region_files.dart';

/// Phones and desktops: regions live under the app-support directory as
/// `<id>.pmtiles` and `<id>.pois.json`.
///
/// Files download to a `.part` name and are renamed only when complete, so a
/// half-finished download can never be mistaken for a usable map. If the app
/// is killed mid-download, the next attempt sends an HTTP `Range` header and
/// continues from the bytes already on disk, which matters for multi-gigabyte
/// country and continent files on flaky connections.
class PlatformRegionFiles implements RegionFiles {
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
    required void Function(int received, int total) onProgress,
    required DownloadCancel cancel,
  }) async {
    // The POI pack is small, so fetch it first; then the basemap reports
    // progress for the part that actually takes time.
    if (pois != null) {
      final response = await http.get(pois);
      if (response.statusCode == 200) {
        await (await _file('$regionId.pois.json')).writeAsBytes(response.bodyBytes);
      }
    }
    await _resumableDownload(
      basemap,
      await _file('$regionId.pmtiles'),
      onProgress,
      cancel,
    );
  }

  Future<void> _resumableDownload(
    Uri url,
    File target,
    void Function(int received, int total) onProgress,
    DownloadCancel cancel,
  ) async {
    final part = File('${target.path}.part');
    var received = await part.exists() ? await part.length() : 0;

    final client = http.Client();
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
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
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
  Future<void> delete(String regionId) async {
    for (final name in ['$regionId.pmtiles', '$regionId.pmtiles.part', '$regionId.pois.json']) {
      final file = await _file(name);
      if (await file.exists()) await file.delete();
    }
  }
}
