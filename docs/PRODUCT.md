# Holdfast — Product Brief
*Offline survival map: supplies, hazards and off-grid networking.*

## Context
Holdfast is a cross-platform app (desktop, iPhone, Android) that:
1. Shows **offline maps** of supply locations by category: big-box stores (Walmart, Costco, Canadian Tire), grocery, hardware, pharmacies, fuel, water and so on.
2. Lets people **network** with each other while some link still works (Starlink, cell, Wi-Fi), and over mesh radio when nothing does.
3. Lets people **mark hazards** (fire, flood, collapsed bridge, chemical spill). A hazard shows on the map once it is verified, and expires when people mark it cleared or nobody confirms it for a while.

This brief covers why the product is shaped the way it is, what makes it useful, how it makes money, and the technical architecture. Work is tracked as GitHub issues.

---

## 1. The key strategic point: make it useful on an ordinary Tuesday
An app that only helps in an apocalypse never gets opened, so it is not installed, updated or downloaded for offline use when the day comes. The same features also serve **disasters that happen every year**: hurricanes, wildfires, ice storms, floods, earthquakes, long power outages, evacuations. Lead with these and keep the "end of the world" angle for marketing to preppers.
- Growth: every hurricane or wildfire season brings a spike of installs (GasBuddy and Zello both hit #1 in app stores during hurricanes).
- Revenue: governments, insurers and businesses pay for disaster tools. They don't pay for zombie tools.
- Store approval: "emergency preparedness" passes App Store and Play review easily. "Where to loot" does not. Never present stores as places to take things from.

---

## 2. Features that make it useful

### A. Offline maps and resources (the core)
- **Downloadable regions** (province, state or metro area) of vector tiles. Kept small: a typical province or state is roughly 100–600 MB.
- **Categories** come from OpenStreetMap tags, with brand names attached through the OSM *name-suggestion-index*:
  - Food: supermarket, hypermarket, warehouse club, convenience store
  - Tools and hardware: hardware stores, Canadian Tire, Home Depot, farm supply (TSC), sporting and outdoor (fishing, hunting, camping)
  - Medical: pharmacy, hospital, clinic, vet (which also stocks medical supplies)
  - Water: drinking fountains, springs, wells, rivers and lakes, with purification notes
  - Fuel and energy: gas stations, propane refills, EV chargers
  - Shelter and safety: official shelters, community centres, schools, fire, police, ranger stations
  - Communications: amateur radio repeaters, NOAA / Weather Radio Canada transmitters, public Wi-Fi
  - Land and food: farms, orchards, community gardens, hunting and fishing zones
- **Search, filter and "nearest N"** all work offline. GPS needs no internet, which is worth stating loudly in marketing.
- **Offline routing** for walking, cycling and driving, which can **route around active hazards**.
- **Status per place**, crowd-reported: open / closed / out of stock / limited stock / generator power / dangerous. Each status carries a timestamp and a confidence level. This is GasBuddy's hurricane mode applied to everything.

### B. Hazard reporting with verification and expiry
- **Report**: a type (fire, flood, road blocked, downed power lines, gas leak, structural collapse, unrest, contaminated water) and its geometry: a point, a line for a road, or a hand-drawn polygon for a fire perimeter. Photo is optional.
- **Verification score**, recomputed as reports come in:
  - independent confirmations from different users and devices close to the hazard (weighted by GPS proximity)
  - the reporter's reputation, built from past reports that turned out accurate
  - matches against official feeds, which verify automatically: USGS earthquakes, NWS/NOAA alerts, Environment Canada, NASA FIRMS fire hotspots, GDACS, provincial and state 511 road closures
  - photo with intact metadata
  - Statuses: *Unverified* (faint, opt-in layer) → *Verified* (shown to everyone) → *Disputed* → *Cleared*.
- **Expiry**: each hazard type has a default lifetime (roadblock 12 h, flood 72 h, wildfire 7 d, chemical spill 48 h). Any "still there" confirmation resets the clock. Several "it's gone" votes clear the hazard early. Expired hazards move to a history layer, which later becomes valuable data.
- **Geofenced alerts**: "a verified hazard appeared within 5 km of you or of a saved place."

### C. Networking: the real differentiator
Starlink by itself is just internet. If it works, a normal server works. The hard and valuable case is **when the internet doesn't work**, so build the communication layer in tiers that degrade gracefully:
1. **Internet** (cell, Wi-Fi, Starlink dish): full sync with the server.
2. **Satellite direct-to-cell** (Starlink direct-to-cell, Apple satellite features): a very low bandwidth, intermittent link. Design a compact binary message format (a few hundred bytes per hazard or check-in) so sync still works over thin pipes. Partnering with carriers' satellite-enabled app programs is a stretch goal.
3. **Phone-to-phone mesh**: Bluetooth LE plus Wi-Fi Direct / Wi-Fi Aware. Messages and hazard reports hop between phones and are stored and forwarded (Bridgefy and Briar work this way). Expect range of about 50–100 m per hop. iOS limits background Bluetooth, so mesh works best with the app open.
4. **LoRa radio via Meshtastic**: pair the app over Bluetooth with a cheap Meshtastic node ($30–60), which reaches several kilometres per hop with no infrastructure. **This is the strongest selling point**, and it is also a hardware revenue line (see section 3).

Every record (hazard, status, message) is a signed, timestamped event. Devices merge events whenever they touch any network: *offline-first, sync-whenever*.

Social features:
- **Groups**: family or neighbourhood, with an "I'm safe / need help" check-in, rally points and a last-known position (shared only inside the group).
- **Skills and needs board** (opt-in): "nurse, 2 km away", "need insulin", "have generator power". Positions are fuzzed to about 1 km.
- **Broadcast channel** for verified local authorities and CERT teams.

### D. Everyday features that keep the app opened
- **Stockpile tracker**: food, water, meds and batteries, with expiry reminders and "you have X days of food for Y people". This is the main reason to open the app weekly.
- **Go-bag and readiness checklist** with a readiness score, by region and season ("hurricane season starts in 3 weeks").
- **Offline survival library**: first aid, water purification, fire, shelter, regional edible and poisonous plants, how to shut off gas, radio frequencies. Bundle only documents whose licences allow redistribution.
- **Family emergency plan**: contacts, meeting points, medical info card (readable from the lock screen).
- **Tools**: compass, sunrise and sunset, a "daylight left" timer, a signal mirror / SOS flashlight, a battery-saver mode.
- **Local drills**: "Practice: walk your evacuation route this weekend."

### E. Safety and abuse risks (must be designed in from day one)
- **Lure attacks**: a bad actor posts "free supplies here" to ambush people. Low-reputation reports of *resources* get the same verification gate as hazards, and the UI shows warnings.
- **Location privacy**: never expose an individual's exact position publicly. Fuzz it, keep precise location inside groups only, and auto-delete position history.
- **Panic and false information**: rate limits, reputation, moderator tools, official sources marked clearly.
- **Liability**: "information may be outdated; follow official instructions" disclaimers, and no medical claims beyond standard first-aid content.
- **Trademarks**: naming "Walmart" or "Canadian Tire" on a map pin is fine (nominative use). Don't use their logos and don't imply partnership unless one is signed.

---

## 3. Ways to make money (ranked by fit)
1. **Freemium plus "Lifetime" licence** (the core)
   - Free: one offline region, basic categories, viewing and reporting hazards.
   - Premium at about $5/mo or $40/yr: unlimited regions, terrain and topo maps, offline satellite imagery, hazard-aware routing, groups larger than 2, stockpile tracker sync, alert radius control.
   - **Lifetime at $99–149**: preppers distrust subscriptions that need a server to be alive. Promise that offline features keep working if the company disappears. This is a real selling point and brings in early cash.
2. **Hardware bundles**: pre-flashed Meshtastic LoRa nodes branded for the app, solar chargers and go-bag kits. Bundle with lifetime licences. A Kickstarter campaign fits this product unusually well.
3. **Affiliate gear recommendations**: readiness checklist items link to gear (Amazon, outdoor retailers, prepper suppliers). Readiness content drives purchase intent naturally.
4. **B2G / B2B licensing (the biggest contracts)**
   - Municipal and county emergency management: a dashboard of crowd hazard reports, the ability to push verified alerts, shelter status management. Annual SaaS of $5k–100k per agency.
   - CERT teams, the Red Cross, NGOs and search-and-rescue: team accounts.
   - Businesses: employee safety check-in and business continuity (a competitor to AlertMedia and Everbridge, at a lower price).
   - Insurers: offer the app to policyholders (risk reduction) and license aggregated, anonymised hazard history.
5. **Retail "Verified Supply Partner" programme**: chains pay to publish real-time open / closed / stock status during disasters (Home Depot and Walmart already run disaster operations centres). Label it clearly and **never show ads in emergency mode**.
6. **Paid content packs**: regional foraging guides, an advanced medical pack, courses and certifications, possibly with partner instructors.
7. **Grants and public funding**: FEMA / BRIC, Public Safety Canada, humanitarian innovation funds (UNICEF Venture Fund, Mozilla). These are non-dilutive money for the mesh and civic features.
8. **Data products, done carefully**: aggregated, anonymised hazard and outage timelines for researchers, insurers and utilities. Never sell individual location data, which would destroy trust and invite regulation.
9. *Avoid*: heavy ad networks and selling precise location data. Both erode trust, which is the product's whole value.

---

## 4. Recommended technical architecture
| Layer | Choice | Why |
|---|---|---|
| App (iOS, Android, desktop, web) | **Flutter** (one codebase builds for iOS, Android, Windows, macOS, Linux and web) | True single codebase including desktop. Good BLE plugins. |
| Map rendering | **flutter_map + vector_map_tiles** (pure Dart) | Open source, no per-view fees, renders offline vector tiles on *every* Flutter platform. `maplibre_gl` was considered but has no desktop support. |
| Map data | **OpenStreetMap** → **Protomaps PMTiles** region files, hosted on cheap object storage (Cloudflare R2) | Free data. One file per region is easy to download. Note: the ODbL licence requires attribution, and modified databases must be shared under the same licence. |
| POI database on the device | Compact JSON pack per region (MVP) → **SQLite** with R-tree + FTS5 once packs outgrow memory | Instant offline search and "nearest" queries. |
| Routing on the device | GraphHopper or Valhalla offline tiles (phase 2) | Offline routing that can avoid hazards. |
| Backend | **Go** API with a pluggable event store (in-memory for dev, **PostgreSQL + PostGIS** in production) | Spatial queries, feed ingestion. Hazard *scoring* runs on clients so mesh peers reach the same answer offline. |
| Sync model | Append-only signed event log (each device has an Ed25519 key) with idempotent merge | The same records travel over internet, satellite, BLE mesh or LoRa. |
| Mesh | BLE / Wi-Fi Direct store-and-forward, plus the **Meshtastic BLE protocol** (protobuf) | Communication with no infrastructure. |
| Official feeds | Scheduled ingest jobs: USGS, NWS CAP, Environment Canada, NASA FIRMS, GDACS | Automatic verification and immediate value at launch. |

Not Google Maps: its terms forbid caching its data for offline use.

### Look and feel: animated, with light and dark themes
- **Theme system**: Material 3 with `ColorScheme.fromSeed` and a custom "tactical" palette: deep slate and amber accent in dark, warm sand and forest green in light. Three modes: **System / Light / Dark**, plus a fourth, **Night-vision red**: an all-red, low-brightness theme that preserves night vision and saves battery on OLED screens. It is both useful and a strong visual signature.
- **Theme switch animation**: a circular reveal that spreads out from the toggle button (a captured screenshot overlay with a clip animation), so the switch feels instant and polished.
- **Matching map styles**: Protomaps basemap flavours (light, dark, and a custom red style for night vision) swap together with the app theme. Map fades between styles instead of flashing.
- **Map animations**:
  - Hazard markers pulse with expanding rings; colour and speed follow severity.
  - Verified hazards "lock in" with a short scale-and-glow when they cross the verification threshold.
  - Expiring hazards fade out over their last hour.
  - "Nearest supplies" shows a radar-sweep from the user's location, then markers drop in one after another.
  - Hand-drawn hazard polygons animate their outline (a marching-ants dash).
- **App animations**: `flutter_animate` for entrance and stagger effects, Hero transitions from map pin to place detail, animated bottom sheets, shimmer placeholders while regions load, and a progress ring with a percentage for region downloads. **Rive** (or Lottie) for a few illustrated moments: onboarding, the empty stockpile, and "you're safe" check-in confirmation.
- **Haptics**: light taps on confirm and a distinct pattern for a new nearby hazard alert.
- **Respect the context**: honour the OS "reduce motion" setting. **Battery-saver / emergency mode** switches off non-essential animations automatically and drops the map to a static, low-power dark style. Looking cool must never cost battery when it matters.

---

## 5. Phased roadmap
- **Phase 1, MVP (about 8–12 weeks solo)**: offline region download, POI categories and search, hazard reporting with expiry, official feed overlay, basic accounts. Android plus desktop first. iOS follows from the same Flutter code.
- **Phase 2**: verification and reputation, place status reports, groups with check-ins, stockpile tracker, premium paywall plus the lifetime licence.
- **Phase 3**: BLE mesh and Meshtastic integration, compact satellite-friendly sync, hazard-aware offline routing.
- **Phase 4**: agency and business dashboard (B2G/B2B), retail partner programme, hardware bundle and Kickstarter.
