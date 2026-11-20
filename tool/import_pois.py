#!/usr/bin/env python3
"""Build a region's supply-location pack from OpenStreetMap.

For one region in ``assets/regions/catalog.json`` this script asks the public
Overpass API for every place that could matter in an emergency (big-box
stores, groceries, hardware, pharmacies, water, fuel, shelters), sorts each
one into a Holdfast category, and writes a compact JSON pack:

    regions/<region-id>.pois.json

The app downloads that pack next to the region's ``.pmtiles`` basemap, so
search and "nearest supplies" work with no connection at all.

Categories are decided by OSM tags first, then refined by brand: a Walmart is
tagged ``shop=department_store`` in OSM, but for our users it belongs with the
other big-box stores that stock food, water and tools under one roof.

Usage:
    python tool/import_pois.py ottawa

Data: (c) OpenStreetMap contributors, ODbL 1.0. The pack is a derived
database, so it must stay available under the ODbL with attribution.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "assets" / "regions" / "catalog.json"
OUT_DIR = REPO_ROOT / "regions"
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "holdfast-poi-import/0.1 (open-source emergency map)"

# Tag filters sent to Overpass, grouped by the category they usually map to.
# Order matters in classify(): the first matching rule wins.
TAG_RULES: list[tuple[str, str, set[str]]] = [
    ("bigbox", "shop", {"department_store", "wholesale", "general", "variety_store"}),
    ("grocery", "shop", {"supermarket", "convenience", "greengrocer", "farm"}),
    ("hardware", "shop", {"hardware", "doityourself", "trade", "agrarian"}),
    ("outdoor", "shop", {"outdoor", "sports", "hunting", "fishing"}),
    ("medical", "amenity", {"pharmacy", "hospital", "clinic", "doctors", "veterinary"}),
    ("medical", "shop", {"chemist", "medical_supply"}),
    ("water", "amenity", {"drinking_water", "water_point"}),
    ("water", "natural", {"spring"}),
    ("water", "man_made", {"water_well"}),
    ("fuel", "amenity", {"fuel"}),
    ("fuel", "shop", {"gas"}),  # propane and other bottled gas
    ("shelter", "amenity", {"shelter", "community_centre", "fire_station", "police"}),
    ("shelter", "emergency", {"assembly_point"}),
    ("shelter", "social_facility", {"shelter"}),
    # Airports, regional airfields and private strips: where airlifts,
    # medical flights and supply drops land when the roads are cut.
    ("airport", "aeroway", {"aerodrome"}),
]

# Chains that stock food, water and tools in one stop. Matched against the
# OSM brand or name, lower-cased, so tagging differences don't matter.
BIGBOX_BRANDS = {
    "walmart", "costco", "canadian tire", "real canadian superstore",
    "giant tiger", "target", "meijer", "sam's club", "fred meyer",
}

# Only these tags are kept in the pack: enough for the place sheet, small
# enough that a province fits in a few megabytes.
KEPT_TAGS = ("brand", "opening_hours", "phone", "addr:street", "addr:housenumber",
             "addr:city", "website", "generator:source", "drinking_water")


def overpass_query(bbox: list[float]) -> str:
    west, south, east, north = bbox
    area = f"({south},{west},{north},{east})"  # Overpass wants S,W,N,E
    selectors = []
    for _category, key, values in TAG_RULES:
        pattern = "|".join(sorted(values))
        selectors.append(f'  nwr["{key}"~"^({pattern})$"]{area};')
    body = "\n".join(selectors)
    # "out center" gives ways and relations (big store buildings) one point.
    return f"[out:json][timeout:180];\n(\n{body}\n);\nout center tags;"


def fetch(query: str) -> list[dict]:
    data = urllib.parse.urlencode({"data": query}).encode()
    request = urllib.request.Request(OVERPASS_URL, data=data,
                                     headers={"User-Agent": USER_AGENT})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=240) as response:
                return json.load(response)["elements"]
        except urllib.error.HTTPError as error:
            # 429 and 502-504 mean the shared server is busy or restarting;
            # back off and retry.
            if error.code in (429, 502, 503, 504) and attempt < 2:
                time.sleep(30 * (attempt + 1))
                continue
            raise
    return []


def classify(tags: dict[str, str]) -> str | None:
    brand = (tags.get("brand") or tags.get("name") or "").lower()
    if any(b in brand for b in BIGBOX_BRANDS):
        return "bigbox"
    for category, key, values in TAG_RULES:
        if tags.get(key) in values:
            return category
    return None


def to_poi(element: dict) -> dict | None:
    tags = element.get("tags", {})
    category = classify(tags)
    if category is None:
        return None
    lat = element.get("lat") or element.get("center", {}).get("lat")
    lon = element.get("lon") or element.get("center", {}).get("lon")
    if lat is None or lon is None:
        return None
    poi = {
        "id": f"{element['type'][0]}{element['id']}",  # e.g. "n12345"
        "cat": category,
        "name": tags.get("name") or tags.get("brand") or "",
        "lat": round(lat, 6),
        "lon": round(lon, 6),
    }
    extra = {k: tags[k] for k in KEPT_TAGS if k in tags}
    if extra:
        poi["tags"] = extra
    return poi


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("region", help="region id from assets/regions/catalog.json")
    parser.add_argument("--out-dir", type=Path, default=OUT_DIR,
                        help="where to write <id>.pois.json (default: regions/ in the repo)")
    args = parser.parse_args()

    regions = json.loads(CATALOG.read_text(encoding="utf-8"))["regions"]
    region = next((r for r in regions if r["id"] == args.region), None)
    if region is None:
        sys.exit(f"Unknown region '{args.region}'")
    if region["level"] in ("world", "continent", "country"):
        sys.exit("Overpass can't serve areas this large; use a planet-file pipeline.")

    elements = fetch(overpass_query(region["bbox"]))
    pois = [p for p in (to_poi(e) for e in elements) if p]
    pois.sort(key=lambda p: (p["cat"], p["name"]))

    args.out_dir.mkdir(parents=True, exist_ok=True)
    target = args.out_dir / f"{region['id']}.pois.json"
    partial = target.with_name(target.name + ".part")
    pack = {
        "region": region["id"],
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "attribution": "© OpenStreetMap contributors, ODbL 1.0",
        "pois": pois,
    }
    # Written aside and renamed, so the server never serves half a pack.
    partial.write_text(json.dumps(pack, ensure_ascii=False, separators=(",", ":")),
                       encoding="utf-8")
    partial.replace(target)

    counts: dict[str, int] = {}
    for poi in pois:
        counts[poi["cat"]] = counts.get(poi["cat"], 0) + 1
    print(f"Wrote {len(pois)} places to {target}")
    for category, count in sorted(counts.items()):
        print(f"  {category:<9} {count}")


if __name__ == "__main__":
    main()
