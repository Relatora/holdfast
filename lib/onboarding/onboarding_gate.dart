/// When to show the welcome flashcards.
///
/// Rule: show them on the very first launch, and keep showing them on later
/// launches for as long as no map has been downloaded, because without a
/// map the app can't do its job offline. "Don't show me this again" wins
/// over both.
bool shouldShowOnboarding({
  required bool dismissedForever,
  required bool isFirstLaunch,
  required int downloadedRegions,
}) {
  if (dismissedForever) return false;
  return isFirstLaunch || downloadedRegions == 0;
}
