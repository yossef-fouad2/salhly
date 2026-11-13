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
  static const String providerRequestFeed = '/provider/requests';
  static const String providerQuote = '/provider/requests/:requestId/quote';
  static const String providerQuotes = '/provider/quotes';
  static const String requestQuotes = '/requests/:requestId/quotes';
  static const String requestMatches = '/requests/:requestId/matches';
  static const String providerMatchingSettings = '/provider/matching';
  static const String jobs = '/jobs';
  static const String jobDetail = '/jobs/:jobId';
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
  static const providerRequestFeed = 'providerRequestFeed';
  static const providerQuote = 'providerQuote';
  static const providerQuotes = 'providerQuotes';
  static const requestQuotes = 'requestQuotes';
  static const requestMatches = 'requestMatches';
  static const providerMatchingSettings = 'providerMatchingSettings';
  static const jobs = 'jobs';
  static const jobDetail = 'jobDetail';
}
