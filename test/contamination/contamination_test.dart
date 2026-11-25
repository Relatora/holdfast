import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/contamination/contaminants.dart';
import 'package:holdfast/contamination/interpolation.dart';
import 'package:holdfast/contamination/sample.dart';
import 'package:holdfast/hazards/hazard.dart';
import 'package:holdfast/hazards/hazard_details.dart' show RadiationLevel;
import 'package:holdfast/hazards/hazard_events.dart';

final _t0 = DateTime.utc(2026, 11, 25, 16);

Sample _sample(String id, double value, {double lat = 40.80, double lon = -91.26, Contaminant c = Contaminant.lead}) =>
    Sample(
      id: id,
      contaminant: c,
      value: value,
      method: SampleMethod.lab,
      latitude: lat,
      longitude: lon,
      reportedBy: 'reporter',
      reportedAt: _t0,
    );

HazardEvent _event(Sample s, [String? eventId]) => HazardEvent.sample(
      eventId ?? 'e-${s.id}',
      sampleId: s.id,
      deviceId: s.reportedBy,
      at: s.reportedAt,
      payload: s.toJson(),
    );

HazardEvent _vote(String sampleId, String device, VoteKind kind, {int minutes = 10}) => HazardEvent.vote(
      'v-$sampleId-$device-${kind.name}',
      sampleId,
      HazardVote(deviceId: device, kind: kind, at: _t0.add(Duration(minutes: minutes))),
    );

