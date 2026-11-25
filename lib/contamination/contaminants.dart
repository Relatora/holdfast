/// What a soil or ground reading means for people living on it: each
/// contaminant's scale, from a measured number to one of five plain levels
/// and what to do. Plain Dart, so every threshold is unit-tested.
///
/// The five levels read the same everywhere in the app as radiation
/// reports do (Normal, Elevated, High, Very high, Dangerous), so a
/// "Very high" lead sample and a "Very high" radiation report mean the
/// same urgency.
///
/// ## Where the numbers come from
///
/// * **Lead** uses the U.S. EPA's own soil-lead levels: 100 ppm where other
///   lead sources are present and 200 ppm otherwise (EPA residential soil
///   lead guidance, January 2024), 400 ppm (the 2001 EPA/HUD soil-lead
///   hazard standard for play areas) and 1,200 ppm (the same standard for
///   the rest of a yard).
/// * **Other chemicals** start from the EPA Regional Screening Levels for
///   resident soil (November 2024 table, TR=1E-06, THQ=1). Those levels
///   are set at a one-in-a-million lifetime cancer risk, so natural soil
///   often exceeds them for arsenic; grading by them would call an ordinary
///   garden "High". The first step here is instead the lower of the
///   non-cancer level and the level at a one-in-ten-thousand cancer risk
///   (the top of the EPA's acceptable range, 100 times the table's cancer
///   level). Each further step is ten times higher.
/// * **Caesium-137 on the ground** uses the zoning applied after Chernobyl:
///   37 kBq/m² (contaminated), 185 (radiation control), 555 (right to
///   resettle) and 1,480 (compulsory evacuation).
/// * **Dose rate** uses the same bands as radiation reports.
///
/// These are screening levels, not cleanup standards: a reading above one
/// means "find out more and protect people meanwhile", which is what the
/// advice says.
library;

import '../hazards/hazard.dart' show HazardSeverity;

/// How much a reading threatens people, in five steps.
enum ContaminationLevel {
  normal('Normal'),
  elevated('Elevated'),
  high('High'),
  veryHigh('Very high'),
  dangerous('Dangerous');

  const ContaminationLevel(this.label);
  final String label;

  /// The hazard severity this matches, for colours and route avoidance.
  HazardSeverity get severity => switch (this) {
        ContaminationLevel.normal || ContaminationLevel.elevated => HazardSeverity.low,
        ContaminationLevel.high => HazardSeverity.moderate,
        ContaminationLevel.veryHigh => HazardSeverity.high,
        ContaminationLevel.dangerous => HazardSeverity.extreme,
      };

  /// Directions keep away from very high and dangerous ground.
  bool get avoid => index >= ContaminationLevel.veryHigh.index;
}

/// What a reading is measured in.
enum SampleUnit {
  mgPerKg('mg/kg', 'mg/kg (ppm)'),
  kBqPerM2('kBq/m²', 'kBq/m² on the ground'),
  uSvPerH('µSv/h', 'µSv/h dose rate');

  const SampleUnit(this.symbol, this.label);

  /// Short, after a number: "240 mg/kg".
  final String symbol;

  /// Longer, for pickers.
  final String label;
}

/// Whether a contaminant harms over years (chemicals in soil) or can harm
/// quickly (radiation), which changes the advice.
enum Exposure { chronic, radiation }

/// The things a reading can be of, each with its scale.
enum Contaminant {
  lead(
    'Lead',
    SampleUnit.mgPerKg,
    [100, 200, 400, 1200],
    Exposure.chronic,
    Duration(days: 365 * 2),
    'EPA residential soil lead guidance (2024); EPA/HUD soil-lead hazard standard (2001)',
  ),
  arsenic(
    'Arsenic',
    SampleUnit.mgPerKg,
    // Non-cancer level 35 mg/kg (below the 1-in-10,000 cancer level, 68).
    [35, 350, 3500, 35000],
    Exposure.chronic,
    Duration(days: 365 * 2),
    'EPA Regional Screening Levels, resident soil (Nov 2024)',
  ),
  cadmium(
    'Cadmium',
    SampleUnit.mgPerKg,
    // Non-cancer level, dietary: 7.1 mg/kg.
    [7.1, 71, 710, 7100],
    Exposure.chronic,
    Duration(days: 365 * 2),
    'EPA Regional Screening Levels, resident soil (Nov 2024)',
  ),
  mercury(
    'Mercury',
    SampleUnit.mgPerKg,
    // Mercury salts (mercuric chloride), non-cancer: 2.3 mg/kg. Soil tests
    // report total mercury, which is mostly salts.
    [2.3, 23, 230, 2300],
    Exposure.chronic,
    Duration(days: 365 * 2),
    'EPA Regional Screening Levels, resident soil (Nov 2024)',
  ),
  benzene(
    'Benzene',
    SampleUnit.mgPerKg,
    // Non-cancer 82 mg/kg, below the 1-in-10,000 cancer level (120).
    [82, 820, 8200, 82000],
    Exposure.chronic,
    // Benzene evaporates and breaks down within months.
    Duration(days: 180),
    'EPA Regional Screening Levels, resident soil (Nov 2024)',
  ),
  pcbs(
    'PCBs',
    SampleUnit.mgPerKg,
    // High-risk PCBs: cancer level 0.23 mg/kg, so 23 at 1 in 10,000.
    [23, 230, 2300, 23000],
    Exposure.chronic,
    Duration(days: 365 * 2),
    'EPA Regional Screening Levels, resident soil (Nov 2024)',
  ),
  caesium137(
    'Caesium-137 (fallout)',
    SampleUnit.kBqPerM2,
    [37, 185, 555, 1480],
    Exposure.radiation,
    // Half-life 30 years: it stays until removed.
    Duration(days: 365 * 2),
    'Chernobyl contamination zones (37 / 185 / 555 / 1,480 kBq/m²)',
  ),
  doseRate(
    'Radiation dose rate',
    SampleUnit.uSvPerH,
    // The radiation report levels (RadiationLevel) in µSv/h.
    [0.3, 10, 1000, 100000],
    Exposure.radiation,
    // Dose rates fall quickly as short-lived fallout decays and rain
    // washes it away: a reading is a snapshot.
    Duration(days: 14),
    'Holdfast radiation levels (see radiation reports)',
  );

