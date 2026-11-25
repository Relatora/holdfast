/// "Place an incident": put a detonation, a leak, an eruption or a tsunami
/// anywhere on the map, by moving the map under a pin or by typing an
/// address, and see its plume, rings or waves before reporting it.
///
/// The flow, driven by the map screen:
/// 1. [pickIncidentType]: what happened.
/// 2. Placing: a pin stays in the middle of the screen while the map moves
///    under it ([PlacementPin]); a banner offers address search
///    ([PlacementBanner], not for tsunamis, which start out at sea); the
///    map previews the hazard at the pin, with the wind there when it can
///    be fetched.
/// 3. "Place here" ([PlacementFooter]) opens the usual report sheet with
///    the type, the place and the wind filled in.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../hazards/hazard.dart';
import '../hazards/hazard_details.dart';
import '../map/hazard_marker.dart';
import 'address_search.dart';

/// The incidents offered first, with the words people use for them. The
/// last choice opens the full list of hazard types.
const incidentChoices = <(HazardType, String, String)>[
  (HazardType.nuclearDetonation, 'Nuclear detonation', 'Blast, burn and fallout rings'),
  (HazardType.leadDust, 'Explosives or lead detonation', 'Lead dust drifting downwind'),
  (HazardType.chemicalSpill, 'Chemical leak', 'A toxic plume downwind'),
  (HazardType.gasLeak, 'Gas leak', 'Gas drifting downwind'),
  (HazardType.radiation, 'Radioactive leak', 'A damaged plant or source: fallout downwind'),
  (HazardType.volcanicEruption, 'Volcanic eruption', 'Danger zone and an ash plume'),
  (HazardType.tsunami, 'Tsunami', 'Where the wave starts, and when it arrives'),
  (HazardType.fire, 'Wildfire', 'Smoke downwind'),
];

/// Asks what to place. Returns the type, [HazardType.other] for "something
/// else" (the caller opens the full report sheet), or null when dismissed.
Future<HazardType?> pickIncidentType(BuildContext context) => showModalBottomSheet<HazardType>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Place an incident', style: theme.textTheme.titleLarge),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Put it anywhere on the map, or find it by address, and see where it spreads before you report it.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                for (final (type, title, subtitle) in incidentChoices)
                  ListTile(
                    leading: CircleAvatar(backgroundColor: type.color, child: Icon(type.icon, color: Colors.white)),
                    title: Text(title),
                    subtitle: Text(subtitle),
                    onTap: () => Navigator.pop(context, type),
                  ),
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.more_horiz_rounded)),
                  title: const Text('Something else'),
                  subtitle: const Text('Every kind of hazard, reported at the middle of the map'),
                  onTap: () => Navigator.pop(context, HazardType.other),
                ),
              ],
            ),
          ),
        );
      },
    );

/// Tsunamis are placed where the wave starts, out at sea, which no street
/// address describes.
bool placedByAddress(HazardType type) => type != HazardType.tsunami;

/// What the pin is asking for, under the type's name.
String placementHint(HazardType type) => switch (type) {
      HazardType.tsunami => 'Move the map to put the pin where the wave starts, out at sea.',
      HazardType.volcanicEruption => 'Move the map to put the pin on the vent, or search for the volcano.',
      _ => 'Move the map to put the pin on it, or search for an address.',
    };

