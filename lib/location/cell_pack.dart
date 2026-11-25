/// Where a region's cell towers are, decoded from the `<id>.cells.bin` pack
/// written by `tool/build_cells.py` (OpenCelliD, CC BY-SA 4.0).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

class CellPackFormatException implements Exception {
  const CellPackFormatException(this.message);
  final String message;
  @override
  String toString() => 'CellPackFormatException: $message';
}

/// The radio generation of a cell. Identities from different generations
/// can collide (a GSM and an LTE cell may share numbers), so it is part of
/// the key.
enum CellRadio { gsm, umts, lte, nr }

/// A cell's network identity: country, network, area (LAC or TAC), cell.
/// Together they name one cell worldwide.
class CellKey {
  const CellKey(this.radio, this.mcc, this.mnc, this.area, this.cell);

  final CellRadio radio;
  final int mcc, mnc, area, cell;

  @override
  bool operator ==(Object other) =>
      other is CellKey &&
      other.radio == radio &&
      other.mcc == mcc &&
      other.mnc == mnc &&
      other.area == area &&
      other.cell == cell;

  @override
  int get hashCode => Object.hash(radio, mcc, mnc, area, cell);

  @override
  String toString() => '${radio.name} $mcc-$mnc-$area-$cell';
}

/// Where a cell was measured from, on average, and how far it reaches.
class CellSite {
  const CellSite(this.at, this.rangeMeters);
  final LatLng at;
  final double rangeMeters;
}

class CellPack {
  CellPack._(this._sites);

  /// Cells with fixed positions, for tests and the training sandbox.
  CellPack.of(Map<CellKey, CellSite> sites) : _sites = Map.of(sites);

  final Map<CellKey, CellSite> _sites;

  static const attribution = 'Cell towers: OpenCelliD (CC BY-SA 4.0)';

  int get length => _sites.length;

  CellSite? operator [](CellKey key) => _sites[key];

  factory CellPack.decode(Uint8List bytes) {
    if (bytes.length < 4 || ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'HFCT') {
      throw const CellPackFormatException('Not a Holdfast cell-tower pack');
    }
    var offset = 4;
    // Arithmetic rather than bit operations: 5G cell ids reach 36 bits,
    // past the 32 that bitwise operators keep on the web.
    int uint() {
      var result = 0, scale = 1;
      while (true) {
        if (offset >= bytes.length) throw const CellPackFormatException('Cell-tower pack is truncated');
        final byte = bytes[offset++];
        result += (byte & 0x7f) * scale;
        if (byte < 0x80) return result;
        scale *= 128;
      }
    }

    int sint() {
      final z = uint();
      return z.isEven ? z ~/ 2 : -(z + 1) ~/ 2;
    }

    final version = uint();
    if (version != 1) throw CellPackFormatException('Cell-tower pack version $version; this app reads 1');
    final count = uint();
    final sites = <CellKey, CellSite>{};
    var lat = 0, lon = 0;
    for (var i = 0; i < count; i++) {
      final radio = uint();
      if (radio >= CellRadio.values.length) throw CellPackFormatException('Unknown radio $radio');
      final key = CellKey(CellRadio.values[radio], uint(), uint(), uint(), uint());
      lat += sint();
      lon += sint();
      sites[key] = CellSite(LatLng(lat / 1e5, lon / 1e5), uint().toDouble());
    }
    return CellPack._(sites);
  }
}