  const Contaminant(this.label, this.unit, this.thresholds, this.exposure, this.lifetime, this.basis);

  final String label;
  final SampleUnit unit;

  /// Where Elevated, High, Very high and Dangerous begin, in [unit].
  final List<double> thresholds;
  final Exposure exposure;

  /// How long a reading stays on the map. Soil contamination lasts; a dose
  /// rate is out of date within days.
  final Duration lifetime;

  /// Where the scale comes from, shown with every reading.
  final String basis;

  static Contaminant? parse(Object? name) => values.asNameMap()[name];

  /// The level a reading of [value] falls in. A reading exactly on a
  /// threshold belongs to the higher level ("at or above 200 ppm").
  ContaminationLevel levelFor(double value) {
    var level = ContaminationLevel.normal;
    for (final (i, threshold) in thresholds.indexed) {
      if (value >= threshold) level = ContaminationLevel.values[i + 1];
    }
    return level;
  }

  /// What to do at [level], in plain words.
  String advice(ContaminationLevel level) => switch ((this, level)) {
        (_, ContaminationLevel.normal) => 'Below the level where action is usually taken.',
        (Contaminant.lead, ContaminationLevel.elevated) =>
          'Keep young children from playing on bare soil here. Wash hands and toys, and leave shoes at the door.',
        (Contaminant.lead, ContaminationLevel.high) =>
          'Above the EPA screening level. Cover bare soil (mulch, grass, gravel); no play or digging, '
              'and don\'t grow food in it. Wet-clean floors.',
        (Contaminant.lead, ContaminationLevel.veryHigh) =>
          'A lead hazard for children. Keep children and pregnant women off it; get blood lead tests '
              'for young children who live here.',
        (Contaminant.lead, ContaminationLevel.dangerous) =>
          'Severe contamination. Keep everyone off it, above all children; it needs professional '
              'cleanup. Get blood lead tests.',
        (_, ContaminationLevel.elevated) when exposure == Exposure.chronic =>
          'Above the level where the EPA looks further. Wash hands and produce; keep children from eating soil.',
        (_, ContaminationLevel.high) when exposure == Exposure.chronic =>
          'Don\'t grow food or let children play here. Cover bare soil and wet-clean dust indoors.',
        (_, ContaminationLevel.veryHigh) when exposure == Exposure.chronic =>
          'Keep off it. Long contact can make people ill. Report it to the local health authority.',
        (_, ContaminationLevel.dangerous) when exposure == Exposure.chronic =>
          'Severe contamination. Leave the area and keep others out until it is assessed.',
        (Contaminant.caesium137, ContaminationLevel.elevated) =>
          'Contaminated ground. Wash produce and keep dust down; follow food restrictions.',
        (Contaminant.caesium137, ContaminationLevel.high) =>
          'Radiation control zone. Limit time outdoors; don\'t eat local produce or game.',
        (Contaminant.caesium137, ContaminationLevel.veryHigh) =>
          'Long-term living here is not advised. Follow resettlement guidance.',
        (Contaminant.caesium137, ContaminationLevel.dangerous) =>
          'Compulsory evacuation zone after Chernobyl. Leave, and do not return to live.',
        (_, ContaminationLevel.elevated) => 'Limit time outdoors. Stay informed.',
        (_, ContaminationLevel.high) => 'Shelter indoors, away from windows. Close vents.',
        (_, ContaminationLevel.veryHigh) =>
          'Shelter in a basement or the middle of a large building. Follow evacuation orders.',
        (_, ContaminationLevel.dangerous) => 'Leave the area now, or take the deepest shelter you can reach.',
      };

  /// "240 mg/kg", "1.2 µSv/h".
  String format(double value) {
    final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    var text = value.toStringAsFixed(digits);
    // "1.20" → "1.2", "3.00" → "3"; whole numbers ("240") are left alone.
    if (text.contains('.')) text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return '$text ${unit.symbol}';
  }
}

/// How a reading was taken. A lab result is worth more than a home kit,
/// and the details sheet says which it is.
enum SampleMethod {
  lab('Lab test'),
  xrf('Handheld XRF'),
  kit('Home test kit'),
  meter('Radiation meter');

  const SampleMethod(this.label);
  final String label;

  static SampleMethod parse(Object? name) => values.asNameMap()[name] ?? SampleMethod.kit;
}
