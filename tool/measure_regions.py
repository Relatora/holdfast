#!/usr/bin/env python3
"""Measure catalog regions and write their real sizes into the catalog.

The map picker shows a size next to every region before anyone downloads
it. Hand-written guesses drift (the first Greater Toronto guess was three
times too big), so this tool asks go-pmtiles for an extract *dry run* of
each region. The dry run reads only the planet archive's directories, finds
exactly which tiles fall inside the bounding box, and reports the archive
size those tiles add up to: the true size, at the cost of a few requests.

Only the basemap is measured. A region's supply pack (``*.pois.json``) is
roughly 2-3% on top: Ottawa's is 0.6 MB next to a 21 MB basemap.

Usage:
    python tool/measure_regions.py                    # cities and provinces
    python tool/measure_regions.py --level country
    python tool/measure_regions.py sarnia toronto     # just these

Continents and the world are skipped by default: their directories alone
run to hundreds of megabytes, and their sizes are published by Protomaps.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fetch_region import CATALOG, GO_PMTILES, latest_planet_url  # noqa: E402

# go-pmtiles ends a dry run with a line like:
#   Extract transferred 54 MB (overfetch 0.05) for an archive size of 52 MB
SIZE_LINE = re.compile(r"archive size of ([\d.]+) (B|kB|KB|MB|GB|TB)")
UNITS = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}


def measure(source: str, region: dict, maxzoom: int) -> int:
    """Bytes the region's extract would be, from a go-pmtiles dry run."""
    west, south, east, north = region["bbox"]
    result = subprocess.run(
        [
            "go", "run", GO_PMTILES, "extract", source, "unused.pmtiles",
            f"--bbox={west},{south},{east},{north}",
            f"--maxzoom={maxzoom}", "--dry-run",
        ],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    match = SIZE_LINE.search(result.stdout + result.stderr)
    if result.returncode != 0 or match is None:
        raise RuntimeError(f"{region['id']}: dry run failed\n{result.stderr[-800:]}")
    return round(float(match.group(1)) * UNITS[match.group(2)])


def write_sizes(sizes: dict[str, int]) -> None:
    """Update approxBytes in place, line by line.

    The catalog is hand-formatted (one region per line, grouped by level),
    so it is edited textually rather than re-serialised, which would turn
    80 readable lines into 900.
    """
    lines = CATALOG.read_text(encoding="utf-8").split("\n")
    for i, line in enumerate(lines):
        found = re.search(r'"id": "([^"]+)"', line)
        if found and found.group(1) in sizes:
            lines[i] = re.sub(r'"approxBytes": \d+', f'"approxBytes": {sizes[found.group(1)]}', line)
    CATALOG.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("ids", nargs="*", help="region ids (default: every region at --level)")
    parser.add_argument("--level", action="append", choices=["city", "province", "country"],
                        help="levels to measure (default: city and province)")
    parser.add_argument("--maxzoom", type=int, default=14)
    parser.add_argument("--jobs", type=int, default=4, help="dry runs in parallel")
    args = parser.parse_args()

    regions = json.loads(CATALOG.read_text(encoding="utf-8"))["regions"]
    levels = set(args.level or ["city", "province"])
    chosen = [r for r in regions if (r["id"] in args.ids if args.ids else r["level"] in levels)]
    if not chosen:
        sys.exit("No matching regions.")

    source = latest_planet_url()
    print(f"Measuring {len(chosen)} regions against {source}", flush=True)
    sizes: dict[str, int] = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(measure, source, r, args.maxzoom): r for r in chosen}
        for future, region in futures.items():
            try:
                sizes[region["id"]] = future.result()
                print(f"  {region['name']:<32} {sizes[region['id']] / 1e6:>10,.1f} MB", flush=True)
            except RuntimeError as error:
                print(f"  {region['name']:<32} FAILED: {error}", flush=True)

    write_sizes(sizes)
    print(f"Updated {len(sizes)} sizes in {CATALOG.relative_to(CATALOG.parents[2])}")


if __name__ == "__main__":
    main()
