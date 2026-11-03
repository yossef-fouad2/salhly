/// Centralized route path constants for GoRouter.
///
/// Use these variables instead of raw strings throughout the app.
/// Example: `context.go(AppRoutes.onboarding)` instead of `context.go('/')`.
abstract final class AppRoutes {
  AppRoutes._();

  static const String splash = '/splash';
  static const String home = '/';
  static const String onboarding = '/onboarding';
  static const String login = '/login';
  static const String signup = '/signup';
  static const String forgotPassword = '/forgot-password';
  static const String verifyEmail = '/verify-email';
  static const String resetPassword = '/reset-password';
  static const String notifications = '/notifications';
  static const String profile = '/profile';
  static const String providerOnboarding = '/provider-onboarding';
  static const String serviceRequests = '/requests';
  static const String createServiceRequest = '/requests/new';
  static const String serviceRequestDetail = '/requests/:requestId';
}

abstract final class AppRouteNames {
  static const splash = 'splash';
  static const onboarding = 'onboarding';
  static const login = 'login';
  static const signup = 'signup';
  static const forgotPassword = 'forgotPassword';
  static const verifyEmail = 'verifyEmail';
  static const resetPassword = 'resetPassword';
  static const home = 'home';
  static const notifications = 'notifications';
  static const profile = 'profile';
  static const providerOnboarding = 'providerOnboarding';
  static const serviceRequests = 'serviceRequests';
  static const createServiceRequest = 'createServiceRequest';
  static const serviceRequestDetail = 'serviceRequestDetail';
}
