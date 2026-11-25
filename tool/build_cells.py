#!/usr/bin/env python3
"""Build a region's cell-tower pack from OpenCelliD, for offline positioning.

When GPS can't get a fix (indoors, under cover), a phone can still hear the
cell towers around it, with no SIM data and no network. Knowing where those
towers are lets Holdfast estimate a position on its own. This tool cuts the
towers inside a region's bounding box out of **OpenCelliD** (Unwired Labs,
CC BY-SA 4.0; https://opencellid.org) and writes them as a small pack.

OpenCelliD publishes one CSV per mobile country code (MCC). Downloading
needs a free API token from opencellid.org, read from the environment
variable OPENCELLID_TOKEN; downloads are cached under regions/.opencellid/
and reused. Without a token, pass the CSV files yourself with --csv.

A phone near a border hears the other country's towers too (Sarnia hears
Port Huron), so a region gets the MCCs of its country and its neighbours,
cut to the region's box.

CSV columns (no header): radio, mcc, net, area, cell, unit, lon, lat, range,
samples, changeable, created, updated, averageSignal.

The pack:

    "HFCT", version (varint)
    count (varint)
    count records, sorted by (radio, mcc, mnc, area, cell):
        radio (varint: 0 GSM, 1 UMTS, 2 LTE, 3 NR)
        mcc, mnc, area, cell (varint)
        lat, lon (zigzag varint, 1e-5 degrees, delta from the previous record)
        range (varint, metres)

The positions are where measurements of each cell were averaged, not the
mast itself; that is good to a few hundred metres in a city, which is what
a "you are about here" circle needs.

Usage:
    OPENCELLID_TOKEN=... python tool/build_cells.py ottawa
    python tool/build_cells.py ottawa --csv 302.csv.gz
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "assets" / "regions" / "catalog.json"
OUT_DIR = REPO_ROOT / "regions"
USER_AGENT = "holdfast-cells-build/0.1 (open-source emergency map)"
DOWNLOAD_URL = "https://opencellid.org/ocid/downloads?token={token}&type=mcc&file={mcc}.csv.gz"

# Mobile country codes of the catalog's countries, and who borders whom.
COUNTRY_MCCS = {
    "canada": [302],
    "united-states": [310, 311, 312, 313, 314, 315, 316],
    "mexico": [334],
}
NEIGHBOURS = {
    "canada": ["united-states"],
    "united-states": ["canada", "mexico"],
    "mexico": ["united-states"],
}

# OpenCelliD's radio names. CDMA cells are identified differently (SID,
# NID, base station) and are nearly gone from North America; skipped.
RADIOS = {"GSM": 0, "UMTS": 1, "LTE": 2, "NR": 3}

# A cell seen once may be a mislocated outlier; ranges beyond this are
# not a useful position at all.
MIN_SAMPLES = 2
MAX_RANGE_M = 40_000


def uint(out: bytearray, value: int) -> None:
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return


def sint(out: bytearray, value: int) -> None:
    uint(out, (value << 1) if value >= 0 else ((-value << 1) - 1))


def country_of(region: dict, regions: dict[str, dict]) -> str | None:
    """The catalog country a region sits in, following its parents."""
    while region is not None:
        if region["level"] == "country":
            return region["id"]
        region = regions.get(region.get("parent"))
    return None


def mccs_for(country: str) -> list[int]:
    codes = list(COUNTRY_MCCS.get(country, []))
    for neighbour in NEIGHBOURS.get(country, []):
        codes += COUNTRY_MCCS[neighbour]
    return codes


def fetch(mcc: int, cache: Path, token: str) -> Path:
    """The MCC's CSV, downloaded once and cached."""
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / f"{mcc}.csv.gz"
    if path.exists():
        return path
    print(f"  downloading MCC {mcc}", flush=True)
    request = urllib.request.Request(DOWNLOAD_URL.format(token=token, mcc=mcc),
                                     headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=600) as response:
        data = response.read()
    # A bad token or a rate limit answers 200 with a short text message.
    if not data.startswith(b"\x1f\x8b"):
        raise RuntimeError(f"OpenCelliD refused MCC {mcc}: {data[:200].decode(errors='replace')}")
    partial = path.with_name(path.name + ".part")
    partial.write_bytes(data)
    partial.replace(path)
    return path


