"""Post a real-world hazard report, with a cited source, to a Holdfast server.

For events that happened and were reported by officials or the news (the
2026 Iowa lead azide detonation, a chemical plant fire), so they show on
everyone's map like a neighbour's report would. The report goes through the
server's normal event API, exactly as an app would send it, and is checked by
people nearby like any other: a cited source is not a verification.

The wind is looked up for the hour the event happened (Open-Meteo's
historical forecast, falling back to its forecast API for the last few
days), so the plume drifts the way the air actually moved.

Re-running is safe: the ids are derived from the event's type, place and
time, and the server ignores events it already has.

Usage, the Iowa detonation (9:00 CST, 25 Nov 2026):

    python tool/post_report.py --server http://localhost:8787 \\
        --type leadDust --severity moderate \\
        --lat 40.79056 --lon -91.24472 --at 2026-11-25T15:00:00Z \\
        --description "..." \\
        --source-name "U.S. Army" --source-url https://www.army.mil/article/...

Add --dry-run to print the event without sending it.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

USER_AGENT = "holdfast-report-tool/0.1 (open-source emergency map)"

# Types whose report carries wind (keep in step with HazardType.spreadsWithWind).
WIND_TYPES = {"fire", "gasLeak", "chemicalSpill", "volcanicAsh", "volcanicEruption",
              "nuclearDetonation", "radiation", "leadDust"}

# A fixed namespace, so the same event always gets the same ids.
NAMESPACE = uuid.UUID("6f1d3c2a-6a5e-4b7e-9a35-3f0c8e1d2b40")


def get_json(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def wind_at(lat: float, lon: float, at: datetime) -> dict | None:
    """The 10 m wind for the hour of [at], as the app stores it, or None."""
    day = at.strftime("%Y-%m-%d")
    query = urllib.parse.urlencode({
        "latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}",
        "hourly": "wind_speed_10m,wind_direction_10m",
        "start_date": day, "end_date": day, "timezone": "GMT",
    })
    hour = at.strftime("%Y-%m-%dT%H:00")
    for base in ("https://historical-forecast-api.open-meteo.com/v1/forecast",
                 "https://api.open-meteo.com/v1/forecast"):
        try:
            hourly = get_json(f"{base}?{query}")["hourly"]
            i = hourly["time"].index(hour)
            speed, direction = hourly["wind_speed_10m"][i], hourly["wind_direction_10m"][i]
            if speed is None or direction is None:
                continue
            return {"from": float(direction), "kmh": float(speed), "source": "forecast"}
        except (OSError, KeyError, ValueError) as error:
            print(f"  wind from {base}: {error}", file=sys.stderr)
    return None


def build_event(args: argparse.Namespace) -> dict:
    at = datetime.fromisoformat(args.at.replace("Z", "+00:00")).astimezone(timezone.utc)
    stamp = at.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    key = f"{args.type}|{args.lat:.5f}|{args.lon:.5f}|{stamp}"
    hazard_id = str(uuid.uuid5(NAMESPACE, "hazard|" + key))

    details: dict = {}
    if args.type in WIND_TYPES and not args.no_wind:
        wind = wind_at(args.lat, args.lon, at)
        if wind:
            details["wind"] = wind
            print(f"  wind at {stamp}: from {wind['from']:.0f}° at {wind['kmh']:.1f} km/h")
        else:
            print("  no wind found: the map will draw no plume", file=sys.stderr)
    if args.source_name and args.source_url:
        if not args.source_url.startswith(("https://", "http://")):
            sys.exit("--source-url must be a web link")
        details["source"] = {"name": args.source_name, "url": args.source_url}

    hazard = {
        "id": hazard_id,
        "type": args.type,
        "severity": args.severity,
        "lat": args.lat,
        "lon": args.lon,
        "description": args.description,
        "reportedBy": args.device,
        "reportedAt": stamp,
        # Never claimed as official: people nearby verify it like any report.
        "official": False,
    }
    if details:
        hazard["details"] = details
    return {
        "id": str(uuid.uuid5(NAMESPACE, "event|" + key)),
        "kind": "report",
        "hazardId": hazard_id,
        "deviceId": args.device,
        "at": stamp,
        "lat": args.lat,
        "lon": args.lon,
        "payload": hazard,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--server", default="http://localhost:8787")
    parser.add_argument("--type", required=True, help="a HazardType name, e.g. leadDust")
    parser.add_argument("--severity", default="moderate", choices=["low", "moderate", "high", "extreme"])
    parser.add_argument("--lat", type=float, required=True)
    parser.add_argument("--lon", type=float, required=True)
    parser.add_argument("--at", required=True, help="when it happened, ISO 8601 in UTC")
    parser.add_argument("--description", default="")
    parser.add_argument("--source-name")
    parser.add_argument("--source-url")
    parser.add_argument("--device", default="desk-real-events",
                        help="the reporter id shown on the map")
    parser.add_argument("--no-wind", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    event = build_event(args)
    body = json.dumps({"events": [event]}).encode()
    if args.dry_run:
        print(json.dumps(event, indent=2))
        return
    request = urllib.request.Request(
        f"{args.server.rstrip('/')}/v1/events", data=body, method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        print(f"  posted {event['hazardId']}: HTTP {response.status}")


if __name__ == "__main__":
    main()
