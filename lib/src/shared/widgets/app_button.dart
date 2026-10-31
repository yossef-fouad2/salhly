import '../../imports/imports.dart';
import '../motion/app_motion.dart';
import '../motion/pressable_scale.dart';

/// A fully themed button supporting all [ButtonVariant]s and [ButtonSize]s.
///
/// Usage:
/// ```dart
/// AppButton(
///   label: 'Save',
///   onPressed: _save,
///   variant: ButtonVariant.primary,
///   height: ButtonSize.large,
///   isLoading: state.isLoading,
/// )
/// ```
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = ButtonVariant.primary,
    this.color,
    this.textColor,
    this.height = ButtonSize.medium,
    this.width,
    this.isLoading = false,
    this.isFullWidth = false,
    this.prefixIcon,
    this.suffixIcon,
  });

  final String label;
  final VoidCallback? onPressed;
  final ButtonVariant variant;
  final Color? color;
  final Color? textColor;
  final ButtonSize height;
  final ButtonSize? width;
  final bool isLoading;
  final bool isFullWidth;
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    final cs = context.theme.colorScheme;
    final appColors = context.theme.extension<AppColorsExtension>()!;
    final isDisabled = onPressed == null || isLoading;

    final double buttonHeight = switch (height) {
      ButtonSize.small => 48,
      ButtonSize.medium => 52,
      ButtonSize.large => 56,
    };

    final double? buttonWidth = switch (width) {
      ButtonSize.small => 100,
      ButtonSize.medium => 150,
      ButtonSize.large => 200,
      null => null,
    };

    final double horizontalPadding = switch (height) {
      ButtonSize.small => 16,
      ButtonSize.medium => 20,
      ButtonSize.large => 24,
    };

    final double fontSize = switch (height) {
      ButtonSize.small => 13,
      ButtonSize.medium => 14,
      ButtonSize.large => 16,
    };

    final (bg, fg, border) = switch (variant) {
      ButtonVariant.primary => (
        color ?? cs.primary,
        textColor ?? cs.onPrimary,
        null,
      ),
      ButtonVariant.secondary => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
        null,
      ),
      ButtonVariant.outline => (
        Colors.transparent,
        cs.primary,
        BorderSide(color: cs.outlineVariant),
      ),
      ButtonVariant.ghost => (Colors.transparent, cs.primary, null),
      ButtonVariant.danger => (cs.error, cs.onError, null),
      ButtonVariant.success => (appColors.success, appColors.onSuccess, null),
    };

    // Retain the label's layout while loading so the button never jumps in size.
    final child = Stack(
      alignment: Alignment.center,
      children: [
        AnimatedOpacity(
          duration: AppMotion.durationOf(context, AppDurations.fast),
          opacity: isLoading ? 0 : 1,
          child: ExcludeSemantics(
            excluding: isLoading,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (prefixIcon != null) ...[
                  prefixIcon!,
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: isDisabled
                          ? fg.withValues(alpha: 0.5)
                          : textColor ?? fg,
                    ),
                  ),
                ),
                if (suffixIcon != null) ...[
                  const SizedBox(width: 8),
                  suffixIcon!,
                ],
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: AnimatedSwitcher(
              duration: AppMotion.durationOf(context, AppDurations.fast),
              switchInCurve: AppCurves.decelerate,
              child: isLoading
                  ? SizedBox(
                      key: const ValueKey('loader'),
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg,
                        semanticsLabel: 'common.loading'.tr(),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );

    return PressableScale(
      builder: (statesController) => AnimatedOpacity(
        duration: AppMotion.durationOf(context, AppDurations.fast),
        opacity: isDisabled ? 0.6 : 1.0,
        child: SizedBox(
          width: isFullWidth ? double.infinity : buttonWidth,
          child: TextButton(
            statesController: statesController,
            onPressed: isDisabled ? null : onPressed,
            style: TextButton.styleFrom(
              backgroundColor: bg,
              foregroundColor: fg,
              minimumSize: Size(0, buttonHeight),
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: 12,
              ),
              shape: border != null
                  ? RoundedRectangleBorder(
                      borderRadius: AppBorders.button,
                      side: border,
                    )
                  : const RoundedRectangleBorder(
                      borderRadius: AppBorders.button,
                    ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
