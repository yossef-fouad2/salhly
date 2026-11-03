import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:salahly/src/data/models/service_category.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';
import 'package:salahly/src/extensions/context_extension.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/shared/enums/button_enums.dart';
import 'package:salahly/src/shared/motion/app_motion.dart';
import 'package:salahly/src/shared/motion/pressable_scale.dart';
import 'package:salahly/src/shared/motion/staggered_entrance.dart';
import 'package:salahly/src/shared/widgets/app_button.dart';
import 'package:salahly/src/shared/widgets/app_empty_state.dart';
import 'package:salahly/src/shared/widgets/app_loading.dart';
import 'package:salahly/src/shared/widgets/app_text_field.dart';
import 'package:salahly/src/theme/theme_constants.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';
import 'package:salahly/src/ui/home/home_cubit.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.select((SessionBloc bloc) => bloc.state.user);
    if (user == null) return const SizedBox.shrink();

    return BlocProvider(
      key: ValueKey(user.id),
      create: (context) => HomeCubit(context.read<CatalogRepository>())..load(),
      child: _HomeView(user: user),
    );
  }
}

class _HomeView extends StatefulWidget {
  const _HomeView({required this.user});

  final AppUser user;

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView> {
  final _servicesKey = GlobalKey();
  final _search = TextEditingController();

  void _browseServices() {
    final target = _servicesKey.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: AppMotion.durationOf(context, AppDurations.quick),
      curve: AppCurves.decelerate,
    );
  }

