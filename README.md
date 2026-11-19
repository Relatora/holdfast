# Holdfast

**An offline survival map for emergencies.** Holdfast shows where to find food, water, tools, medicine, fuel and shelter, lets people flag hazards that the community verifies, and keeps working when the network doesn't.

Built with **Flutter** (one codebase for Android, iOS, Windows, macOS, Linux and web), a small **Go** sync server, and **PostGIS**. Map data comes from **OpenStreetMap**, packaged as **PMTiles** regions.

<p align="center">
  <img src="docs/screenshots/map-light.jpg" width="200" alt="Light theme map with hazard markers">
  <img src="docs/screenshots/supplies-dark.jpg" width="200" alt="Dark theme with big-box store pins">
  <img src="docs/screenshots/night-vision.jpg" width="200" alt="Night-vision theme, all red">
  <img src="docs/screenshots/radar.jpg" width="200" alt="Nearest-supplies radar sweep">
</p>

## What it does

| | |
|---|---|
| **Offline maps, any size** | Download a city (Ottawa is 21 MB), a province, a country, a continent or the entire planet. Downloads resume after interruption. |
| **Supplies by category** | Big-box stores, groceries, hardware, outdoor, medical, drinking water, fuel and shelters: 3,483 places for Ottawa alone, all searchable offline. |
| **Nearest supplies** | A radar sweep finds the closest place of each kind. |
| **Community hazards** | Long-press to report a fire, flood, blocked road or gas leak. A report is shown to everyone once people nearby confirm it, and expires when nobody does. |
| **Three palettes + system** | Light for sunlight, dark for dusk, and **night vision**: pure red on black, which preserves dark-adapted eyes. Switching plays a circular reveal. |
| **Battery saver** | One switch turns off every decorative animation. The OS "reduce motion" setting is honoured too. |

<p align="center">
  <img src="docs/screenshots/welcome-cards.jpg" width="200" alt="Welcome flashcards">
  <img src="docs/screenshots/map-picker.jpg" width="200" alt="Map picker by continent">
  <img src="docs/screenshots/hazard-details.jpg" width="200" alt="Hazard details with votes">
</p>

## Architecture

```
┌─────────────── Flutter app ───────────────┐        ┌──────── Go server ────────┐
│ flutter_map + vector_map_tiles (PMTiles)  │  HTTP  │ POST/GET /v1/events       │
│ PoiIndex: offline search & nearest        │◄──────►│   append-only event log   │
│ HazardRepository: local event log+outbox  │ Range  │ GET /regions/* (Range)    │
│ hazard_engine.dart: the shared rules      │        │ Memory store │ PostGIS    │
└───────────────────────────────────────────┘        └───────────────────────────┘
          ▲ future: the same events over Bluetooth mesh and LoRa radio (#9, #10)
```

Design decisions worth reading:

- **Hazards sync as facts, not state.** Every report and vote is an immutable event with a UUID. Folding the log is order-independent and idempotent, so events can arrive late, twice or out of order, over the internet today and over mesh radio later. See [`hazard_events.dart`](lib/hazards/hazard_events.dart).
- **The verification rules run on the client.** The server is a relay; it never decides what is "verified". Two phones with no server in reach still reach the same answer from the same facts. See [`hazard_engine.dart`](lib/hazards/hazard_engine.dart) and the discussion in #2.
- **One rendering path for every platform.** `maplibre_gl` has no desktop support, so the map is pure Dart (`flutter_map`) reading PMTiles from a local file or over HTTP range requests (#5).
- **Night vision is generated, not hand-drawn.** The dark map style is walked recursively and every colour is mapped to a red of the same luminance. A test asserts that no blue light survives. See [`basemap_style.dart`](lib/map/basemap_style.dart).

## Run it locally

Requirements: Flutter 3.50+, Go 1.26+, Python 3.10+.

```sh
# 1. Fetch a region: basemap (~21 MB) and supply locations for Ottawa
python tool/fetch_region.py ottawa
python tool/import_pois.py ottawa

# 2. Start the server (in-memory store; serves regions/ with Range support)
go -C server run .

# 3. Run the app
flutter run -d chrome          # web preview: streams the map from the server
flutter run -d windows         # desktop: downloads maps for offline use
flutter run -d emulator-5554 --dart-define=HOLDFAST_SERVER=http://10.0.2.2:8787
```

For a production-like backend with PostgreSQL + PostGIS: `docker compose -f server/docker-compose.yml up`.

## Tests

```sh
flutter analyze && flutter test   # 52 tests: rules, sync fold, search, styles, onboarding
go -C server vet ./... && go -C server test ./...
```

## Project status

The MVP milestone covers offline maps, supplies, hazards and sync. Next up (see [issues](https://github.com/Relatora/holdfast/issues)): GPS-based "nearest" (#11), Meshtastic LoRa sync (#9), phone-to-phone mesh (#10), signed events (#14) and official alert feeds (#16). The product thinking behind all of it is in [`docs/PRODUCT.md`](docs/PRODUCT.md).

## Data and licences

Code: MIT. Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, ODbL 1.0; the supply packs are derived databases under the same licence. Basemap tiles and styles by [Protomaps](https://protomaps.com). Hazard reports come from users and can be wrong: always follow local authorities.
