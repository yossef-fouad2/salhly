import 'package:salahly/src/imports/imports.dart';
import 'package:salahly/src/shared/motion/pressable_scale.dart';
import 'package:salahly/src/shared/motion/staggered_entrance.dart';

/// A single, retained layout for the welcome and email account screens.
class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.pagePadding),
                  child: SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: AppSpacing.md,
                      runSpacing: AppSpacing.sm,
                      children: [
                        const AppBrand(),
                        PressableScale(
                          builder: (states) => TextButton.icon(
                            statesController: states,
                            onPressed: () => context.setLocale(
                              Locale(
                                context.locale.languageCode == 'en'
                                    ? 'ar'
                                    : 'en',
                              ),
                            ),
                            style: TextButton.styleFrom(
                              backgroundColor: colors.surfaceContainer,
                              foregroundColor: colors.onSurface,
                              minimumSize: const Size(48, 48),
                              padding: EdgeInsets.symmetric(
                                horizontal: AppSpacing.md,
                                vertical: AppSpacing.sm,
                              ),
                              shape: const StadiumBorder(),
                            ),
                            icon: const Icon(Icons.translate_rounded, size: 18),
                            label: Text(
                              (context.locale.languageCode == 'en'
                                      ? 'profile.arabic'
                                      : 'profile.english')
                                  .tr(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.pagePadding,
                  AppSpacing.sm,
                  AppSpacing.pagePadding,
                  AppSpacing.lg,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1048),
                    child: StaggeredEntrance(
                      itemCount: 2,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 840;
                          final gap = wide ? AppSpacing.lg : AppSpacing.md;
                          final introWidth = wide
                              ? (constraints.maxWidth - gap) * 0.43
                              : constraints.maxWidth;
                          final contentWidth = wide
                              ? constraints.maxWidth - gap - introWidth
                              : constraints.maxWidth;

                          // Keep the same element tree at both breakpoints so
                          // focused fields and password visibility survive a resize.
                          return Flex(
                            direction: wide ? Axis.horizontal : Axis.vertical,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: introWidth,
                                child: EntranceItem(
                                  index: 0,
                                  child: Material(
                                    color: colors.surfaceContainerLow,
                                    borderRadius: AppBorders.card,
                                    child: Padding(
                                      padding: EdgeInsets.all(AppSpacing.lg),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: AppSpacing.ms,
                                              vertical: AppSpacing.sm,
                                            ),
                                            decoration: BoxDecoration(
                                              color: colors.surfaceContainer,
                                              borderRadius: AppBorders.full,
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const ExcludeSemantics(
                                                  child: Icon(
                                                    Icons.handyman_rounded,
                                                    size: 16,
                                                    color: AppPalettes.amber,
                                                  ),
                                                ),
                                                SizedBox(width: AppSpacing.sm),
                                                Flexible(
                                                  child: Text(
                                                    'auth.workspace_label'.tr(),
                                                    style: context
                                                        .textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                          color: colors
                                                              .onSurfaceVariant,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          SizedBox(height: AppSpacing.md),
                                          Semantics(
                                            header: true,
                                            child: Text(
                                              title,
                                              style: context
                                                  .textTheme
                                                  .displaySmall,
                                            ),
                                          ),
                                          SizedBox(height: AppSpacing.ms),
                                          Text(
                                            subtitle,
                                            style: context.textTheme.bodyLarge
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: wide ? gap : 0,
                                height: wide ? 0 : gap,
                              ),
                              SizedBox(
                                width: contentWidth,
                                child: EntranceItem(index: 1, child: child),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