  void _clearSearch() {
    _search.clear();
    context.read<HomeCubit>().search('');
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final isProvider = user.role == UserRole.provider;
    return RefreshIndicator(
      onRefresh: context.read<HomeCubit>().load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.pagePadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpacing.sm,
                    children: [
                      Text(
                        'home.greeting'.tr(namedArgs: {'name': user.name}),
                        style: context.textTheme.bodyMedium?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => context.goNamed(AppRouteNames.profile),
                        icon: const Icon(Icons.location_on_outlined, size: 16),
                        label: Text(
                          user.city?.trim().isNotEmpty == true
                              ? user.city!
                              : 'home.add_city'.tr(),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    (isProvider
                            ? 'home.provider_title'
                            : 'home.discovery_title')
                        .tr(),
                    style: context.textTheme.displaySmall,
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    (isProvider
                            ? 'home.provider_subtitle'
                            : 'home.customer_subtitle')
                        .tr(),
                    style: context.textTheme.bodyLarge?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: AppSpacing.lg),
                  _DiscoveryCard(
                    isProvider: isProvider,
                    onPressed: isProvider
                        ? () => context.pushNamed(
                            AppRouteNames.providerOnboarding,
                          )
                        : () => context.pushNamed(
                            AppRouteNames.createServiceRequest,
                          ),
                    onBrowse: isProvider ? null : _browseServices,
                  ),
                  SizedBox(height: AppSpacing.xl),
                  Row(
                    key: _servicesKey,
                    children: [
                      Expanded(
                        child: Text(
                          'home.services_title'.tr(),
                          style: context.textTheme.titleLarge,
                        ),
                      ),
                      BlocSelector<HomeCubit, HomeState, bool>(
                        selector: (state) => state.query.isNotEmpty,
                        builder: (context, hasQuery) => hasQuery
                            ? TextButton(
                                onPressed: _clearSearch,
                                child: Text('home.clear_search'.tr()),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                  SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _search,
                    hint: 'home.search_hint'.tr(),
                    prefixIcon: const Icon(Icons.search_rounded),
                    textInputAction: TextInputAction.search,
                    onChanged: context.read<HomeCubit>().search,
                    onFieldSubmitted: (_) => context.hideKeyboard(),
                  ),
                  SizedBox(height: AppSpacing.md),
                  BlocConsumer<HomeCubit, HomeState>(
                    listenWhen: (previous, current) =>
                        current.categories.isNotEmpty &&
                        current.errorMessage != null &&
                        previous.errorMessage != current.errorMessage,
                    listener: (context, state) =>
                        context.showErrorSnackBar(state.errorMessage!.tr()),
                    builder: (context, state) {
                      if (state.isLoading && state.categories.isEmpty) {
                        return Padding(
                          padding: EdgeInsets.all(AppSpacing.lg),
                          child: AppLoading(
                            message: 'common.loading'.tr(context: context),
                          ),
                        );
                      }
                      if (state.errorMessage != null &&
                          state.categories.isEmpty) {
                        return AppEmptyState(
                          icon: Icons.error_outline,
                          title: 'common.error'.tr(context: context),
                          subtitle: state.errorMessage!.tr(context: context),
                          actionLabel: 'common.retry'.tr(context: context),
                          onAction: context.read<HomeCubit>().load,
                        );
                      }
                      if (state.categories.isEmpty) {
                        return AppEmptyState(
                          icon: Icons.home_repair_service_outlined,
                          title: 'home.no_categories'.tr(context: context),
                          actionLabel: 'common.retry'.tr(context: context),
                          onAction: context.read<HomeCubit>().load,
                        );
                      }
                      final categories = state.visibleCategories;
                      return StaggeredEntrance(
                        itemCount: state.categories.length,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            if (categories.isEmpty) {
                              return AppEmptyState(
                                icon: Icons.search_off,
                                title: 'home.no_results'.tr(context: context),
                              );
                            }
                            final textScale =
                                MediaQuery.textScalerOf(context).scale(16) / 16;
                            final columns =
                                textScale > 1.4 || constraints.maxWidth < 260
                                ? 1
                                : constraints.maxWidth >= 680
                                ? 3
                                : 2;
                            final width =
                                (constraints.maxWidth -
                                    AppSpacing.ms * (columns - 1)) /
                                columns;
                            return Wrap(
                              spacing: AppSpacing.ms,
                              runSpacing: AppSpacing.ms,
                              children: [
                                for (final (index, category)
                                    in categories.indexed)
                                  SizedBox(
                                    key: ValueKey(category.id),
                                    width: width,
                                    child: EntranceItem(
                                      index: index,
                                      child: _CategoryCard(category: category),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      );
                    },
                  ),
                  SizedBox(height: AppSpacing.xl),
                  Card(
                    color: context.colors.surfaceContainerLow,
                    child: Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'home.coming_next'.tr(),
                            style: context.textTheme.labelSmall?.copyWith(
                              color: context.colors.secondary,
                              letterSpacing: 1.4,
                            ),
                          ),
                          SizedBox(height: AppSpacing.sm),
                          Text(
                            'home.how_title'.tr(),
                            style: context.textTheme.titleLarge,
                          ),
                          SizedBox(height: AppSpacing.ms),
                          for (final (index, step) in const [
                            'home.step_request',
                            'home.step_quotes',
                            'home.step_choose',
                          ].indexed)
                            Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: AppSpacing.sm,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color:
                                          context.colors.surfaceContainerLowest,
                                      borderRadius: AppBorders.sm,
                                    ),
                                    child: Text(
                                      '${index + 1}'.padLeft(2, '0'),
                                      style: context.textTheme.labelMedium,
                                    ),
                                  ),
                                  SizedBox(width: AppSpacing.ms),
                                  Expanded(child: Text(step.tr())),
                                ],
                              ),
                            ),
                          SizedBox(height: AppSpacing.ms),
                          Text(
                            (user.role == UserRole.provider
                                    ? 'home.provider_next'
                                    : 'home.category_soon')
                                .tr(),
                            style: context.textTheme.bodySmall?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: AppSpacing.md),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscoveryCard extends StatelessWidget {
  const _DiscoveryCard({
    required this.isProvider,
    required this.onPressed,
    this.onBrowse,
  });

  final bool isProvider;
  final VoidCallback onPressed;
  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: AppBorders.card,
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [AppPalettes.ink, Color(0xFF24334D)],
        ),
      ),
      child: ClipRRect(
        borderRadius: AppBorders.card,
        child: Stack(
          children: [
            PositionedDirectional(
              end: -24,
              top: -20,
              child: ExcludeSemantics(
                child: Icon(
                  isProvider
                      ? Icons.handyman_rounded
                      : Icons.home_repair_service_rounded,
                  size: 190,
                  color: Colors.white.withValues(alpha: 0.05),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isProvider ? Icons.badge_outlined : Icons.home_outlined,
                        color: AppPalettes.amber,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (isProvider
                                  ? 'home.provider_label'
                                  : 'home.discovery_label')
                              .tr(),
                          style: context.textTheme.labelSmall?.copyWith(
                            color: AppPalettes.amber,
                            letterSpacing: 1.3,
                          ),
                        ),
                      ),
                      if (!isProvider)
                        IconButton(
                          tooltip: 'requests.history_title'.tr(),
                          onPressed: () =>
                              context.pushNamed(AppRouteNames.serviceRequests),
                          icon: const Icon(
                            Icons.receipt_long_outlined,
                            color: Colors.white,
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: AppSpacing.md),
                  Text(
                    (isProvider
                            ? 'home.provider_card_title'
                            : 'home.discovery_card_title')
                        .tr(),
                    style: context.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    (isProvider
                            ? 'home.provider_card_body'
                            : 'home.discovery_card_body')
                        .tr(),
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFD0D9E7),
                    ),
                  ),
                  SizedBox(height: AppSpacing.lg),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      AppButton(
                        label:
                            (isProvider
                                    ? 'provider.open'
                                    : 'requests.new_request')
                                .tr(),
                        color: AppPalettes.amber,
                        textColor: AppPalettes.ink,
                        height: ButtonSize.large,
                        suffixIcon: const Icon(
                          Icons.arrow_forward_rounded,
                          color: AppPalettes.ink,
                          size: 20,
                        ),
                        onPressed: onPressed,
                      ),
                      if (onBrowse != null)
                        TextButton(
                          onPressed: onBrowse,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          child: Text('home.browse_services'.tr()),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category});

  final ServiceCategory category;

  @override
  Widget build(BuildContext context) {
    final language = context.locale.languageCode;
    final (iconBackground, iconColor) = switch (category.iconKey) {
      'electrical' || 'carpentry' => (
        context.appColors.warningContainer!,
        context.appColors.onWarningContainer!,
      ),
      'painting' => (
        context.appColors.successContainer!,
        context.appColors.onSuccessContainer!,
      ),
      _ => (context.colors.primaryContainer, context.colors.onPrimaryContainer),
    };
    return PressableScale(
      builder: (statesController) => Card(
        child: InkWell(
          statesController: statesController,
          onTap: () => _showDetails(context),
          borderRadius: AppBorders.card,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 152),
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: iconBackground,
                      borderRadius: AppBorders.lg,
                    ),
                    child: Icon(
                      _categoryIcon(category.iconKey),
                      color: iconColor,
                      size: 27,
                    ),
                  ),
                  SizedBox(height: AppSpacing.ms),
                  Text(
                    category.name(language),
                    textAlign: TextAlign.center,
                    style: context.textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    context.showAppBottomSheet<void>(
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  _categoryIcon(category.iconKey),
                  color: context.colors.primary,
                ),
                SizedBox(height: AppSpacing.md),
                Text(
                  category.name(context.locale.languageCode),
                  style: context.textTheme.headlineSmall,
                ),
                SizedBox(height: AppSpacing.ms),
                Text(category.description(context.locale.languageCode)),
                SizedBox(height: AppSpacing.lg),
                Text(
                  'home.category_soon'.tr(),
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: AppSpacing.lg),
                AppButton(
                  label: 'common.close'.tr(),
                  variant: ButtonVariant.ghost,
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
                if (context.read<SessionBloc>().state.user?.role ==
                    UserRole.customer) ...[
                  SizedBox(height: AppSpacing.sm),
                  AppButton(
                    label: 'requests.request_service'.tr(),
                    isFullWidth: true,
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      context.pushNamed(
                        AppRouteNames.createServiceRequest,
                        queryParameters: {'categoryId': category.id},
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _categoryIcon(String key) => switch (key) {
  'plumbing' => Icons.plumbing,
  'electrical' => Icons.electrical_services,
  'carpentry' => Icons.handyman_outlined,
  'air_conditioning' => Icons.ac_unit,
  'appliance_repair' => Icons.kitchen_outlined,
  'painting' => Icons.format_paint_outlined,
  _ => Icons.home_repair_service_outlined,
};
