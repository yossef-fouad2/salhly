import 'package:flutter/widgets.dart';

import '../../theme/app_curves.dart';
import '../../theme/app_durations.dart';

/// Finite decorative motion, using the existing theme timings and curves.
abstract final class AppMotion {
  AppMotion._();

  static const Duration entrance = AppDurations.medium;
  static const Duration tabSwap = AppDurations.quick;

  /// Logical pixels; paint transforms do not change the child's layout.
  static const double entranceOffset = 12;
  static const double pressedScale = 0.985;

  /// Items beyond this index share the last step so long lists do not crawl.
  static const int maxStaggerIndex = 7;

  /// Fraction of the timeline given to the stagger steps in total.
  static const double _staggerSpread = 0.35;

  /// Resolve a duration against the user's reduced-motion preference.
  static Duration durationOf(BuildContext context, Duration duration) {
    return isEnabled(context) ? duration : Duration.zero;
  }

  /// Whether entrance/transition animation should play at all.
  static bool isEnabled(BuildContext context) =>
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  /// Per-item [Interval] for a staggered entrance.
  ///
  /// One shared timeline drives the whole list; each item only reads its own
  /// slice of it, which keeps the number of tickers constant.
  static Interval intervalFor(int index, int itemCount) {
    if (itemCount <= 1) {
      return const Interval(0, 1, curve: AppCurves.decelerate);
    }
    final safeIndex = index.clamp(0, maxStaggerIndex);
    final step = _staggerSpread / (itemCount.clamp(2, maxStaggerIndex + 1) - 1);
    final start = (safeIndex * step).clamp(0.0, _staggerSpread);
    final end = (start + (1 - _staggerSpread)).clamp(0.0, 1.0);
    return Interval(start, end, curve: AppCurves.decelerate);
  }
}
