/// Hazard data model: what people report, and the votes that verify or clear
/// a report.
///
/// This file is deliberately free of Flutter imports. The same rules have to
/// give the same answer on a phone, on a desktop and (later) on a mesh peer
/// with no server in reach, so the model is plain Dart that the test suite
/// can exercise with a fake clock.
library;

/// How hazards are grouped, so a report starts with "what kind of thing"
/// and a map can be filtered down to what matters to you.
enum HazardCategory {
  fire('Fire & explosion'),
  water('Water & weather'),
  transport('Roads & buildings'),
  utilities('Utilities'),
  chemical('Chemical & radiological'),
  geological('Volcanic & geological'),
  people('People & security'),
  other('Other');

  const HazardCategory(this.label);
  final String label;

  List<HazardType> get types => [for (final t in HazardType.values) if (t.category == this) t];
}

/// The kinds of hazard people can report, each with a default lifetime.
///
/// The lifetime is how long a report stays on the map after the last sign of
/// life (the original report or the latest "still there" confirmation). A
/// roadblock is usually gone within hours; a lava flow for weeks; fallout
/// and radiation for longer than any of them.
///
/// The names are stored in synced events, so they never change; new types
/// are only ever added.
enum HazardType {
  fire('Fire', Duration(days: 7), HazardCategory.fire),
  flood('Flood', Duration(hours: 72), HazardCategory.water),
  roadBlocked('Road blocked', Duration(hours: 12), HazardCategory.transport),
  powerLines('Downed power lines', Duration(hours: 24), HazardCategory.utilities),
  gasLeak('Gas leak', Duration(hours: 12), HazardCategory.utilities),
  chemicalSpill('Chemical spill', Duration(hours: 48), HazardCategory.chemical),
  structuralCollapse('Structural collapse', Duration(days: 7), HazardCategory.transport),
  unrest('Unrest', Duration(hours: 6), HazardCategory.people),
  contaminatedWater('Contaminated water', Duration(days: 5), HazardCategory.water),
  police('Police activity', Duration(hours: 6), HazardCategory.people),
  peopleHurt('People hurt', Duration(hours: 6), HazardCategory.people),
  volcanicAsh('Volcanic ash', Duration(days: 3), HazardCategory.geological),
  lava('Lava flow', Duration(days: 14), HazardCategory.geological),
  tsunami('Tsunami', Duration(hours: 24), HazardCategory.water),
  nuclearDetonation('Nuclear detonation', Duration(days: 30), HazardCategory.chemical),
  radiation('Radiation', Duration(days: 14), HazardCategory.chemical),

  /// A type this version of the app doesn't know (sent by a newer one).
  /// Shown as a generic hazard rather than mislabelled.
  other('Other hazard', Duration(hours: 12), HazardCategory.other);

  const HazardType(this.label, this.lifetime, this.category);

  final String label;
  final Duration lifetime;
  final HazardCategory category;

  /// Hazards whose danger drifts with the wind, for which a report can
  /// include wind and the map can draw a spread pattern.
  bool get spreadsWithWind => switch (this) {
        HazardType.fire ||
        HazardType.gasLeak ||
        HazardType.chemicalSpill ||
        HazardType.volcanicAsh ||
        HazardType.nuclearDetonation ||
        HazardType.radiation =>
          true,
        _ => false,
      };

  static HazardType parse(String name) =>
      HazardType.values.firstWhere((t) => t.name == name, orElse: () => HazardType.other);
}

/// How dangerous the reporter judged the hazard to be. Drives marker size,
/// colour and pulse speed.
enum HazardSeverity {
  low('Low'),
  moderate('Moderate'),
  high('High'),
  extreme('Extreme');

  const HazardSeverity(this.label);
  final String label;

  static HazardSeverity parse(String name) =>
      HazardSeverity.values.firstWhere((s) => s.name == name, orElse: () => HazardSeverity.moderate);
}

/// What a vote says about a hazard.
enum VoteKind {
  /// "Still there." Counts towards verification and restarts the lifetime.
  confirm,

  /// "It's gone." Enough of these clear the hazard before it expires.
  clear,
}

/// One device's opinion of a hazard at a point in time.
class HazardVote {
  const HazardVote({
    required this.deviceId,
    required this.kind,
    required this.at,
    this.distanceMeters,
  });

  /// The voting install. Only a device's latest vote counts.
  final String deviceId;
  final VoteKind kind;
  final DateTime at;

  /// How far the voter was from the hazard when voting, if known. Someone
  /// standing next to a flood is better evidence than someone 30 km away.
  final double? distanceMeters;

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'kind': kind.name,
        'at': at.toUtc().toIso8601String(),
        if (distanceMeters != null) 'distanceMeters': distanceMeters,
      };

  factory HazardVote.fromJson(Map<String, Object?> json) => HazardVote(
        deviceId: json['deviceId']! as String,
        kind: VoteKind.values.byName(json['kind']! as String),
        at: DateTime.parse(json['at']! as String),
        distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
      );
}

/// A reported hazard plus every vote it has received.
///
/// Instances are immutable; [withVote] returns a copy. The lifecycle status
/// is *not* stored here: it depends on the current time, so it is computed
/// on demand by `assessHazard` in `hazard_engine.dart`.
class Hazard {
  const Hazard({
    required this.id,
    required this.type,
    required this.severity,
    required this.latitude,
    required this.longitude,
    required this.reportedBy,
    required this.reportedAt,
    this.description = '',
    this.official = false,
    this.votes = const [],
    this.details = const {},
  });

  final String id;
  final HazardType type;
  final HazardSeverity severity;
  final double latitude;
  final double longitude;
  final String description;

  /// Device that filed the report. Its own confirmations never count.
  final String reportedBy;
  final DateTime reportedAt;

  /// True when the hazard came from an official feed (weather service,
  /// earthquake service, road authority). Official hazards are verified
  /// from the start.
  final bool official;

  final List<HazardVote> votes;

  /// Type-specific extras: a nuclear detonation's yield, a radiation
  /// level, the wind. Kept as JSON here and read through the typed views in
  /// `hazard_details.dart`, so unknown keys from newer apps survive a sync.
  final Map<String, Object?> details;

  Hazard withVote(HazardVote vote) => Hazard(
        id: id,
        type: type,
        severity: severity,
        latitude: latitude,
        longitude: longitude,
        description: description,
        reportedBy: reportedBy,
        reportedAt: reportedAt,
        official: official,
        votes: [...votes, vote],
        details: details,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type.name,
        'severity': severity.name,
        'lat': latitude,
        'lon': longitude,
        'description': description,
        'reportedBy': reportedBy,
        'reportedAt': reportedAt.toUtc().toIso8601String(),
        'official': official,
        if (details.isNotEmpty) 'details': details,
        'votes': [for (final v in votes) v.toJson()],
      };

  factory Hazard.fromJson(Map<String, Object?> json) => Hazard(
        id: json['id']! as String,
        type: HazardType.parse(json['type']! as String),
        severity: HazardSeverity.parse(json['severity']! as String),
        latitude: (json['lat']! as num).toDouble(),
        longitude: (json['lon']! as num).toDouble(),
        description: (json['description'] as String?) ?? '',
        reportedBy: json['reportedBy']! as String,
        reportedAt: DateTime.parse(json['reportedAt']! as String),
        official: (json['official'] as bool?) ?? false,
        details: ((json['details'] as Map?) ?? const {}).cast<String, Object?>(),
        votes: [
          for (final v in (json['votes'] as List<Object?>?) ?? const [])
            HazardVote.fromJson((v! as Map).cast<String, Object?>()),
        ],
      );
}
