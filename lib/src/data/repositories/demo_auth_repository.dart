import 'dart:async';

import '../../utils/utils.dart';
import '../models/auth_session.dart';
import '../models/user_model.dart';
import 'auth_repository.dart';

/// Local development only. Accounts and passwords disappear on app restart.
class DemoAuthRepository implements AuthRepository {
  DemoAuthRepository() {
    for (final role in UserRole.values) {
      final email = role == UserRole.customer ? customerEmail : providerEmail;
      _accounts[email] = _DemoAccount(
        user: AppUser(
          id: 'demo-${role.name}',
          email: email,
          name: role == UserRole.customer ? 'Demo Customer' : 'Demo Provider',
          role: role,
        ),
        password: demoPassword,
        confirmed: true,
      );
    }
  }

  static const customerEmail = 'customer@salahly.demo';
  static const providerEmail = 'provider@salahly.demo';
  static const demoPassword = 'Salahly123!';
  static const demoCode = '123456';

  final _changes = StreamController<AuthSession>.broadcast();
  final _accounts = <String, _DemoAccount>{};
  final _recoveryEmails = <String>{};
  AuthSession _session = const AuthSession();

  @override
  bool get isDemo => true;

  @override
  Stream<AuthSession> get onAuthStateChanged => _changes.stream;

  void _setSession(AuthSession session) {
    _session = session;
    _changes.add(session);
  }

  @override
  FutureEither<AuthSession> checkAuthState() => runTask(() async => _session);

  @override
  FutureEither<AppUser> login({
    required String email,
    required String password,
  }) {
    return runTask(() async {
      final account = _accounts[email.trim().toLowerCase()];
      if (account == null || account.password != password) {
        throw const ServerFailure('auth.invalid_credentials');
      }
      if (!account.confirmed) {
        throw const ServerFailure('auth.email_not_confirmed');
      }
      _setSession(AuthSession(user: account.user));
      return account.user;
    });
  }

  @override
  FutureEither<SignUpResult> signUp({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) {
    return runTask(() async {
      final normalizedEmail = email.trim().toLowerCase();
      if (_accounts.containsKey(normalizedEmail)) {
        throw const ServerFailure('auth.email_exists');
      }
      if (!AppUtils.isValidEmail(normalizedEmail)) {
        throw const ServerFailure('auth.email_invalid');
      }
      if (name.trim().length < 2 || name.trim().length > 80) {
        throw const ServerFailure('auth.name_length');
      }
      if (password.length < 8) {
        throw const ServerFailure('auth.password_too_short');
      }
      _accounts[normalizedEmail] = _DemoAccount(
        user: AppUser(
          id: 'demo-user-${_accounts.length + 1}',
          email: normalizedEmail,
          name: name.trim(),
          role: role,
        ),
        password: password,
      );
      return SignUpResult.confirmationRequired;
    });
  }

  @override
  FutureEither<void> confirmEmail({required String email, required String code}) {
    return runTask(() async {
      final account = _accounts[email.trim().toLowerCase()];
      if (account == null || account.confirmed || code.trim() != demoCode) {
        throw const ServerFailure('auth.invalid_code');
      }
      account.confirmed = true;
      _setSession(AuthSession(user: account.user));
    });
  }

  @override
  FutureEither<void> resendConfirmation({required String email}) {
    // Just like the live endpoint, do not reveal whether an account exists.
    return runTask(() async {});
  }

  @override
  FutureEither<void> forgotPassword({required String email}) {
    return runTask(() async {
      final normalizedEmail = email.trim().toLowerCase();
      if (_accounts[normalizedEmail]?.confirmed ?? false) {
        _recoveryEmails.add(normalizedEmail);
      }
    });
  }

  @override
  FutureEither<void> resetPassword({
    required String email,
    required String code,
    required String password,
  }) {
    return runTask(() async {
      final normalizedEmail = email.trim().toLowerCase();
      final account = _accounts[normalizedEmail];
      if (account == null ||
          !_recoveryEmails.contains(normalizedEmail) ||
          code.trim() != demoCode) {
        throw const ServerFailure('auth.invalid_code');
      }
      if (password.length < 8) {
        throw const ServerFailure('auth.password_too_short');
      }
      if (password == account.password) {
        throw const ServerFailure('auth.same_password');
      }
      account.password = password;
      _recoveryEmails.remove(normalizedEmail);
      _setSession(AuthSession(user: account.user));
    });
  }

  @override
  FutureEither<AppUser> updateProfile({
    required String name,
    String? phone,
    String? city,
  }) {
    return runTask(() async {
      final user = _session.user;
      if (user == null || _session.needsPasswordUpdate) {
        throw const ServerFailure('errors.not_authenticated');
      }
      if (name.trim().length < 2 || name.trim().length > 80) {
        throw const ServerFailure('auth.name_length');
      }
      if ((phone?.trim().length ?? 0) > 32 ||
          (city?.trim().length ?? 0) > 100) {
        throw const ServerFailure('errors.invalid_profile');
      }
      final updated = user.withProfile(
        name: name.trim(),
        phone: AppUtils.isBlank(phone) ? null : phone!.trim(),
        city: AppUtils.isBlank(city) ? null : city!.trim(),
      );
      _accounts[user.email]!.user = updated;
      _setSession(AuthSession(user: updated));
      return updated;
    });
  }

  @override
  FutureEither<void> logout() => runTask(() async {
        _setSession(const AuthSession());
      });

  @override
  Future<void> dispose() => _changes.close();
}

class _DemoAccount {
  _DemoAccount({
    required this.user,
    required this.password,
    this.confirmed = false,
  });

  AppUser user;
  String password;
  bool confirmed;
}
