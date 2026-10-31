import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:salahly/src/data/repositories/auth_repository.dart';
import 'package:salahly/src/shared/motion/app_motion.dart';
import 'package:salahly/src/shared/widgets/app_brand.dart';
import 'package:salahly/src/shared/widgets/demo_banner.dart';
import 'package:salahly/src/theme/theme_constants.dart';

class AppShell extends StatelessWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  void _selectDestination(BuildContext context, int index) {
    FocusScope.of(context).unfocus();
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = [
      'navigation.home'.tr(context: context),
      'notifications.title'.tr(context: context),
      'profile.title'.tr(context: context),
    ];

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: AppSpacing.lg,
        title: AnimatedSwitcher(
          duration: AppMotion.durationOf(context, AppDurations.fast),
          child: navigationShell.currentIndex == 0
              ? const AppBrand(key: ValueKey('brand'))
              : Text(
                  titles[navigationShell.currentIndex],
                  key: ValueKey(navigationShell.currentIndex),
                ),
        ),
        actions: navigationShell.currentIndex == 0
            ? [
                IconButton(
                  tooltip: 'navigation.notifications'.tr(),
                  onPressed: () => _selectDestination(context, 1),
                  icon: const Icon(Icons.notifications_none_rounded),
                ),
                IconButton(
                  tooltip: 'navigation.profile'.tr(),
                  onPressed: () => _selectDestination(context, 2),
                  icon: CircleAvatar(
                    radius: 18,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer,
                    child: Icon(
                      Icons.person_outline_rounded,
                      size: 20,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                SizedBox(width: AppSpacing.sm),
              ]
            : null,
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            if (context.read<AuthRepository>().isDemo)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.pagePadding,
                      vertical: AppSpacing.xs,
                    ),
                    child: const DemoBanner(),
                  ),
                ),
              ),
            Expanded(child: navigationShell),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              child: NavigationBar(
                animationDuration: AppMotion.durationOf(
                  context,
                  AppMotion.tabSwap,
                ),
                selectedIndex: navigationShell.currentIndex,
                onDestinationSelected: (index) =>
                    _selectDestination(context, index),
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.home_outlined),
                    selectedIcon: const Icon(Icons.home),
                    label: 'navigation.home'.tr(context: context),
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.notifications_outlined),
                    selectedIcon: const Icon(Icons.notifications),
                    label: 'navigation.notifications'.tr(context: context),
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.person_outline),
                    selectedIcon: const Icon(Icons.person),
                    label: 'navigation.profile'.tr(context: context),
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
