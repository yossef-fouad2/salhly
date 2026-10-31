import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../data/models/auth_session.dart';
import '../data/models/user_model.dart';
import '../utils/utils.dart';
import 'storage_service.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _recoveryKey = 'salahly.auth.password_recovery';
  final _changes = StreamController<AuthSession>.broadcast();
  StreamSubscription<AuthState>? _subscription;
  bool _needsPasswordUpdate = false;
  int _revision = 0;

  SupabaseClient get _client => AppConfig.supabase!;

  Stream<AuthSession> get authStateChanges {
    _ensureListening();
    return _changes.stream;
  }

  void _ensureListening() {
    if (_subscription != null) return;
    _needsPasswordUpdate = StorageService.instance.getBool(_recoveryKey) ?? false;
    _subscription = _client.auth.onAuthStateChange.listen(
      (event) => unawaited(_onAuthChange(event)),
      onError: (Object error, StackTrace trace) {
        if (!_changes.isClosed) _changes.addError(error, trace);
      },
    );
  }

  Future<void> _onAuthChange(AuthState event) async {
    final revision = ++_revision;
    final result = await runTask(() async {
      if (event.event == AuthChangeEvent.passwordRecovery) {
        await _setRecovery(true);
      } else if (event.event == AuthChangeEvent.signedOut) {
        await _setRecovery(false);
      }
      return _readSession();
    });
    // A late profile response must not resurrect a signed-out session.
    if (revision != _revision || _changes.isClosed) return;
    result.fold(_changes.addError, _changes.add);
  }

  void _emit(AuthSession session) {
    _revision++;
    if (!_changes.isClosed) _changes.add(session);
  }

  Future<void> _setRecovery(bool value) async {
    _needsPasswordUpdate = value;
    final result = await StorageService.instance.setBool(_recoveryKey, value);
    result.fold((failure) => throw failure, (saved) {
      if (!saved) throw const CacheFailure('errors.storage');
    });
  }

  Future<AppUser> _readUser(User authUser) async {
    final profile = await _client
        .from('profiles')
        .select('id,full_name,role,phone,city')
        .eq('id', authUser.id)
        .single();
    return AppUser.fromProfile(profile, email: authUser.email ?? '');
  }

  Future<AuthSession> _readSession() async {
    final session = _client.auth.currentSession;
    if (session == null) return const AuthSession();
    return AuthSession(
      user: await _readUser(session.user),
      needsPasswordUpdate: _needsPasswordUpdate,
    );
  }

  FutureEither<AuthSession> getCurrentSession() {
    _ensureListening();
    return runTask(_readSession);
  }

  FutureEither<AppUser> login({
    required String email,
    required String password,
  }) {
    return runTask(() async {
      await _setRecovery(false);
      final response = await _client.auth.signInWithPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );
      final session = response.session;
      if (session == null) throw const ServerFailure('auth.invalid_credentials');
      final user = await _readUser(session.user);
      _emit(AuthSession(user: user));
      return user;
    });
  }

  FutureEither<SignUpResult> signUp({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) {
    return runTask(() async {
      final response = await _client.auth.signUp(
        email: email.trim().toLowerCase(),
        password: password,
        data: {'full_name': name.trim(), 'role': role.name},
      );
      if (response.session == null) return SignUpResult.confirmationRequired;
      await _setRecovery(false);
      final user = await _readUser(response.session!.user);
      _emit(AuthSession(user: user));
      return SignUpResult.authenticated;
    });
  }

  FutureEither<void> confirmEmail({required String email, required String code}) {
    return runTask(() async {
      final response = await _client.auth.verifyOTP(
        email: email.trim().toLowerCase(),
        token: code.trim(),
        type: OtpType.signup,
      );
      if (response.session == null) throw const ServerFailure('auth.invalid_code');
      await _setRecovery(false);
      _emit(AuthSession(user: await _readUser(response.session!.user)));
    });
  }

  FutureEither<void> resendConfirmation({required String email}) {
    return runTask(() async {
      await _client.auth.resend(
        email: email.trim().toLowerCase(),
        type: OtpType.signup,
      );
    });
  }

  FutureEither<void> forgotPassword({required String email}) {
    return runTask(() async {
      await _client.auth.resetPasswordForEmail(email.trim().toLowerCase());
    });
  }

  FutureEither<void> resetPassword({
    required String email,
    required String code,
    required String password,
  }) {
    return runTask(() async {
      if (!_needsPasswordUpdate || _client.auth.currentSession == null) {
        // Persist only a flow flag. Supabase alone owns session/token storage.
        await _setRecovery(true);
        try {
          final response = await _client.auth.verifyOTP(
            email: email.trim().toLowerCase(),
            token: code.trim(),
            type: OtpType.recovery,
          );
          if (response.session == null) {
            throw const ServerFailure('auth.invalid_code');
          }
        } catch (_) {
          if (_client.auth.currentSession == null) await _setRecovery(false);
          rethrow;
        }
      }
      await _client.auth.updateUser(UserAttributes(password: password));
      await _setRecovery(false);
      _emit(await _readSession());
    });
  }

  FutureEither<AppUser> updateProfile({
    required String name,
    String? phone,
    String? city,
  }) {
    return runTask(() async {
      final authUser = _client.auth.currentSession?.user;
      if (authUser == null || _needsPasswordUpdate) {
        throw const ServerFailure('errors.not_authenticated');
      }
      final profile = await _client
          .from('profiles')
          .update({
            'full_name': name.trim(),
            'phone': AppUtils.isBlank(phone) ? null : phone!.trim(),
            'city': AppUtils.isBlank(city) ? null : city!.trim(),
          })
          .eq('id', authUser.id)
          .select('id,full_name,role,phone,city')
          .single();
      final user = AppUser.fromProfile(profile, email: authUser.email ?? '');
      _emit(AuthSession(user: user));
      return user;
    });
  }

  FutureEither<void> logout() {
    return runTask(() async {
      await _client.auth.signOut(scope: SignOutScope.local);
      await _setRecovery(false);
      _emit(const AuthSession());
    });
  }

  Future<void> dispose() async {
    _revision++;
    await _subscription?.cancel();
    await _changes.close();
  }
}
