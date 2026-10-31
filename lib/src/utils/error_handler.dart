import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'failure.dart';

class AppErrorHandler {
  /// Return a translation key, not backend details or a UI side effect.
  static String format(Object error) {
    if (error is Failure) return error.message;
    if (error is TimeoutException || error is AuthRetryableFetchException) {
      return 'errors.network';
    }
    if (error is AuthException) {
      return switch (error.code) {
        'invalid_credentials' => 'auth.invalid_credentials',
        'email_not_confirmed' => 'auth.email_not_confirmed',
        'user_already_exists' || 'email_exists' => 'auth.email_exists',
        'otp_expired' || 'otp_disabled' => 'auth.invalid_code',
        'over_email_send_rate_limit' ||
        'over_request_rate_limit' ||
        'over_sms_send_rate_limit' => 'auth.rate_limited',
        'weak_password' => 'auth.password_too_short',
        'same_password' => 'auth.same_password',
        _ => 'errors.auth_failed',
      };
    }
    if (error is PostgrestException) {
      return switch (error.code) {
        '42P01' || 'PGRST205' || 'PGRST116' => 'errors.database_setup',
        _ => 'errors.request_failed',
      };
    }
    return 'errors.unexpected';
  }
}
