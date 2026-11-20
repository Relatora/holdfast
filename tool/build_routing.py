#!/usr/bin/env python3
"""Build a region's offline routing pack from OpenStreetMap.

Directions in Holdfast are computed on the device, because an online
routing API is useless exactly when it is needed. This tool downloads the
region's roads, paths and rail lines from Overpass and compiles them into a
small graph the app can search with A*:

* **Vertices** are only the points where ways meet (or end). A road that
  bends 40 times between two junctions is one edge with 40 shape points,
  not 40 edges, which keeps the search fast and the file small.
* **Edges** carry everything the four travel modes need: which modes may use
  them (foot, bicycle, car, rail), one-way rules per mode, the road class and
  any posted speed limit (the app turns these into travel times), the
  street name for step-by-step directions, and the simplified shape for
  drawing the route.
* **Stations** (railway=station/halt) let the app plan walk → train → walk.

The file is a sequence of LEB128 varints with zigzag-encoded coordinate
deltas: a city's network fits in a few megabytes without compression.

Format (all integers varint; coordinates in micro-degrees):

    "HFRT", version
    strings:  count, then (byte length, UTF-8 bytes)...
    vertices: count, then (zigzag dlat, zigzag dlon)...   # delta from previous
    edges:    count, then per edge:
              from, to, length (decimetres), modes, oneway flags, class,
              maxspeed (km/h, 0 = unknown), name (string index + 1, 0 = none),
              shape point count, (zigzag dlat, zigzag dlon)...  # from "from"
    stations: count, then (zigzag lat, zigzag lon, byte length, UTF-8 name)...

Usage:
    python tool/build_routing.py sarnia
    python tool/build_routing.py ottawa --out-dir regions

Overpass can return a city's network; provinces and larger need a planet
file pipeline (osmium), which is future work.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "assets" / "regions" / "catalog.json"
OUT_DIR = REPO_ROOT / "regions"
# The main Overpass instance is shared and often at capacity; the others
# are public mirrors running the same software.
OVERPASS_URLS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
USER_AGENT = "holdfast-routing-build/0.1 (open-source emergency map)"
FORMAT_VERSION = 1

# Mode bits. Must match lib/routing/routing_graph.dart.
FOOT, BIKE, CAR, RAIL = 1, 2, 4, 8
# One-way flags: the edge may only be travelled from -> to by this mode.
CAR_ONEWAY, BIKE_ONEWAY = 1, 2

# Road classes, in the order the app indexes them. Must match
# RoadClass in lib/routing/routing_graph.dart.
CLASSES = [
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
    "residential", "motorway_link", "trunk_link", "primary_link",
    "secondary_link", "tertiary_link", "living_street", "service",
    "pedestrian", "track", "footway", "path", "cycleway", "steps",
    "bridleway", "road", "rail",
]
CLASS_INDEX = {name: i for i, name in enumerate(CLASSES)}

CAR_ROADS = {
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
    "residential", "motorway_link", "trunk_link", "primary_link",
    "secondary_link", "tertiary_link", "living_street", "service", "road",
}
BIKE_ROADS = (CAR_ROADS - {"motorway", "motorway_link"}) | {"cycleway", "path", "track"}
FOOT_ROADS = (set(CLASSES) - {"motorway", "motorway_link", "rail"})
RAIL_TYPES = {"rail", "light_rail", "subway", "narrow_gauge"}

YES = {"yes", "designated", "permissive", "destination"}
NO = {"no", "private", "use_sidepath"}

# Shape points closer than this to the straight line between their
# neighbours are dropped (Douglas-Peucker). Invisible at street zoom and
# roughly halves the file.
SIMPLIFY_METRES = 2.5


def overpass(query: str, timeout: int = 600, rounds: int = 7) -> dict:
    """Run a query, trying each mirror in turn.

    When every server is at capacity (they answer 429/502/504 with "all
    query workers are busy"), wait and go round again, doubling the wait
    each time as the servers ask: 20 s, 40 s, ... capped at 5 minutes.
    """
    data = urllib.parse.urlencode({"data": query}).encode()
    for round_ in range(rounds):
        for url in OVERPASS_URLS:
            request = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    return json.load(response)
            # A dropped connection mid-download (IncompleteRead) is as
            # retryable as a busy server.
            except (urllib.error.URLError, http.client.HTTPException, OSError, json.JSONDecodeError) as error:
                print(f"  {url}: {error!r:.200}", flush=True)
        wait = min(300, 20 * 2 ** round_)
        print(f"  every server is busy; trying again in {wait} s", flush=True)
        time.sleep(wait)
    raise RuntimeError("Overpass stayed at capacity; try again later")


def query_for(bbox: list[float]) -> str:
    west, south, east, north = bbox
    area = f"({south},{west},{north},{east})"
    highways = "|".join(c for c in CLASSES if c != "rail")
    rails = "|".join(sorted(RAIL_TYPES))
    # No [maxsize]: asking for more than the default 512 MB makes a busy
    # server reject the query outright, and a city's network fits anyway.
    return f"""[out:json][timeout:300];
(
  way["highway"~"^({highways})$"]{area};
  way["railway"~"^({rails})$"]{area};
)->.ways;
.ways out body qt;
node(w.ways);
out skel qt;
node["railway"~"^(station|halt)$"]{area};
out body qt;
rel["route"~"^(train|light_rail|subway)$"]{area};
way(r)["railway"];
out ids qt;
"""


def modes_for(tags: dict[str, str], passenger: bool = True) -> int:
    """Which modes may use a way, from its class and access tags.

    [passenger] is false for track that no passenger line runs on (freight
    spurs, yards, the link between a light-rail line and the main line).
    Track connectivity is not service: riding it would plan a "train" from
    Ottawa's VIA station to a light-rail stop no train ever serves."""
    railway = tags.get("railway")
    if railway in RAIL_TYPES:
        return RAIL if passenger else 0
    highway = tags.get("highway")
    if highway is None:
        return 0
    modes = 0
    if highway in CAR_ROADS:
        modes |= CAR
    if highway in BIKE_ROADS:
        modes |= BIKE
    if highway in FOOT_ROADS:
        modes |= FOOT

    # General access first, then the mode-specific tags that override it.
    if tags.get("access") in NO:
        modes = 0
    for key in ("motor_vehicle", "motorcar"):
        if tags.get(key) in NO:
            modes &= ~CAR
        elif tags.get(key) in YES and highway in CAR_ROADS:
            modes |= CAR
    if tags.get("bicycle") in NO:
        modes &= ~BIKE
    elif tags.get("bicycle") in YES:
        modes |= BIKE
    if tags.get("foot") in NO:
        modes &= ~FOOT
    elif tags.get("foot") in YES:
        modes |= FOOT
    if highway == "steps":
        modes &= FOOT  # nobody drives or rides up stairs
    return modes


def oneway_flags(tags: dict[str, str]) -> tuple[int, bool]:
    """(flags, reversed): one-way rules, and whether the way is drawn
    against its direction of travel (oneway=-1)."""
    oneway = tags.get("oneway")
    implied = tags.get("highway") in ("motorway", "motorway_link") or \
        tags.get("junction") in ("roundabout", "circular")
    is_oneway = oneway in ("yes", "true", "1", "-1") or (implied and oneway != "no")
    if not is_oneway:
        return 0, False
    flags = CAR_ONEWAY
    # Contraflow cycling is common in cities and tagged explicitly.
    bike_both_ways = tags.get("oneway:bicycle") == "no" or \
        tags.get("cycleway") in ("opposite", "opposite_lane", "opposite_track")
    if not bike_both_ways:
        flags |= BIKE_ONEWAY
    return flags, oneway == "-1"


def maxspeed_kmh(tags: dict[str, str]) -> int:
    raw = (tags.get("maxspeed") or "").strip().lower()
    try:
        if raw.endswith("mph"):
            return min(255, round(float(raw[:-3]) * 1.609))
        return min(255, int(float(raw)))
    except ValueError:
        return 0


def metres(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


def simplify(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Douglas-Peucker on a short polyline, in a local flat projection."""
    if len(points) < 3:
        return points
    lat0 = math.radians(points[0][0])
    xy = [(p[1] * 111320 * math.cos(lat0), p[0] * 110540) for p in points]

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        (ax, ay), (bx, by) = xy[first], xy[last]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy) or 1e-9
        worst, worst_i = 0.0, -1
        for i in range(first + 1, last):
            px, py = xy[i]
            distance = abs(dy * px - dx * py + bx * ay - by * ax) / length
            if distance > worst:
                worst, worst_i = distance, i
        if worst > SIMPLIFY_METRES:
            keep[worst_i] = True
            stack += [(first, worst_i), (worst_i, last)]
    return [p for p, k in zip(points, keep) if k]


class Writer:
    def __init__(self) -> None:
        self.out = bytearray(b"HFRT")

    def uint(self, value: int) -> None:
        while True:
            byte = value & 0x7F
            value >>= 7
            if value:
                self.out.append(byte | 0x80)
            else:
                self.out.append(byte)
                return

    def sint(self, value: int) -> None:
        self.uint((value << 1) ^ (value >> 63))  # zigzag

    def text(self, value: str) -> None:
        raw = value.encode("utf-8")
        self.uint(len(raw))
        self.out += raw


def _pin_station(station, rail_ways, coords, usage, within=400.0) -> bool:
    """On each rail way passing within [within] metres of the station, turn
    the closest node into a vertex. False when no track passes that close
    (a bus-only or closed station)."""
    lat, lon, _name = station
    pinned = False
    for refs in rail_ways:
        best, best_m = None, within
        for node in refs:
            nlat, nlon = coords[node]
            if abs(nlat - lat) > 0.005 or abs(nlon - lon) > 0.007:
                continue  # cheap box test before the real distance
            m = metres((lat, lon), (nlat, nlon))
            if m < best_m:
                best, best_m = node, m
        if best is not None:
            usage[best] = max(usage.get(best, 0), 2)
            pinned = True
    return pinned


def micro(degrees: float) -> int:
    return round(degrees * 1_000_000)


def build(data: dict) -> tuple[bytes, dict[str, int]]:
    coords: dict[int, tuple[float, float]] = {}
    ways: list[tuple[list[int], dict[str, str]]] = []
    stations: list[tuple[float, float, str]] = []
    passenger_ids: set[int] = set()
    for element in data["elements"]:
        if element["type"] == "node":
            coords[element["id"]] = (element["lat"], element["lon"])
            tags = element.get("tags")
            if tags and tags.get("railway") in ("station", "halt") and tags.get("name"):
                stations.append((element["lat"], element["lon"], tags["name"]))
        elif element["type"] == "way" and "nodes" in element:
            ways.append((element["id"], element["nodes"], element.get("tags", {})))
        elif element["type"] == "way":
            # The last block of the query: ids of track carrying a
            # passenger route (train, light rail, subway).
            passenger_ids.add(element["id"])
    # A region whose lines aren't mapped as route relations keeps all track.
    if not passenger_ids:
        passenger_ids = {way_id for way_id, _, tags in ways if tags.get("railway") in RAIL_TYPES}

    # A node becomes a graph vertex when it ends a way or is shared by two.
    usage: dict[int, int] = {}
    usable = []
    rail_ways: list[list[int]] = []
    for way_id, refs, tags in ways:
        modes = modes_for(tags, passenger=way_id in passenger_ids)
        refs = [r for r in refs if r in coords]
        if modes == 0 or len(refs) < 2:
            continue
        usable.append((refs, tags, modes))
        for r in refs:
            usage[r] = usage.get(r, 0) + 1
        usage[refs[0]] += 1
        usage[refs[-1]] += 1
        if modes == RAIL:
            rail_ways.append(refs)

    # Tracks run for kilometres between junctions, so a station is rarely
    # near a vertex. On every track passing the station, make the closest
    # node a vertex, so the app can board there, and change lines at a
    # station two lines share without sharing track (Ottawa's Bayview).
    stations = [s for s in stations if _pin_station(s, rail_ways, coords, usage)]

    vertex_of: dict[int, int] = {}
    vertices: list[tuple[float, float]] = []
    strings: dict[str, int] = {}
    edges = []

    def vertex(node: int) -> int:
        if node not in vertex_of:
            vertex_of[node] = len(vertices)
            vertices.append(coords[node])
        return vertex_of[node]

    for refs, tags, modes in usable:
        flags, reverse = oneway_flags(tags)
        if reverse:
            refs = refs[::-1]
        cls = CLASS_INDEX["rail"] if modes == RAIL else CLASS_INDEX.get(tags.get("highway", "road"), CLASS_INDEX["road"])
        name = tags.get("name") or tags.get("ref") or ""
        name_id = 0
        if name:
            name_id = strings.setdefault(name, len(strings)) + 1
        speed = maxspeed_kmh(tags)

        start = 0
        for i in range(1, len(refs)):
            if i < len(refs) - 1 and usage[refs[i]] < 2:
                continue
            segment = [coords[r] for r in refs[start:i + 1]]
            length = sum(metres(segment[j], segment[j + 1]) for j in range(len(segment) - 1))
            if length > 0:
                shape = simplify(segment)[1:-1]
                edges.append((vertex(refs[start]), vertex(refs[i]), round(length * 10),
                              modes, flags, cls, speed, name_id, shape))
            start = i

    w = Writer()
    w.uint(FORMAT_VERSION)
    names = sorted(strings, key=strings.get)
    w.uint(len(names))
    for name in names:
        w.text(name)

    w.uint(len(vertices))
    prev = (0, 0)
    for lat, lon in vertices:
        cur = (micro(lat), micro(lon))
        w.sint(cur[0] - prev[0])
        w.sint(cur[1] - prev[1])
        prev = cur

    w.uint(len(edges))
    for a, b, length, modes, flags, cls, speed, name_id, shape in edges:
        for value in (a, b, length, modes, flags, cls, speed, name_id, len(shape)):
            w.uint(value)
        prev = (micro(vertices[a][0]), micro(vertices[a][1]))
        for lat, lon in shape:
            cur = (micro(lat), micro(lon))
            w.sint(cur[0] - prev[0])
            w.sint(cur[1] - prev[1])
            prev = cur

    w.uint(len(stations))
    for lat, lon, name in stations:
        w.sint(micro(lat))
        w.sint(micro(lon))
        w.text(name)

    stats = {
        "vertices": len(vertices),
        "edges": len(edges),
        "stations": len(stations),
        "names": len(names),
        "ways": len(usable),
    }
    return bytes(w.out), stats


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("region", help="region id from assets/regions/catalog.json")
    parser.add_argument("--out-dir", type=Path, default=OUT_DIR,
                        help="where to write <id>.routing.bin (default: regions/ in the repo)")
    parser.add_argument("--refresh", action="store_true",
                        help="download again even if a recent copy is cached")
    args = parser.parse_args()

    regions = json.loads(CATALOG.read_text(encoding="utf-8"))["regions"]
    region = next((r for r in regions if r["id"] == args.region), None)
    if region is None:
        sys.exit(f"Unknown region '{args.region}'")
    if region["level"] != "city":
        sys.exit("Overpass can only return a city's road network; larger "
                 "regions need a planet-file pipeline.")

    # Keep the raw download for a day: rebuilding after a format or rules
    # change shouldn't cost the shared Overpass servers another query.
    query = query_for(region["bbox"])
    digest = hashlib.sha1(query.encode()).hexdigest()[:10]
    cache = args.out_dir / ".overpass" / f"{region['id']}-{digest}.json"
    if not args.refresh and cache.exists() and time.time() - cache.stat().st_mtime < 86400:
        print(f"Using the network downloaded at {time.ctime(cache.stat().st_mtime)}", flush=True)
        data = json.loads(cache.read_text(encoding="utf-8"))
    else:
        print(f"Downloading the road and rail network for {region['name']}...", flush=True)
        started = time.time()
        data = overpass(query)
        print(f"  {len(data['elements']):,} elements in {time.time() - started:.0f} s", flush=True)
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(data), encoding="utf-8")

    pack, stats = build(data)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    target = args.out_dir / f"{region['id']}.routing.bin"
    partial = target.with_name(target.name + ".part")
    partial.write_bytes(pack)
    partial.replace(target)  # never serve half a pack
    print(f"Wrote {target} ({len(pack) / 1e6:.1f} MB): "
          + ", ".join(f"{v:,} {k}" for k, v in stats.items()))


if __name__ == "__main__":
    main()