void main() {
  group('lead uses the EPA and HUD soil-lead levels', () {
    test('each threshold starts its level', () {
      const lead = Contaminant.lead;
      expect(lead.levelFor(99), ContaminationLevel.normal);
      expect(lead.levelFor(100), ContaminationLevel.elevated, reason: 'EPA, with other lead sources');
      expect(lead.levelFor(199), ContaminationLevel.elevated);
      expect(lead.levelFor(200), ContaminationLevel.high, reason: 'EPA residential screening level (2024)');
      expect(lead.levelFor(201), ContaminationLevel.high);
      expect(lead.levelFor(400), ContaminationLevel.veryHigh, reason: 'play-area hazard standard');
      expect(lead.levelFor(1200), ContaminationLevel.dangerous, reason: 'rest-of-yard hazard standard');
    });

    test('advice speaks to children, not just numbers', () {
      expect(Contaminant.lead.advice(ContaminationLevel.veryHigh), contains('children'));
      expect(Contaminant.lead.advice(ContaminationLevel.normal), isNotEmpty);
    });
  });

  test('chemicals start at the EPA level that calls for action, not one-in-a-million', () {
    // Ordinary garden soil holds a few mg/kg of arsenic: not an alarm.
    expect(Contaminant.arsenic.levelFor(8), ContaminationLevel.normal);
    expect(Contaminant.arsenic.levelFor(35), ContaminationLevel.elevated);
    expect(Contaminant.cadmium.levelFor(7.1), ContaminationLevel.elevated);
    expect(Contaminant.cadmium.levelFor(71), ContaminationLevel.high);
    expect(Contaminant.mercury.levelFor(2300), ContaminationLevel.dangerous);
    expect(Contaminant.pcbs.levelFor(22.9), ContaminationLevel.normal);
    for (final c in Contaminant.values) {
      expect(c.thresholds, hasLength(4));
      for (var i = 1; i < 4; i++) {
        expect(c.thresholds[i], greaterThan(c.thresholds[i - 1]), reason: '$c rises');
      }
    }
  });

  test('caesium-137 on the ground follows the Chernobyl zones', () {
    const cs = Contaminant.caesium137;
    expect(cs.levelFor(36), ContaminationLevel.normal);
    expect(cs.levelFor(37), ContaminationLevel.elevated);
    expect(cs.levelFor(555), ContaminationLevel.veryHigh);
    expect(cs.levelFor(1479), ContaminationLevel.veryHigh);
    expect(cs.levelFor(1480), ContaminationLevel.dangerous, reason: 'compulsory evacuation');
    expect(cs.advice(ContaminationLevel.dangerous), contains('evacuation'));
  });

  test('a dose-rate reading agrees with radiation reports', () {
    for (final reading in <double>[0.1, 0.3, 5, 10, 999, 1000, 50000, 100000, 1e6]) {
      expect(
        Contaminant.doseRate.levelFor(reading).index,
        RadiationLevel.forReading(reading).index,
        reason: '$reading µSv/h',
      );
    }
  });

  test('readings are written plainly', () {
    expect(Contaminant.lead.format(240), '240 mg/kg');
    expect(Contaminant.lead.format(1200), '1200 mg/kg');
    expect(Contaminant.doseRate.format(1.20), '1.2 µSv/h');
    expect(Contaminant.cadmium.format(7.1), '7.1 mg/kg');
    expect(Contaminant.caesium137.format(3), '3 kBq/m²');
  });

  group('samples in the event log', () {
    test('round-trip, keep the earliest of duplicates, and attach votes in any order', () {
      final a = _sample('a', 420);
      final events = [
        _vote('a', 'neighbour', VoteKind.confirm),
        _event(a),
        _event(a), // the same event twice
        HazardEvent.report('r1', Hazard(
          id: 'h1',
          type: HazardType.leadDust,
          severity: HazardSeverity.high,
          latitude: 40.8,
          longitude: -91.26,
          reportedBy: 'x',
          reportedAt: _t0,
        )),
      ];
      final samples = foldSamples(events);
      expect(samples.keys, ['a'], reason: 'hazard reports are not samples');
      final folded = samples['a']!;
      expect(folded.value, 420);
      expect(folded.level, ContaminationLevel.veryHigh);
      expect(folded.votes, hasLength(1));
      expect(foldHazardEvents(events).keys, ['h1'], reason: 'and samples are not hazards');
    });

    test('a contaminant from a newer app, or a malformed payload, is skipped', () {
      final odd = HazardEvent.sample('e', sampleId: 's', deviceId: 'd', at: _t0,
          payload: {'contaminant': 'plutonium', 'value': 1, 'lat': 0, 'lon': 0, 'reportedAt': '2026-11-25T16:00:00Z'});
      final broken = HazardEvent.sample('f', sampleId: 't', deviceId: 'd', at: _t0, payload: {'contaminant': 'lead'});
      expect(foldSamples([odd, broken]), isEmpty);
    });

    test('event JSON survives the trip to the server and back', () {
      final e = _event(_sample('a', 150));
      final back = HazardEvent.tryFromJson(e.toJson())!;
      expect(back.kind, HazardEventKind.sample);
      expect(back.latitude, 40.80, reason: 'top-level lat lets the server filter by area');
      expect(foldSamples([back])['a']!.value, 150);
      expect(HazardEventKind.supported, contains('sample'));
    });
  });

  group('assessing a sample', () {
    Sample withVotes(List<HazardEvent> votes) => foldSamples([_event(_sample('a', 420)), ...votes])['a']!;
    final now = _t0.add(const Duration(hours: 1));

    test('one "looks wrong" disputes it; two outweighing agreement reject it', () {
      expect(assessSample(withVotes([]), now), SampleStatus.shown);
      expect(assessSample(withVotes([_vote('a', 'b', VoteKind.clear)]), now), SampleStatus.disputed);
      expect(
        assessSample(withVotes([_vote('a', 'b', VoteKind.clear), _vote('a', 'c', VoteKind.clear)]), now),
        SampleStatus.rejected,
      );
      expect(
        assessSample(
          withVotes([
            _vote('a', 'b', VoteKind.clear),
            _vote('a', 'c', VoteKind.clear),
            _vote('a', 'd', VoteKind.confirm),
            _vote('a', 'e', VoteKind.confirm),
          ]),
          now,
        ),
        SampleStatus.disputed,
        reason: 'as many back it up',
      );
    });

    test("the reporter can't vote on their own sample, and a trusted voter counts more", () {
      expect(assessSample(withVotes([_vote('a', 'reporter', VoteKind.clear)]), now), SampleStatus.shown);
      final one = withVotes([_vote('a', 'trusted', VoteKind.clear)]);
      expect(assessSample(one, now, reputation: (d) => d == 'trusted' ? 2.0 : 1.0), SampleStatus.rejected);
    });

    test('a soil reading lasts two years; a dose rate two weeks', () {
      final soil = _sample('s', 420);
      expect(assessSample(soil, _t0.add(const Duration(days: 700))), SampleStatus.shown);
      expect(assessSample(soil, _t0.add(const Duration(days: 731))), SampleStatus.expired);
      final dose = _sample('d', 50, c: Contaminant.doseRate);
      expect(assessSample(dose, _t0.add(const Duration(days: 15))), SampleStatus.expired);
    });
  });

  group('estimated zones', () {
    // A line of lead samples about 300 m apart, worst at the west end.
    final line = [
      _sample('1', 1500, lon: -91.270),
      _sample('2', 600, lon: -91.266),
      _sample('3', 250, lon: -91.262),
      _sample('4', 60, lon: -91.258),
    ];

    test('need at least three samples of one contaminant', () {
      expect(estimateZones(line.take(2)), isEmpty);
      expect(estimateZones([
        _sample('a', 500),
        _sample('b', 500, lon: -91.264),
        _sample('c', 50, lon: -91.268, c: Contaminant.arsenic),
      ]), isEmpty, reason: 'two lead and one arsenic');
      expect(estimateZones(line), hasLength(1));
    });

    test('never exceed the measured range, and leave Normal ground unshaded', () {
      final zone = estimateZones(line).single;
      expect(zone.sampleCount, 4);
      for (final cell in zone.cells) {
        expect(cell.value, lessThanOrEqualTo(1500 + 1e-6));
        expect(cell.value, greaterThanOrEqualTo(60 - 1e-6));
        expect(zone.levelOf(cell), isNot(ContaminationLevel.normal));
      }
    });

    test('are worst near the worst sample', () {
      final zone = estimateZones(line).single;
      final westmost = zone.cells.reduce((a, b) => a.west < b.west ? a : b);
      final eastmost = zone.cells.reduce((a, b) => a.east > b.east ? a : b);
      expect(westmost.value, greaterThan(eastmost.value));
      // The cell over the 1,500 ppm sample is Dangerous like the sample.
      final atWorst = zone.cells.firstWhere(
        (c) => c.west <= -91.270 && c.east >= -91.270 && c.south <= 40.80 && c.north >= 40.80,
      );
      expect(zone.levelOf(atWorst), ContaminationLevel.dangerous);
    });

    test("don't reach into unsampled ground", () {
      final zone = estimateZones(line).single;
      // Spacing ~330 m, so nothing beyond ~660 m (+ a cell) of a sample.
      for (final cell in zone.cells) {
        expect((cell.center.latitude - 40.80).abs() * 110540, lessThan(800));
        expect(cell.center.longitude, inInclusiveRange(-91.280, -91.248));
      }
    });

    test('dose rates are snapshots: dots only, no zone', () {
      expect(
        estimateZones([
          for (var i = 0; i < 4; i++) _sample('$i', 50, lon: -91.26 + i * 0.004, c: Contaminant.doseRate),
        ]),
        isEmpty,
      );
    });
  });
}
