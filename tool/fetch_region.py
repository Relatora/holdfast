#!/usr/bin/env python3
"""Cut a regional basemap out of the daily Protomaps planet build.

Holdfast ships maps as one PMTiles file per region. In production a pipeline
runs this extract for every region in ``assets/regions/catalog.json`` and
uploads the results to object storage. Locally you run it for the one or two
regions you want to develop against, and the dev server in ``server/`` serves
the files from ``regions/``.

The extract streams only the tiles inside the bounding box over HTTP range
requests, so a city-sized region costs tens of megabytes of download, not the
~140 GB of the full planet.

Usage:
    python tool/fetch_region.py ottawa
    python tool/fetch_region.py ottawa --maxzoom 13
    python tool/fetch_region.py toronto --dry-run   # size only, no download

Requires Go (the official go-pmtiles CLI is run with ``go run``).
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "assets" / "regions" / "catalog.json"
OUT_DIR = REPO_ROOT / "regions"

# Pinned so every developer extracts with the same CLI behaviour.
GO_PMTILES = "github.com/protomaps/go-pmtiles@v1.31.2"
BUILDS_INDEX = "https://build-metadata.protomaps.dev/builds.json"


def latest_planet_url() -> str:
    """Return the URL of the newest daily planet build."""
    # The index rejects urllib's default User-Agent, so name the tool.
    request = urllib.request.Request(
        BUILDS_INDEX, headers={"User-Agent": "holdfast-fetch-region/0.1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        builds = json.load(response)
    newest = builds[-1]["key"]  # e.g. "20261118.pmtiles"
    return f"https://build.protomaps.com/{newest}"


def find_region(region_id: str) -> dict:
    regions = json.loads(CATALOG.read_text(encoding="utf-8"))["regions"]
    for region in regions:
        if region["id"] == region_id:
            return region
    known = ", ".join(r["id"] for r in regions)
    sys.exit(f"Unknown region '{region_id}'. Known regions: {known}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("region", help="region id from assets/regions/catalog.json")
    parser.add_argument(
        "--maxzoom",
        type=int,
        default=14,
        help="highest zoom to keep; the app over-zooms beyond it (default 14)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=OUT_DIR,
        help="where to write <id>.pmtiles (default: regions/ in the repo)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=("report how big the extract would be without downloading it. "
              "go-pmtiles reads only the archive's directories, so this is "
              "the real size, not a guess, and costs a few MB at most"),
    )
    args = parser.parse_args()

    if shutil.which("go") is None:
        sys.exit("Go is required: https://go.dev/dl/")

    region = find_region(args.region)
    west, south, east, north = region["bbox"]
    args.out_dir.mkdir(parents=True, exist_ok=True)
    target = args.out_dir / f"{region['id']}.pmtiles"
    # Extract to a side file and rename when complete: the region server
    # only serves finished names, so a half-written map is never handed out
    # (and the server reports progress from the side file's size).
    partial = target.with_name(target.name + ".part")

    source = latest_planet_url()
    command = [
        "go", "run", GO_PMTILES, "extract", source, str(partial),
        f"--bbox={west},{south},{east},{north}",
        f"--maxzoom={args.maxzoom}",
    ]
    if args.dry_run:
        print(f"Measuring {region['name']} in {source} (dry run, nothing is downloaded)", flush=True)
        subprocess.run([*command, "--dry-run"], check=True)
        return

    print(f"Extracting {region['name']} from {source}", flush=True)
    partial.unlink(missing_ok=True)  # go-pmtiles won't resume; start clean
    subprocess.run(command, check=True)
    partial.replace(target)
    size_mb = target.stat().st_size / 1_000_000
    print(f"Wrote {target} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
