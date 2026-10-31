import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/imports/imports.dart';
import 'package:salahly/src/shared/motion/app_motion.dart';
import 'package:salahly/src/shared/motion/pressable_scale.dart';

class AccountRoleCard extends StatelessWidget {
  const AccountRoleCard({
    super.key,
    required this.role,
    required this.selected,
    required this.onTap,
  });

  final UserRole role;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final provider = role == UserRole.provider;
    return Semantics(
      checked: selected,
      enabled: onTap != null,
      inMutuallyExclusiveGroup: true,
      child: PressableScale(
        builder: (states) => Material(
          color: onTap == null
              ? colors.surfaceContainerLow
              : colors.surfaceContainerLowest,
          animationDuration: AppMotion.durationOf(context, AppDurations.fast),
          shape: RoundedRectangleBorder(
            borderRadius: AppBorders.card,
            side: BorderSide(
              color: selected ? colors.primary : colors.outlineVariant,
              width: 1.5,
            ),
          ),
          child: InkWell(
            statesController: states,
            onTap: onTap,
            canRequestFocus: onTap != null,
            borderRadius: AppBorders.card,
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.ml),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: Container(
                          padding: EdgeInsets.all(AppSpacing.ms),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainer,
                            borderRadius: AppBorders.lg,
                          ),
                          child: Icon(
                            provider
                                ? Icons.engineering_outlined
                                : Icons.home_repair_service_outlined,
                            color: provider
                                ? colors.secondary
                                : colors.onSurface,
                          ),
                        ),
                      ),
                      SizedBox(width: AppSpacing.ms),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: AppSpacing.xs,
                              ),
                              decoration: BoxDecoration(
                                color: provider
                                    ? context.appColors.warningContainer
                                    : colors.surfaceContainerHigh,
                                borderRadius: AppBorders.full,
                              ),
                              child: Text(
                                'roles.${role.name}'.tr(),
                                style: context.textTheme.labelSmall?.copyWith(
                                  color: provider
                                      ? context.appColors.onWarningContainer
                                      : colors.onSurface,
                                ),
                              ),
                            ),
                            SizedBox(height: AppSpacing.sm),
                            Text(
                              'onboarding.${role.name}_title'.tr(),
                              style: context.textTheme.titleLarge,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: AppSpacing.sm),
                      ExcludeSemantics(
                        child: Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: selected
                              ? colors.primary
                              : colors.outlineVariant,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: AppSpacing.md),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(AppSpacing.ms),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: AppBorders.lg,
                    ),
                    child: Text(
                      'onboarding.${role.name}_benefit'.tr(),
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
