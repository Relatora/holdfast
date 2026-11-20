#!/usr/bin/env python3
"""Build a region's population pack from the GHSL population grid.

Holdfast estimates casualties for a reported nuclear detonation by counting
the people inside each effect ring. The counts come from **GHS-POP**, the
Global Human Settlement Layer population grid of the European Commission's
Joint Research Centre (epoch 2025, release R2023A, 30 arc-second WGS84;
licence CC BY 4.0). Attribution: "Schiavina M., Freire S., Carioli A.,
MacManus K. (2023): GHS-POP R2023A - GHS population grid multitemporal
(1975-2030). European Commission, JRC."

GHSL publishes the 30″ grid as 10° × 10° tiles. This tool downloads only
the tiles a region touches (cached under regions/.ghsl/), decodes them in
pure Python (BigTIFF, LZW, float64: no GDAL or numpy needed) and writes
the region's cells as a small pack:

    "HFPP", version (varint)
    west, north, cell size (float64 little-endian, degrees; top-left corner)
    columns, rows (varint)
    rows × columns people per cell (varint, rounded), row by row from the north

A city is a few thousand cells and a few kilobytes.

Usage:
    python tool/build_population.py ottawa
"""

from __future__ import annotations

import argparse
import io
import json
import math
import struct
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "assets" / "regions" / "catalog.json"
OUT_DIR = REPO_ROOT / "regions"
USER_AGENT = "holdfast-population-build/0.1 (open-source emergency map)"

TILE_URL = ("https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/GHS_POP_GLOBE_R2023A/"
            "GHS_POP_E2025_GLOBE_R2023A_4326_30ss/V1-0/tiles/"
            "GHS_POP_E2025_GLOBE_R2023A_4326_30ss_V1_0_R{row}_C{col}.zip")

# The 30″ tiling, from the tiles' own geotransforms: tile R1_C1's top-left
# corner, 1200 × 1200 cells of 1/120°, so 10° per tile.
CELL = 1 / 120
TILE_CELLS = 1200
GRID_WEST = -180.0079163273772
GRID_NORTH = 89.09958333862941


# ---- TIFF reading ------------------------------------------------------------

def lzw_decode(data: bytes) -> bytes:
    """TIFF-flavoured LZW: MSB-first codes, 9 to 12 bits, early change."""
    clear, eoi = 256, 257
    out = bytearray()
    table: list[bytes] = []
    bits, pos, nbits = 0, 0, 0
    width = 9
    prev: bytes | None = None
    data_len = len(data)

    def reset():
        nonlocal table, width, prev
        table = [bytes([i]) for i in range(256)] + [b"", b""]
        width = 9
        prev = None

    reset()
    while True:
        while nbits < width and pos < data_len:
            bits = (bits << 8) | data[pos]
            pos += 1
            nbits += 8
        if nbits < width:
            break
        nbits -= width
        code = (bits >> nbits) & ((1 << width) - 1)
        bits &= (1 << nbits) - 1
        if code == eoi:
            break
        if code == clear:
            reset()
            continue
        if prev is None:
            entry = table[code]
            out += entry
            prev = entry
            continue
        if code < len(table):
            entry = table[code]
            table.append(prev + entry[:1])
        else:  # the KwKwK case
            entry = prev + prev[:1]
            table.append(entry)
        out += entry
        prev = entry
        # "Early change": TIFF widens one code before the table fills.
        if len(table) + 1 >= (1 << width) and width < 12:
            width += 1
    return bytes(out)


