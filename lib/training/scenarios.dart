/// The training scenarios. Each is set around the centre of whatever map
/// the player has open, so it works in any city.
library;

import 'package:material_ui/material_ui.dart';

import '../contamination/contaminants.dart';
import '../hazards/hazard.dart';
import '../hazards/hazard_details.dart';
import '../pois/poi.dart';
import 'scenario.dart';

Duration _s(int seconds) => Duration(seconds: seconds);

final scenarios = <Scenario>[
  Scenario(
    id: 'iceStorm',
    title: 'Ice storm',
    icon: Icons.ac_unit_rounded,
    briefing: 'Freezing rain has coated the city in ice. Branches and power lines are coming down, '
        'and the power is out in your neighbourhood.',
    lesson: 'Ice storms can cut power for days. Keep three days of water and food, a battery radio, '
        'and a safe way to stay warm. Never run a generator indoors.',
    par: _s(150),
    events: [
      ScriptedReport(
        at: _s(3),
        notice: 'New report nearby: downed power lines.',
        ref: 'lines',
        type: HazardType.powerLines,
        bearing: 20,
        meters: 600,
      ),
      ScriptedVotes(at: _s(20), notice: 'A neighbour confirmed the downed lines.', ref: 'lines', kind: VoteKind.confirm, count: 1),
      ScriptedNotice(at: _s(35), notice: 'Official: warming centres are open in community centres and shelters.'),
    ],
    objectives: [
      confirmA(HazardType.powerLines, 'You can see the lines too: confirm the report ("Still there").'),
      findA(PoiCategory.shelter, 'Find a warming shelter: open one from search or "Nearest supplies".'),
      reportA(HazardType.roadBlocked, 'A fallen tree blocks your street: report a blocked road.'),
    ],
  ),
  Scenario(
    id: 'springFlood',
    title: 'Spring flood',
    icon: Icons.flood_rounded,
    briefing: 'Snowmelt and heavy rain have pushed the river over its banks. Reports are coming in, '
        'and not all of them are right.',
    lesson: 'Never walk or drive through floodwater: 15 cm of moving water can knock you over, '
        '30 cm can float a car. Know your route to higher ground before the water rises.',
    par: _s(150),
    events: [
      ScriptedReport(at: _s(3), notice: 'New report: flooding near the river.', ref: 'flood', type: HazardType.flood, bearing: 200, meters: 900),
      ScriptedVotes(at: _s(12), notice: 'Two neighbours confirmed the flooding.', ref: 'flood', kind: VoteKind.confirm),
      ScriptedReport(
        at: _s(25),
        notice: 'New report: flooding on a hill street. That seems unlikely…',
        ref: 'falseFlood',
        type: HazardType.flood,
        bearing: 40,
        meters: 700,
        severity: HazardSeverity.moderate,
      ),
    ],
    objectives: [
      confirmA(HazardType.flood, 'Confirm the river flooding you can see.'),
      clearA(HazardType.flood, 'The hill street is dry: mark that report "It\'s gone".'),
      routeAround('Plan a route that goes around the flooding (Directions from any place).'),
    ],
  ),
  Scenario(
    id: 'wildfireSmoke',
    title: 'Wildfire smoke',
    icon: Icons.local_fire_department_rounded,
    briefing: 'A wildfire is burning outside town. The wind is picking up and smoke is drifting in.',
    lesson: 'Keep a go-bag by the door in fire season, with N95 masks, medicines and copies of documents. '
        'Leave early: roads jam once an evacuation order comes.',
    par: _s(150),
    events: [
      ScriptedReport(
        at: _s(3),
        notice: 'New report: wildfire, wind from the west.',
        ref: 'fire',
        type: HazardType.fire,
        bearing: 270,
        meters: 2500,
        severity: HazardSeverity.extreme,
        details: {'wind': {'from': 270.0, 'kmh': 20.0, 'source': 'forecast'}},
      ),
      ScriptedVotes(at: _s(15), notice: 'Others confirmed the fire.', ref: 'fire', kind: VoteKind.confirm),
      ScriptedNotice(at: _s(30), notice: 'Official: be ready to leave. Keep water with you.'),
    ],
    objectives: [
      filterTo(HazardCategory.fire, 'Too much on the map? Filter the hazards list to Fire & explosion.'),
      findA(PoiCategory.water, 'Find drinking water to take with you.'),
      routeAround('Plan a route that keeps out of the smoke plume.'),
    ],
  ),
  Scenario(
    id: 'chemicalSpill',
    title: 'Chemical spill',
    icon: Icons.science_rounded,
    briefing: 'A rail tanker has leaked near the station. A chemical smell is spreading downwind.',
    lesson: 'To shelter in place: go inside, close windows and doors, turn off fans and air conditioning, '
        'and seal gaps with wet towels or tape. Keep a radio on for the all-clear.',
    par: _s(120),
    events: [
      ScriptedReport(
        at: _s(3),
        notice: 'New report: chemical spill, wind from the north.',
        ref: 'spill',
        type: HazardType.chemicalSpill,
        bearing: 0,
        meters: 1200,
        details: {'wind': {'from': 0.0, 'kmh': 12.0, 'source': 'forecast'}},
      ),
      ScriptedVotes(at: _s(10), notice: 'Others confirmed the spill.', ref: 'spill', kind: VoteKind.confirm),
    ],
    objectives: [
      open(HazardType.chemicalSpill, 'Open the spill report: how far is it likely to spread?'),
      routeAround('Plan a route that avoids the spill and its plume.'),
      reportA(HazardType.gasLeak, 'You smell gas on your street too: report a gas leak.'),
    ],
  ),
  Scenario(
    id: 'radiationAlert',
    title: 'Radiation alert',
    icon: Icons.warning_amber_rounded,
    briefing: 'An accident at an industrial site has released radioactive material. '
        'A neighbour with a meter reports high readings.',
    lesson: 'Get inside, stay inside, stay tuned. A basement or the middle of a large building cuts '
        'your dose the most. Keep potassium iodide only if officials tell you to take it.',
    par: _s(120),
    events: [
      ScriptedReport(
        at: _s(3),
        notice: 'New report: HIGH radiation nearby.',
        ref: 'rad',
        type: HazardType.radiation,
        bearing: 120,
        meters: 1500,
        details: {
          'radiation': {'level': 'high', 'uSvH': 85.0},
          'wind': {'from': 300.0, 'kmh': 15.0, 'source': 'forecast'},
        },
      ),
      ScriptedVotes(at: _s(10), notice: 'Others confirmed the readings.', ref: 'rad', kind: VoteKind.confirm),
    ],
    objectives: [
      open(HazardType.radiation, 'Open the radiation report and read what to do.'),
      filterTo(HazardCategory.chemical, 'Shortlist the map to Chemical & radiological hazards.'),
      findA(PoiCategory.shelter, 'Find the nearest shelter.'),
    ],
  ),
  Scenario(
    id: 'nuclearDrill',
    title: 'Nuclear detonation drill',
    icon: Icons.brightness_7_rounded,
    briefing: 'A drill: a 15 kt ground burst has been reported 6 km away. Read what the rings mean '
        'and get yourself to safety.',
    lesson: 'If you see a flash: get down and cover your head. Then get inside the most solid building '
        'nearby within minutes: fallout arrives in 10 to 30 minutes. Stay in for at least 24 hours.',
    par: _s(150),
    events: [
      ScriptedReport(
        at: _s(3),
        notice: 'ALERT: nuclear detonation reported.',
        ref: 'blast',
        type: HazardType.nuclearDetonation,
        bearing: 315,
        meters: 6000,
        severity: HazardSeverity.extreme,
        details: {
          'nuclear': {'kt': 15.0, 'preset': 'hiroshima', 'burst': 'surface'},
          'wind': {'from': 315.0, 'kmh': 20.0, 'source': 'forecast'},
        },
      ),
      ScriptedVotes(at: _s(8), notice: 'Officials confirmed the detonation.', ref: 'blast', kind: VoteKind.confirm, count: 3),
    ],
    objectives: [
      readRings('Open the detonation and read its rings (try both views).'),
      findA(PoiCategory.medical, 'Find medical help for the injured.'),
      routeAround('Plan a route that keeps out of the rings and the fallout.'),
    ],
  ),
  Scenario(
    id: 'tsunamiWarning',
    title: 'Tsunami warning',
    icon: Icons.tsunami_rounded,
    briefing: 'A strong earthquake offshore. A tsunami is possible within the hour.',
    lesson: 'If the ground shakes hard near the coast, go to high ground or inland at once. Don\'t wait '
        'for a warning, and don\'t go to the shore to watch. Several waves come over hours.',
    par: _s(100),
    events: [
      ScriptedReport(at: _s(3), notice: 'New report: tsunami expected.', ref: 'wave', type: HazardType.tsunami, bearing: 90, meters: 2000, severity: HazardSeverity.extreme),
      ScriptedVotes(at: _s(8), notice: 'Officials confirmed the warning.', ref: 'wave', kind: VoteKind.confirm, count: 3),
    ],
    objectives: [
      open(HazardType.tsunami, 'Open the tsunami report and read what to do.'),
      routeAround('Plan a walking route away from the danger zone.'),
    ],
  ),
  // Modelled on the U.S. Army's November 2026 detonation of degraded lead
  // azide at the Iowa Army Ammunition Plant: a planned release, a
  // downwind evacuation cone, shelter in place beyond it, and lead that
  // settles into soil for decades.
  Scenario(
    id: 'leadDustRelease',
    title: 'Lead dust release',
    icon: Icons.grain_rounded,
    briefing: 'The army is about to detonate an old store of lead-based explosive 3 km north-east of you. '
        'The wind will carry lead dust your way for tens of kilometres.',
    lesson: 'For lead dust: shelter in place with windows shut and ventilation on recirculate, and keep '
        'children under 6 and pregnant women inside. Afterwards wet-clean, never sweep, and test the soil '
        'before children play or you grow food. A blood lead test shows exposure from about the past month.',
    par: _s(180),
    events: [
      ScriptedReport(
        at: _s(3),
        notice: 'Planned: a controlled detonation of lead-based explosive, upwind of you.',
        ref: 'lead',
        type: HazardType.leadDust,
        bearing: 45,
        meters: 3000,
        details: {
          'wind': {'from': 45.0, 'kmh': 13.0, 'source': 'forecast'},
        },
      ),
      ScriptedVotes(at: _s(6), notice: 'Officials confirmed the release.', ref: 'lead', kind: VoteKind.confirm, count: 3),
      ScriptedNotice(at: _s(25), notice: 'The detonation has happened. Dust is drifting your way: shelter in place.'),
      // Neighbours' soil tests: high along the plume, low upwind and to the side.
      ScriptedSample(at: _s(40), notice: 'Neighbours have tested their soil. Readings are on the map.',
          contaminant: Contaminant.lead, value: 1400, bearing: 45, meters: 2200),
      ScriptedSample(at: _s(40), notice: 'Neighbours have tested their soil. Readings are on the map.',
          contaminant: Contaminant.lead, value: 850, bearing: 45, meters: 1400),
      ScriptedSample(at: _s(40), notice: 'Neighbours have tested their soil. Readings are on the map.',
          contaminant: Contaminant.lead, value: 310, bearing: 50, meters: 600),
      ScriptedSample(at: _s(40), notice: 'Neighbours have tested their soil. Readings are on the map.',
          contaminant: Contaminant.lead, value: 70, bearing: 135, meters: 1200),
      ScriptedSample(at: _s(40), notice: 'Neighbours have tested their soil. Readings are on the map.',
          contaminant: Contaminant.lead, value: 40, bearing: 225, meters: 900),
    ],
    objectives: [
      open(HazardType.leadDust, 'Open the release and see where the dust will drift.'),
      findMe('Find your own location on the map.'),
      routeAround('Plan a route that keeps out of the dust plume.'),
      openReading("Open a neighbour's soil reading and read what it means."),
      addReading(Contaminant.lead, 'Test your own yard: add a lead reading where you are.'),
    ],
  ),
  Scenario(
    id: 'unrestInjuries',
    title: 'Unrest and injuries',
    icon: Icons.personal_injury_rounded,
    briefing: 'A protest has turned violent downtown. People are hurt, and police are closing streets.',
    lesson: 'Learn basic first aid: firm pressure on bleeding saves lives. Keep a first aid kit at home '
        'and in the car, and know two ways out of your neighbourhood.',
    par: _s(120),
    events: [
      ScriptedReport(at: _s(3), notice: 'New report: unrest downtown.', ref: 'unrest', type: HazardType.unrest, bearing: 180, meters: 800),
      ScriptedVotes(at: _s(12), notice: 'Others confirmed the unrest.', ref: 'unrest', kind: VoteKind.confirm),
    ],
    objectives: [
      reportA(HazardType.police, 'Police are closing your street: report police activity.'),
      reportA(HazardType.peopleHurt, 'Someone is hurt at the corner: report people hurt.'),
      findA(PoiCategory.medical, 'Find the nearest medical help.'),
    ],
  ),
];

/// Scenario details are stored as plain JSON; check they parse as the
/// typed details the map expects (a typo would silently draw no rings).
bool scenarioDetailsParse() {
  for (final s in scenarios) {
    for (final e in s.events) {
      if (e is! ScriptedReport) continue;
      final h = Hazard(
        id: 'x',
        type: e.type,
        severity: e.severity,
        latitude: 0,
        longitude: 0,
        reportedBy: 'x',
        reportedAt: DateTime.utc(2026),
        details: e.details,
      );
      if (e.details.containsKey('wind') && h.wind == null) return false;
      if (e.details.containsKey('nuclear') && h.nuclear == null) return false;
      if (e.details.containsKey('radiation') && h.radiation == null) return false;
    }
  }
  return true;
}
