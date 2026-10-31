import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_curves.dart';
import '../../theme/app_durations.dart';
import 'app_motion.dart';

/// Pass the supplied statesController to an InkWell or Material button. Its
/// native states handle keyboard presses, drag cancellation, and disabled input.
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.builder});

  final Widget Function(WidgetStatesController statesController) builder;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  final _states = WidgetStatesController();
  bool _pressed = false;
  bool _updateScheduled = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_syncPressed);
  }

  void _syncPressed() {
    final pressed =
        _states.value.contains(WidgetState.pressed) &&
        !_states.value.contains(WidgetState.disabled);
    if (pressed == _pressed) return;

    // Material can publish disabled/pressed changes while building its child.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_updateScheduled) return;
      _updateScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateScheduled = false;
        if (mounted) _syncPressed();
      });
      return;
    }
    setState(() => _pressed = pressed);
  }

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: AppMotion.isEnabled(context) && _pressed
        ? AppMotion.pressedScale
        : 1,
    duration: AppMotion.durationOf(context, AppDurations.veryFast),
    curve: AppCurves.smooth,
    child: widget.builder(_states),
  );
}
