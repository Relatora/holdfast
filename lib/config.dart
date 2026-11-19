/// Build-time configuration, set with `--dart-define`.
///
/// ```sh
/// flutter run -d chrome --dart-define=HOLDFAST_SERVER=http://192.168.1.20:8787
/// ```
abstract final class Config {
  /// The Holdfast server: hazard sync API plus the region file host.
  ///
  /// Defaults to the local dev server in `server/`. The Android emulator
  /// reaches the host machine at 10.0.2.2 instead of localhost, so pass that
  /// address when running there.
  static const serverUrl = String.fromEnvironment(
    'HOLDFAST_SERVER',
    defaultValue: 'http://localhost:8787',
  );

  /// Where region files (`<id>.pmtiles`, `<id>.pois.json`) and the
  /// `index.json` listing live. In production this is object storage behind
  /// a CDN; in development the Go server serves `regions/` from the repo.
  static const regionsUrl = String.fromEnvironment(
    'HOLDFAST_REGIONS',
    defaultValue: '$serverUrl/regions',
  );
}
