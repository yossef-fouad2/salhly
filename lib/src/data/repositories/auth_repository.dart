import 'package:salahly/src/utils/typedefs.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/user_model.dart';

abstract class AuthRepository {
  bool get isDemo;

  Stream<AuthSession> get onAuthStateChanged;

  /// Sign in with email and password
  FutureEither<AppUser> login({
    required String email,
    required String password,
  });

  /// A signup without a session requires email confirmation, not navigation home.
  FutureEither<SignUpResult> signUp({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  });

  FutureEither<void> confirmEmail({required String email, required String code});

  FutureEither<void> resendConfirmation({required String email});

  FutureEither<void> forgotPassword({required String email});

  FutureEither<void> resetPassword({
    required String email,
    required String code,
    required String password,
  });

  FutureEither<AppUser> updateProfile({
    required String name,
    String? phone,
    String? city,
  });

  /// Sign out the current user
  FutureEither<void> logout();
  
  FutureEither<AuthSession> checkAuthState();

  Future<void> dispose();
}
