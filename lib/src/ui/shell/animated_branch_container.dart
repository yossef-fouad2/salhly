import 'package:flutter/widgets.dart';

import '../../shared/motion/app_motion.dart';
import '../../theme/app_curves.dart';

/// Keeps all branch navigators mounted, but only the active branch can tick or
/// receive focus. A single paint-only transition runs on a change of tab.
class AnimatedBranchContainer extends StatefulWidget {
  const AnimatedBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  }) : assert(currentIndex >= 0 && currentIndex < children.length);

  final int currentIndex;
  final List<Widget> children;

  @override
  State<AnimatedBranchContainer> createState() =>
      _AnimatedBranchContainerState();
}

class _AnimatedBranchContainerState extends State<AnimatedBranchContainer>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);
  late final _progress = _controller.drive(
    CurveTween(curve: AppCurves.decelerate),
  );
  late final _opacity = _progress.drive(Tween<double>(begin: 0.92, end: 1));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = AppMotion.durationOf(context, AppMotion.tabSwap);
    if (!AppMotion.isEnabled(context)) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant AnimatedBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex &&
        _controller.duration != Duration.zero) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: AnimatedBuilder(
      animation: _progress,
      child: IndexedStack(
        index: widget.currentIndex,
        children: [
          for (var index = 0; index < widget.children.length; index++)
            Offstage(
              offstage: index != widget.currentIndex,
              child: ExcludeFocus(
                excluding: index != widget.currentIndex,
                child: TickerMode(
                  enabled: index == widget.currentIndex,
                  child: RepaintBoundary(child: widget.children[index]),
                ),
              ),
            ),
        ],
      ),
      builder: (_, child) => Transform.translate(
        offset: Offset(0, AppMotion.entranceOffset / 2 * (1 - _progress.value)),
        child: child,
      ),
    ),
  );
}
