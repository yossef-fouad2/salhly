import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salahly/src/shared/widgets/app_button.dart';
import 'package:salahly/src/theme/color_schemes.dart';
import 'package:salahly/src/theme/theme.dart';

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05);
}

void main() {
  for (final theme in [
    buildLightTheme(primaryColorHex: '#0B132B'),
    buildDarkTheme(primaryColorHex: '#0B132B'),
  ]) {
    test(
      'design text and status colors remain legible in ${theme.brightness}',
      () {
        final cs = theme.colorScheme;
        final semantic = theme.extension<AppColorsExtension>()!;
        for (final (background, foreground) in [
          (cs.surface, cs.onSurface),
          (cs.surfaceContainerLow, cs.onSurfaceVariant),
          (cs.surfaceContainerLowest, cs.onSurface),
          (cs.primary, cs.onPrimary),
          (cs.secondaryContainer, cs.onSecondaryContainer),
          (semantic.warningContainer!, semantic.onWarningContainer!),
          (semantic.successContainer!, semantic.onSuccessContainer!),
          (AppPalettes.amber, AppPalettes.ink),
        ]) {
          expect(_contrast(background, foreground), greaterThanOrEqualTo(4.5));
        }
      },
    );
  }

  testWidgets(
    'buttons grow for accessible text without changing bounds on loading',
    (tester) async {
      final loading = ValueNotifier(false);
      addTearDown(loading.dispose);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(primaryColorHex: '#0B132B'),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
              child: Center(
                child: SizedBox(
                  width: 220,
                  child: ValueListenableBuilder(
                    valueListenable: loading,
                    builder: (context, busy, _) => AppButton(
                      label: 'Continue with your account',
                      isFullWidth: true,
                      isLoading: busy,
                      onPressed: () => taps++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bounds = tester.getSize(find.byType(TextButton));
      expect(bounds.height, greaterThan(56));
      loading.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getSize(find.byType(TextButton)), bounds);
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      await tester.tap(find.byType(TextButton));
      expect(taps, 0);
      loading.value = false;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(TextButton)), bounds);
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
