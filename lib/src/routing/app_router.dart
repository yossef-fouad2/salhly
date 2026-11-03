import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../data/repositories/auth_repository.dart';
import '../data/models/user_model.dart';
import '../shared/motion/app_motion.dart';
import '../shared/widgets/app_empty_state.dart';
import '../theme/app_curves.dart';
import '../theme/app_durations.dart';
import '../ui/auth/bloc/auth_bloc.dart';
import '../ui/auth/bloc/session_bloc.dart';
import '../ui/auth/forgot_password_screen.dart';
import '../ui/auth/login_screen.dart';
import '../ui/auth/reset_password_screen.dart';
import '../ui/auth/session_gate_page.dart';
import '../ui/auth/signup_screen.dart';
import '../ui/auth/verify_email_screen.dart';
import '../ui/home/home_page.dart';
import '../ui/notifications/notifications_page.dart';
import '../ui/onboarding/onboarding_page.dart';
import '../ui/profile/profile_page.dart';
import '../ui/provider/provider_onboarding_page.dart';
import '../ui/requests/service_request_form_page.dart';
import '../ui/requests/service_request_history_page.dart';
import '../ui/requests/service_request_detail_page.dart';
import '../ui/shell/app_shell.dart';
import '../ui/shell/animated_branch_container.dart';
import 'app_routes.dart';
import 'global_navigator.dart';

/// The single authorization gate for normal navigation and deep links.
String? redirectForSession(SessionState session, String location) {
  final isAuthPage = const {
    AppRoutes.login,
    AppRoutes.signup,
    AppRoutes.forgotPassword,
    AppRoutes.verifyEmail,
    AppRoutes.resetPassword,
    AppRoutes.onboarding,
  }.contains(location);

  switch (session.status) {
    case SessionStatus.unknown:
    case SessionStatus.failure:
      return location == AppRoutes.splash ? null : AppRoutes.splash;
    case SessionStatus.passwordRecovery:
      return location == AppRoutes.resetPassword
          ? null
          : AppRoutes.resetPassword;
    case SessionStatus.authenticated:
      if (location == AppRoutes.providerOnboarding &&
          session.user?.role != UserRole.provider) {
        return AppRoutes.home;
      }
      if ((location == AppRoutes.serviceRequests ||
              location.startsWith('${AppRoutes.serviceRequests}/')) &&
          session.user?.role != UserRole.customer) {
        return AppRoutes.home;
      }
      return isAuthPage || location == AppRoutes.splash ? AppRoutes.home : null;
    case SessionStatus.unauthenticated:
      return isAuthPage ? null : AppRoutes.login;
  }
}

