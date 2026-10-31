import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salahly/src/extensions/context_extension.dart';
import 'package:salahly/src/shared/motion/app_motion.dart';
import 'package:salahly/src/shared/motion/pressable_scale.dart';
import 'package:salahly/src/shared/motion/staggered_entrance.dart';
import 'package:salahly/src/theme/app_durations.dart';
import 'package:salahly/src/ui/shell/animated_branch_container.dart';

Widget _entrance({bool reduced = false, int count = 6, VoidCallback? onBuild}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: StaggeredEntrance(
        itemCount: count,
        child: Column(
          children: [
            for (var index = 0; index < count; index++)
              EntranceItem(
                index: index,
                child: Builder(
                  builder: (_) {
                    onBuild?.call();
                    return const SizedBox(width: 100, height: 40);
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

Widget _button({
  bool reduced = false,
  VoidCallback? onPressed,
  bool scrollable = false,
}) {
  final button = PressableScale(
    builder: (states) => FilledButton(
      statesController: states,
      autofocus: true,
      onPressed: onPressed,
      child: const Text('Action'),
    ),
  );
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: scrollable
            ? ListView(children: [button, const SizedBox(height: 1500)])
            : Center(child: button),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'sheets and dialogs respect reduced-motion timing and return to rest',
    (tester) async {
      for (final reduced in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () => context.showAppBottomSheet<void>(
                        builder: (_) => const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Modal content'),
                        ),
                      ),
                      child: const Text('Open sheet'),
                    ),
                    TextButton(
                      onPressed: () => context.showAppDialog<void>(
                        builder: (_) =>
                            const AlertDialog(content: Text('Modal content')),
                      ),
                      child: const Text('Open dialog'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final action in ['Open sheet', 'Open dialog']) {
          await tester.tap(find.text(action));
          await tester.pumpAndSettle();
          final context = tester.element(find.text('Modal content'));
          final route = ModalRoute.of(context)!;
          expect(
            route.transitionDuration,
            reduced ? Duration.zero : AppDurations.quick,
          );
          expect(
            route.reverseTransitionDuration,
            reduced
                ? Duration.zero
                : action == 'Open sheet'
                ? AppDurations.fast
                : AppDurations.quick,
          );
          Navigator.of(context).pop();
          await tester.pumpAndSettle();
          expect(find.text('Modal content'), findsNothing);
          expect(tester.binding.transientCallbackCount, 0);
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  test('stagger length stays bounded even with a long list', () {
    expect(AppMotion.intervalFor(0, 1).begin, 0);
    expect(AppMotion.intervalFor(0, 1).end, 1);
    expect(AppMotion.intervalFor(0, 1000).begin, 0);
    expect(AppMotion.intervalFor(7, 1000).begin, closeTo(0.35, 0.001));
    expect(
      AppMotion.intervalFor(999, 1000).begin,
      AppMotion.intervalFor(7, 1000).begin,
    );
    expect(AppMotion.intervalFor(999, 1000).end, 1);
  });

  testWidgets('one entrance ticker does not rebuild its children each frame', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpWidget(_entrance(onBuild: () => builds++));
    expect(builds, 6);
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(builds, 6);
    expect(
      tester
          .widgetList<FadeTransition>(find.byType(FadeTransition))
          .last
          .opacity
          .value,
      lessThan(1),
    );
    await tester.pumpAndSettle();
    expect(builds, 6);
    expect(tester.binding.transientCallbackCount, 0);
    for (final fade in tester.widgetList<FadeTransition>(
      find.byType(FadeTransition),
    )) {
      expect(fade.opacity.value, 1);
    }
  });

  testWidgets(
    'changing the item count after loading does not replay entrances',
    (tester) async {
      await tester.pumpWidget(_entrance());
      await tester.pumpAndSettle();
      await tester.pumpWidget(_entrance(count: 2));
      for (final fade in tester.widgetList<FadeTransition>(
        find.byType(FadeTransition),
      )) {
        expect(fade.opacity.value, 1);
      }
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'reduced motion skips and immediately finishes an active entrance',
    (tester) async {
      await tester.pumpWidget(_entrance(reduced: true));
      expect(tester.binding.transientCallbackCount, 0);
      expect(
        tester
            .widget<FadeTransition>(find.byType(FadeTransition).first)
            .opacity
            .value,
        1,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_entrance());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester
            .widgetList<FadeTransition>(find.byType(FadeTransition))
            .last
            .opacity
            .value,
        lessThan(1),
      );
      await tester.pumpWidget(_entrance(reduced: true));
      expect(tester.binding.transientCallbackCount, 0);
      for (final fade in tester.widgetList<FadeTransition>(
        find.byType(FadeTransition),
      )) {
        expect(fade.opacity.value, 1);
      }
      await tester.pumpWidget(_entrance());
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('disposing during an entrance removes its scheduled ticker', (
    tester,
  ) async {
    await tester.pumpWidget(_entrance());
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('press feedback preserves button activation and ends at rest', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(_button(onPressed: () => taps++));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Action')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      AppMotion.pressedScale,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('scrolling cancels the press without activating the button', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(_button(scrollable: true, onPressed: () => taps++));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Action')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
  });

  testWidgets('reduced motion keeps keyboard activation and disables scaling', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(_button(reduced: true, onPressed: () => taps++));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Action')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, 1);
    expect(scale.duration, Duration.zero);
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('disabled controls never scale or activate', (tester) async {
    await tester.pumpWidget(_button());
    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabling a pressed control safely resets feedback', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(_button(onPressed: () => taps++));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Action')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      AppMotion.pressedScale,
    );

    await tester.pumpWidget(_button());
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_button(onPressed: () => taps++));
    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tab transitions preserve text, scroll, and inactive focus rules',
    (tester) async {
      final text = TextEditingController();
      final scroll = ScrollController();
      final focus = FocusNode();
      addTearDown(text.dispose);
      addTearDown(scroll.dispose);
      addTearDown(focus.dispose);

      Widget shell(int index, {bool reduced = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: AnimatedBranchContainer(
              currentIndex: index,
              children: [
                ListView(
                  controller: scroll,
                  children: [
                    TextField(controller: text, focusNode: focus),
                    const SizedBox(height: 1600),
                  ],
                ),
                const Center(child: Text('Second tab')),
              ],
            ),
          ),
        ),
      );

      await tester.pumpWidget(shell(0));
      await tester.enterText(find.byType(TextField), 'Unsubmitted profile');
      focus.unfocus();
      await tester.pumpAndSettle();
      scroll.jumpTo(180);
      await tester.pumpWidget(shell(1));
      await tester.pumpAndSettle();
      expect(focus.canRequestFocus, isFalse);
      expect(focus.hasFocus, isFalse);
      expect(scroll.offset, 180);
      await tester.pumpWidget(shell(0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(text.text, 'Unsubmitted profile');
      expect(scroll.offset, 180);
      await tester.pumpWidget(shell(0, reduced: true));
      final fade = find
          .descendant(
            of: find.byType(AnimatedBranchContainer),
            matching: find.byType(FadeTransition),
          )
          .first;
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      await tester.pumpWidget(shell(1, reduced: true));
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('inactive branches stop ticking and rapid swaps settle cleanly', (
    tester,
  ) async {
    final ticks = [0, 0];
    final mounts = [0, 0];
    Widget shell(int index) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: AnimatedBranchContainer(
          currentIndex: index,
          children: [
            for (var index = 0; index < 2; index++)
              _TickerProbe(
                onMount: () => mounts[index]++,
                onTick: () => ticks[index]++,
              ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(shell(0));
    await tester.pump(const Duration(milliseconds: 20));
    expect(ticks[0], greaterThan(0));
    expect(ticks[1], 0);
    await tester.pumpWidget(shell(1));
    final inactiveTicks = ticks[0];
    await tester.pump(const Duration(milliseconds: 50));
    expect(ticks[0], inactiveTicks);
    expect(ticks[1], greaterThan(0));
    for (final index in [0, 1, 0, 1]) {
      await tester.pumpWidget(shell(index));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(mounts, [1, 1]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<FadeTransition>(find.byType(FadeTransition)).opacity.value,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}

class _TickerProbe extends StatefulWidget {
  const _TickerProbe({required this.onMount, required this.onTick});
  final VoidCallback onMount;
  final VoidCallback onTick;

  @override
  State<_TickerProbe> createState() => _TickerProbeState();
}

class _TickerProbeState extends State<_TickerProbe>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    widget.onMount();
    _ticker = createTicker((_) => widget.onTick())..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