class BigTiff:
    """Just enough BigTIFF to read a tiled, single-band float64 grid."""

    def __init__(self, raw: bytes):
        if raw[:2] != b"II" or struct.unpack("<H", raw[2:4])[0] != 43:
            raise ValueError("expected a little-endian BigTIFF")
        self.raw = raw
        tags = self._tags(struct.unpack("<Q", raw[8:16])[0])
        self.width, self.height = tags[256][0], tags[257][0]
        self.tile_w, self.tile_h = tags[322][0], tags[323][0]
        self.offsets, self.counts = tags[324], tags[325]
        if tags[259][0] not in (1, 5) or tags[258][0] != 64 or tags[339][0] != 3:
            raise ValueError("expected an uncompressed or LZW float64 grid")
        self.compressed = tags[259][0] == 5
        self.predictor = tags.get(317, [1])[0]
        self.tiles_across = math.ceil(self.width / self.tile_w)
        self._cache: dict[int, list[float]] = {}

    def _tags(self, offset: int) -> dict[int, list]:
        sizes = {1: 1, 2: 1, 3: 2, 4: 4, 11: 4, 12: 8, 16: 8, 17: 8}
        fmts = {1: "B", 2: "B", 3: "H", 4: "I", 11: "f", 12: "d", 16: "Q", 17: "q"}
        count = struct.unpack("<Q", self.raw[offset:offset + 8])[0]
        tags = {}
        for i in range(count):
            entry = self.raw[offset + 8 + i * 20: offset + 28 + i * 20]
            tag, typ, n = struct.unpack("<HHQ", entry[:12])
            size = sizes.get(typ, 1) * n
            data = entry[12:12 + size] if size <= 8 else \
                self.raw[struct.unpack("<Q", entry[12:20])[0]:][:size]
            tags[tag] = list(struct.unpack("<" + fmts.get(typ, "B") * n, data[:sizes.get(typ, 1) * n]))
        return tags

    def _tile(self, index: int) -> list[float]:
        if index not in self._cache:
            start, length = self.offsets[index], self.counts[index]
            data = self.raw[start:start + length]
            if self.compressed:
                data = lzw_decode(data)
            if self.predictor == 2:  # horizontal differencing (not used by GHSL)
                raise ValueError("predictor 2 is not supported")
            self._cache[index] = list(struct.unpack(f"<{self.tile_w * self.tile_h}d",
                                                    data[:self.tile_w * self.tile_h * 8]))
        return self._cache[index]

    def value(self, col: int, row: int) -> float:
        tile = (row // self.tile_h) * self.tiles_across + col // self.tile_w
        cells = self._tile(tile)
        v = cells[(row % self.tile_h) * self.tile_w + col % self.tile_w]
        return v if v > 0 else 0.0  # negative values mark "no data" (sea)


# ---- Region extraction -------------------------------------------------------

def fetch_tile(row: int, col: int, cache: Path) -> BigTiff | None:
    target = cache / f"R{row}_C{col}.zip"
    if not target.exists():
        url = TILE_URL.format(row=row, col=col)
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None  # open ocean: GHSL has no tile here
            raise
        cache.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    with zipfile.ZipFile(io.BytesIO(target.read_bytes())) as archive:
        name = next(n for n in archive.namelist() if n.endswith(".tif"))
        return BigTiff(archive.read(name))


def uint(out: bytearray, value: int) -> None:
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return


def build(bbox: list[float], cache: Path) -> tuple[bytes, float]:
    west, south, east, north = bbox
    # Global cell indices covering the box.
    col0 = math.floor((west - GRID_WEST) / CELL)
    col1 = math.ceil((east - GRID_WEST) / CELL)
    row0 = math.floor((GRID_NORTH - north) / CELL)
    row1 = math.ceil((GRID_NORTH - south) / CELL)
    cols, rows = col1 - col0, row1 - row0

    tiles: dict[tuple[int, int], BigTiff | None] = {}
    values = []
    total = 0.0
    for r in range(row0, row1):
        for c in range(col0, col1):
            key = (r // TILE_CELLS + 1, c // TILE_CELLS + 1)
            if key not in tiles:
                print(f"  tile R{key[0]}_C{key[1]}", flush=True)
                tiles[key] = fetch_tile(*key, cache)
            tile = tiles[key]
            v = tile.value(c % TILE_CELLS, r % TILE_CELLS) if tile else 0.0
            total += v
            values.append(round(v))

    out = bytearray(b"HFPP")
    uint(out, 1)
    out += struct.pack("<ddd", GRID_WEST + col0 * CELL, GRID_NORTH - row0 * CELL, CELL)
    uint(out, cols)
    uint(out, rows)
    for v in values:
        uint(out, v)
    return bytes(out), total


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("region", help="region id from assets/regions/catalog.json")
    parser.add_argument("--out-dir", type=Path, default=OUT_DIR,
                        help="where to write <id>.population.bin (default: regions/ in the repo)")
    args = parser.parse_args()

    regions = json.loads(CATALOG.read_text(encoding="utf-8"))["regions"]
    region = next((r for r in regions if r["id"] == args.region), None)
    if region is None:
        sys.exit(f"Unknown region '{args.region}'")

    started = time.time()
    print(f"Building the population grid for {region['name']}", flush=True)
    pack, total = build(region["bbox"], args.out_dir / ".ghsl")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    target = args.out_dir / f"{region['id']}.population.bin"
    partial = target.with_name(target.name + ".part")
    partial.write_bytes(pack)
    partial.replace(target)
    print(f"Wrote {target} ({len(pack) / 1000:.0f} KB, {total:,.0f} people) "
          f"in {time.time() - started:.0f} s")


if __name__ == "__main__":
    main()
