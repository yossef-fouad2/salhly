import 'package:flutter/widgets.dart';

import 'app_motion.dart';

/// One timeline for a group. Ordinary rebuilds and item-count changes do not
/// replay it; create a new keyed group only when a new entrance is intended.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.itemCount,
    required this.child,
  }) : assert(itemCount >= 0);

  final int itemCount;
  final Widget child;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = AppMotion.durationOf(context, AppMotion.entrance);
    _controller.duration = duration;
    if (duration == Duration.zero) {
      _controller.value = 1;
    } else if (!_started) {
      _controller.forward();
    }
    _started = true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _EntranceScope(
    animation: _controller,
    itemCount: widget.itemCount,
    child: widget.child,
  );
}

class EntranceItem extends StatelessWidget {
  const EntranceItem({super.key, required this.index, required this.child})
    : assert(index >= 0);

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_EntranceScope>();
    if (scope == null) return child;

    final progress = scope.animation.drive(
      CurveTween(curve: AppMotion.intervalFor(index, scope.itemCount)),
    );
    return FadeTransition(
      opacity: progress,
      alwaysIncludeSemantics: true,
      child: AnimatedBuilder(
        animation: progress,
        child: RepaintBoundary(child: child),
        builder: (_, child) => Transform.translate(
          offset: Offset(0, AppMotion.entranceOffset * (1 - progress.value)),
          child: child,
        ),
      ),
    );
  }
}

class _EntranceScope extends InheritedWidget {
  const _EntranceScope({
    required this.animation,
    required this.itemCount,
    required super.child,
  });

  final Animation<double> animation;
  final int itemCount;

  @override
  bool updateShouldNotify(_EntranceScope oldWidget) =>
      animation != oldWidget.animation || itemCount != oldWidget.itemCount;
}