/// The pin in the middle of the map. It doesn't move: the map moves under
/// it, which works the same with a finger, a mouse and the keyboard.
class PlacementPin extends StatelessWidget {
  const PlacementPin({super.key, required this.type});
  final HazardType type;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Center(
          child: Semantics(
            label: '${type.label} pin, at the middle of the map',
            child: SizedBox(
              width: 48,
              height: 96, // the pin's point sits on the centre
              child: Column(
                children: [
                  Icon(Icons.location_on_rounded, size: 48, color: type.color, shadows: const [
                    Shadow(blurRadius: 6, color: Color(0x66000000)),
                  ]),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ),
      );
}

/// The top of the screen while placing: what's being placed, an address
/// search where it makes sense, and Cancel.
class PlacementBanner extends StatefulWidget {
  const PlacementBanner({
    super.key,
    required this.type,
    required this.searchOffline,
    required this.searchOnline,
    required this.onResult,
    required this.onCancel,
  });

  final HazardType type;

  /// Streets, crossings and places on the downloaded map; instant.
  final Future<List<AddressResult>> Function(String query) searchOffline;

  /// Full addresses through Photon, or null when offline mode is on.
  final Future<List<AddressResult>> Function(String query)? searchOnline;

  final ValueChanged<AddressResult> onResult;
  final VoidCallback onCancel;

  @override
  State<PlacementBanner> createState() => _PlacementBannerState();
}

class _PlacementBannerState extends State<PlacementBanner> {
  final _query = TextEditingController();
  List<AddressResult> _results = const [];
  bool _searchingOnline = false;
  String? _message;
  Timer? _debounce;
  int _generation = 0; // ignores answers to queries that were since changed

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () => _searchOffline(text));
  }

  Future<void> _searchOffline(String text) async {
    final generation = ++_generation;
    final query = text.trim();
    if (query.length < 2) {
      setState(() {
        _results = const [];
        _message = null;
      });
      return;
    }
    final results = await widget.searchOffline(query);
    if (!mounted || generation != _generation) return;
    setState(() {
      _results = results;
      _message = results.isEmpty
          ? (widget.searchOnline == null
              ? 'Nothing on your map by that name. Offline mode is on, so full addresses aren\'t searched.'
              : 'Nothing on your map by that name. Press Enter to search full addresses online.')
          : null;
    });
  }

  /// Enter: the map's matches plus, with a connection, full addresses.
  Future<void> _submit(String text) async {
    final query = text.trim();
    final online = widget.searchOnline;
    if (query.length < 2) return;
    await _searchOffline(query);
    if (online == null || !mounted) return;
    final generation = _generation;
    setState(() => _searchingOnline = true);
    List<AddressResult> found;
    try {
      found = await online(query);
    } catch (_) {
      found = const [];
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _searchingOnline = false;
      _results = [..._results, ...found];
      _message = _results.isEmpty ? 'No address found. Move the map to place the pin instead.' : null;
    });
  }

  void _pick(AddressResult result) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _results = const [];
      _query.text = result.title;
    });
    widget.onResult(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = widget.type;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 16, backgroundColor: type.color, child: Icon(type.icon, size: 18, color: Colors.white)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Place: ${type.label}', style: theme.textTheme.titleMedium),
                      Text(placementHint(type), style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
              ],
            ),
            if (placedByAddress(type)) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextField(
                  controller: _query,
                  onChanged: _onChanged,
                  onSubmitted: _submit,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: 'Street, crossing (Main & 2nd) or address',
                    border: const OutlineInputBorder(),
                    suffixIcon: _searchingOnline
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : null,
                  ),
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
                  child: Text(_message!, style: theme.textTheme.bodySmall),
                ),
              if (_results.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(top: 4, right: 8),
                    children: [
                      for (final r in _results)
                        ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                          leading: Icon(switch (r.source) {
                            AddressSource.street => Icons.add_road_rounded,
                            AddressSource.crossing => Icons.alt_route_rounded,
                            AddressSource.place => Icons.place_rounded,
                            AddressSource.online => Icons.public_rounded,
                          }),
                          title: Text(r.title),
                          subtitle: Text(r.subtitle),
                          onTap: () => _pick(r),
                        ),
                    ],
                  ),
                ),
              if (widget.searchOnline != null && _results.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
                  child: Text(
                    'Press Enter to also search full addresses online (photon.komoot.io).',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The bottom of the screen while placing: the wind the preview uses, and
/// the button that opens the report.
class PlacementFooter extends StatelessWidget {
  const PlacementFooter({super.key, required this.type, required this.wind, required this.fetchingWind, required this.onPlace});

  final HazardType type;
  final Wind? wind;
  final bool fetchingWind;
  final VoidCallback onPlace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final windLine = !type.spreadsWithWind
        ? null
        : fetchingWind
            ? 'Getting the wind at the pin…'
            : switch (wind) {
                final w? => 'Wind at the pin: from ${w.fromCompass} at ${w.speedKmh.round()} km/h (forecast)',
                null => 'No wind yet: add it in the next step to draw the plume.',
              };
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                windLine ?? 'The rings show around the pin.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: onPlace,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Place here'),
            ),
          ],
        ),
      ),
    );
  }
}