def read_rows(path: Path):
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8", newline="") as f:
        for row in csv.reader(f):
            if row and row[0] != "radio":  # tolerate a header line
                yield row


def cells_in(paths: list[Path], bbox: list[float], mccs: set[int] | None) -> list[tuple]:
    west, south, east, north = bbox
    cells = {}
    for path in paths:
        for row in read_rows(path):
            try:
                radio = RADIOS.get(row[0])
                mcc, mnc, area, cell = int(row[1]), int(row[2]), int(row[3]), int(row[4])
                lon, lat, rng, samples = float(row[6]), float(row[7]), int(row[8]), int(row[9])
            except (ValueError, IndexError):
                continue
            if radio is None or (mccs and mcc not in mccs):
                continue
            if not (west <= lon <= east and south <= lat <= north):
                continue
            if samples < MIN_SAMPLES or rng > MAX_RANGE_M:
                continue
            # The same cell can appear in two files; keep the better-sampled.
            key = (radio, mcc, mnc, area, cell)
            if key not in cells or samples > cells[key][-1]:
                cells[key] = (*key, round(lat * 1e5), round(lon * 1e5), max(rng, 1), samples)
    return [c[:-1] for c in sorted(cells.values())]


def encode(cells: list[tuple]) -> bytes:
    out = bytearray(b"HFCT")
    uint(out, 1)
    uint(out, len(cells))
    last_lat = last_lon = 0
    for radio, mcc, mnc, area, cell, lat, lon, rng in cells:
        for v in (radio, mcc, mnc, area, cell):
            uint(out, v)
        sint(out, lat - last_lat)
        sint(out, lon - last_lon)
        uint(out, rng)
        last_lat, last_lon = lat, lon
    return bytes(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("region", help="region id from assets/regions/catalog.json")
    parser.add_argument("--out-dir", type=Path, default=OUT_DIR,
                        help="where to write <id>.cells.bin (default: regions/ in the repo)")
    parser.add_argument("--csv", type=Path, nargs="+",
                        help="OpenCelliD CSV files to read instead of downloading")
    args = parser.parse_args()

    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))["regions"]
    regions = {r["id"]: r for r in catalog}
    region = regions.get(args.region)
    if region is None:
        sys.exit(f"Unknown region '{args.region}'")

    started = time.time()
    print(f"Building the cell-tower pack for {region['name']}", flush=True)
    if args.csv:
        paths, mccs = args.csv, None  # take every MCC in the given files
    else:
        token = os.environ.get("OPENCELLID_TOKEN")
        if not token:
            sys.exit("Set OPENCELLID_TOKEN (free at opencellid.org) or pass --csv files")
        country = country_of(region, regions)
        if country not in COUNTRY_MCCS:
            sys.exit(f"No mobile country codes known for {region['name']}")
        codes = mccs_for(country)
        try:
            paths = [fetch(mcc, args.out_dir / ".opencellid", token) for mcc in codes]
        except (urllib.error.URLError, RuntimeError) as error:
            sys.exit(f"OpenCelliD download failed: {error}")
        mccs = set(codes)

    cells = cells_in(paths, region["bbox"], mccs)
    if not cells:
        sys.exit(f"No cell towers found inside {region['name']}")
    pack = encode(cells)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    target = args.out_dir / f"{region['id']}.cells.bin"
    partial = target.with_name(target.name + ".part")
    partial.write_bytes(pack)
    partial.replace(target)
    print(f"Wrote {target} ({len(pack) / 1000:.0f} KB, {len(cells):,} cells) "
          f"in {time.time() - started:.0f} s")


if __name__ == "__main__":
    main()
