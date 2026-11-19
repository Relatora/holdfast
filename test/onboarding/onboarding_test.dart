import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/onboarding/onboarding_carousel.dart';
import 'package:holdfast/onboarding/onboarding_gate.dart';
import 'package:holdfast/settings/app_settings.dart';
import 'package:holdfast/theme/app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('shouldShowOnboarding', () {
    test('shows on first launch', () {
      expect(shouldShowOnboarding(dismissedForever: false, isFirstLaunch: true, downloadedRegions: 0), isTrue);
    });

    test('keeps showing on later launches while no map is downloaded', () {
      expect(shouldShowOnboarding(dismissedForever: false, isFirstLaunch: false, downloadedRegions: 0), isTrue);
    });

    test('stops once a map is downloaded', () {
      expect(shouldShowOnboarding(dismissedForever: false, isFirstLaunch: false, downloadedRegions: 1), isFalse);
    });

    test('"Don\'t show me this again" wins, even on first launch', () {
      expect(shouldShowOnboarding(dismissedForever: true, isFirstLaunch: true, downloadedRegions: 0), isFalse);
    });
  });

  group('OnboardingCarousel', () {
    late AppSettings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await AppSettings.load();
    });

    Future<OnboardingResult?> pump(WidgetTester tester) async {
      OnboardingResult? result;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            theme: AppTheme.dark(),
            // Reduced motion: also stops the looping glow, which would
            // otherwise keep pumpAndSettle from ever settling.
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async => result = await showOnboarding(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('ticking the box is saved immediately', (tester) async {
      await pump(tester);
      expect(find.text('Maps that work with no signal'), findsOneWidget);

      await tester.tap(find.text("Don't show me this again"));
      await tester.pump();
      expect(settings.onboardingDismissed, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('onboardingDismissed'), isTrue);
    });

    testWidgets('the last card offers to choose maps', (tester) async {
      await pump(tester);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Choose your first map'), findsOneWidget);
      expect(find.text('World'), findsOneWidget);
      expect(find.text('Choose maps'), findsOneWidget);
    });
  });
}
