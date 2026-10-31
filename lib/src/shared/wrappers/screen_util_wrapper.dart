import '../../imports/imports.dart';

/// A wrapper to initialize [ScreenUtil] with design-specific constraints.
class ScreenUtilWrapper extends StatelessWidget {
  final Widget? child;
  final WidgetBuilder? builder;
  final Size designSize;
  final bool minTextAdapt;
  final bool splitScreenMode;

  const ScreenUtilWrapper({
    super.key,
    this.child,
    this.builder,
    this.designSize = const Size(390, 844),
    this.minTextAdapt = true,
    this.splitScreenMode = true,
  }) : assert(child != null || builder != null);

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: designSize,
      minTextAdapt: minTextAdapt,
      splitScreenMode: splitScreenMode,
      builder: (context, _) => builder?.call(context) ?? child!,
    );
  }
}