class AppRouter {
  AppRouter(SessionBloc session, {String initialLocation = AppRoutes.home})
    : _refresh = _SessionRefresh(session.stream) {
    router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: initialLocation,
      refreshListenable: _refresh,
      redirect: (_, state) =>
          redirectForSession(session.state, state.matchedLocation),
      routes: [
        GoRoute(
          path: AppRoutes.splash,
          name: AppRouteNames.splash,
          builder: (_, _) => const SessionGatePage(),
        ),
        GoRoute(
          path: AppRoutes.onboarding,
          name: AppRouteNames.onboarding,
          pageBuilder: (context, state) =>
              _motionPage(context, state, const OnboardingPage()),
        ),
        GoRoute(
          path: AppRoutes.login,
          name: AppRouteNames.login,
          pageBuilder: (context, state) =>
              _authPage(context, state, const LoginScreen()),
        ),
        GoRoute(
          path: AppRoutes.signup,
          name: AppRouteNames.signup,
          pageBuilder: (context, state) => _authPage(
            context,
            state,
            SignupScreen(
              initialRole:
                  state.uri.queryParameters['role'] == UserRole.provider.name
                  ? UserRole.provider
                  : UserRole.customer,
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.forgotPassword,
          name: AppRouteNames.forgotPassword,
          pageBuilder: (context, state) =>
              _authPage(context, state, const ForgotPasswordScreen()),
        ),
        GoRoute(
          path: AppRoutes.verifyEmail,
          name: AppRouteNames.verifyEmail,
          pageBuilder: (context, state) => _authPage(
            context,
            state,
            VerifyEmailScreen(email: state.uri.queryParameters['email'] ?? ''),
          ),
        ),
        GoRoute(
          path: AppRoutes.resetPassword,
          name: AppRouteNames.resetPassword,
          pageBuilder: (context, state) => _authPage(
            context,
            state,
            ResetPasswordScreen(
              email: state.uri.queryParameters['email'] ?? '',
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.providerOnboarding,
          name: AppRouteNames.providerOnboarding,
          // Account changes must also remove this page's private preview dialogs.
          pageBuilder: (context, state) => _motionPage(
            context,
            state,
            const ProviderOnboardingPage(),
            pageKey: ValueKey('provider-${session.state.user?.id}'),
          ),
        ),
        GoRoute(
          path: AppRoutes.serviceRequests,
          name: AppRouteNames.serviceRequests,
          pageBuilder: (context, state) => _motionPage(
            context,
            state,
            ServiceRequestHistoryPage(userId: session.state.user?.id ?? ''),
            pageKey: ValueKey('requests-${session.state.user?.id}'),
          ),
        ),
        GoRoute(
          path: AppRoutes.createServiceRequest,
          name: AppRouteNames.createServiceRequest,
          pageBuilder: (context, state) => _motionPage(
            context,
            state,
            ServiceRequestFormPage(
              userId: session.state.user?.id ?? '',
              initialCategoryId: state.uri.queryParameters['categoryId'],
              initialCity: session.state.user?.city ?? '',
            ),
            pageKey: ValueKey('request-form-${session.state.user?.id}'),
          ),
        ),
        GoRoute(
          path: AppRoutes.serviceRequestDetail,
          name: AppRouteNames.serviceRequestDetail,
          pageBuilder: (context, state) => _motionPage(
            context,
            state,
            ServiceRequestDetailPage(
              userId: session.state.user?.id ?? '',
              requestId: state.pathParameters['requestId']!,
            ),
            pageKey: ValueKey(
              'request-${session.state.user?.id}-${state.pathParameters['requestId']}',
            ),
          ),
        ),
        StatefulShellRoute(
          navigatorContainerBuilder: (_, navigationShell, children) =>
              AnimatedBranchContainer(
                currentIndex: navigationShell.currentIndex,
                children: children,
              ),
          pageBuilder: (_, _, navigationShell) => NoTransitionPage<void>(
            key: ValueKey('shell-${session.state.user?.id}'),
            child: AppShell(navigationShell: navigationShell),
          ),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: AppRoutes.home,
                  name: AppRouteNames.home,
                  builder: (_, _) => const HomePage(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: AppRoutes.notifications,
                  name: AppRouteNames.notifications,
                  builder: (_, _) => const NotificationsPage(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: AppRoutes.profile,
                  name: AppRouteNames.profile,
                  builder: (_, _) => const ProfilePage(),
                ),
              ],
            ),
          ],
        ),
      ],
      errorBuilder: (context, _) => Scaffold(
        body: AppEmptyState(
          title: 'common.not_found'.tr(),
          actionLabel: 'navigation.home'.tr(),
          onAction: () => context.goNamed(AppRouteNames.home),
        ),
      ),
    );
  }

  final _SessionRefresh _refresh;
  late final GoRouter router;

  Page<void> _authPage(
    BuildContext context,
    GoRouterState state,
    Widget child,
  ) => _motionPage(
    context,
    state,
    BlocProvider(
      create: (context) => AuthBloc(repository: context.read<AuthRepository>()),
      child: child,
    ),
  );

  Page<void> _motionPage(
    BuildContext context,
    GoRouterState state,
    Widget child, {
    LocalKey? pageKey,
  }) => CustomTransitionPage<void>(
    key: pageKey ?? state.pageKey,
    transitionDuration: AppMotion.durationOf(context, AppDurations.quick),
    reverseTransitionDuration: AppMotion.durationOf(context, AppDurations.fast),
    child: child,
    transitionsBuilder: (context, animation, _, child) {
      if (!AppMotion.isEnabled(context)) return child;
      final progress = animation.drive(CurveTween(curve: AppCurves.decelerate));
      return FadeTransition(
        opacity: progress,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.012),
            end: Offset.zero,
          ).animate(progress),
          child: child,
        ),
      );
    },
  );

  void dispose() {
    router.dispose();
    _refresh.dispose();
  }
}

class _SessionRefresh extends ChangeNotifier {
  _SessionRefresh(Stream<SessionState> stream) {
    // Profile edits/loading feedback do not change access or navigator identity.
    _subscription = stream
        .map((state) => (state.status, state.user?.id, state.user?.role))
        .distinct()
        .listen((_) => notifyListeners());
  }

  late final StreamSubscription<(SessionStatus, String?, UserRole?)>
  _subscription;

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
