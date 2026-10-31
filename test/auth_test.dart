import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/routing/app_router.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/ui/auth/bloc/auth_bloc.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';

const _user = AppUser(
  id: 'customer-id',
  email: 'customer@example.com',
  name: 'Customer',
);

Future<T> _success<T>(FutureEither<T> task) async {
  return (await task).fold((failure) => fail(failure.message), (value) => value);
}

Future<AppUser> _login(DemoAuthRepository repository) => _success(repository.login(
      email: DemoAuthRepository.customerEmail,
      password: DemoAuthRepository.demoPassword,
    ));

void main() {
  group('Demo authentication', () {
    late DemoAuthRepository repository;
    setUp(() => repository = DemoAuthRepository());
    tearDown(() => repository.dispose());

    test('starts signed out without a backend', () async {
      expect(repository.isDemo, isTrue);
      expect((await _success(repository.checkAuthState())).user, isNull);
    });

    test('normalizes email and authenticates both sample roles', () async {
      final customer = await _success(repository.login(
        email: '  CUSTOMER@SALAHLY.DEMO  ',
        password: DemoAuthRepository.demoPassword,
      ));
      expect(customer.role, UserRole.customer);
      await _success(repository.logout());
      final provider = await _success(repository.login(
        email: DemoAuthRepository.providerEmail,
        password: DemoAuthRepository.demoPassword,
      ));
      expect(provider.role, UserRole.provider);
      expect(provider.id, isNot(customer.id));
    });

    test('rejects wrong passwords without creating a session', () async {
      final result = await repository.login(
        email: DemoAuthRepository.customerEmail,
        password: 'wrong-password',
      );
      expect(result.getLeft().toNullable()?.message, 'auth.invalid_credentials');
      expect((await _success(repository.checkAuthState())).user, isNull);
    });

    test('signup requires confirmation and preserves the selected role', () async {
      final result = await _success(repository.signUp(
        name: '  New Provider  ',
        email: '  NEW@example.com ',
        password: 'NewPassword123!',
        role: UserRole.provider,
      ));
      expect(result, SignUpResult.confirmationRequired);
      expect((await _success(repository.checkAuthState())).user, isNull);
      final unconfirmed = await repository.login(
        email: 'new@example.com',
        password: 'NewPassword123!',
      );
      expect(unconfirmed.getLeft().toNullable()?.message, 'auth.email_not_confirmed');
      expect((await repository.confirmEmail(email: 'new@example.com', code: '000000')).isLeft(), isTrue);

      await _success(repository.confirmEmail(
        email: 'new@example.com',
        code: DemoAuthRepository.demoCode,
      ));
      final user = (await _success(repository.checkAuthState())).user!;
      expect(user.name, 'New Provider');
      expect(user.email, 'new@example.com');
      expect(user.role, UserRole.provider);
      expect((await repository.confirmEmail(email: user.email, code: DemoAuthRepository.demoCode)).isLeft(), isTrue);
    });

    test('duplicate email and weak signup input fail', () async {
      final duplicate = await repository.signUp(
        name: 'Customer',
        email: DemoAuthRepository.customerEmail.toUpperCase(),
        password: 'Password123!',
        role: UserRole.provider,
      );
      expect(duplicate.getLeft().toNullable()?.message, 'auth.email_exists');
      final weak = await repository.signUp(
        name: 'New User',
        email: 'new@example.com',
        password: 'short',
        role: UserRole.customer,
      );
      expect(weak.getLeft().toNullable()?.message, 'auth.password_too_short');
    });

    test('recovery requires a requested code and changes the password', () async {
      final withoutRequest = await repository.resetPassword(
        email: DemoAuthRepository.customerEmail,
        code: DemoAuthRepository.demoCode,
        password: 'Replacement123!',
      );
      expect(withoutRequest.isLeft(), isTrue);
      await _success(repository.forgotPassword(email: DemoAuthRepository.customerEmail));
      await _success(repository.resetPassword(
        email: DemoAuthRepository.customerEmail,
        code: DemoAuthRepository.demoCode,
        password: 'Replacement123!',
      ));
      await _success(repository.logout());
      expect((await repository.login(
        email: DemoAuthRepository.customerEmail,
        password: DemoAuthRepository.demoPassword,
      )).isLeft(), isTrue);
      expect((await repository.login(
        email: DemoAuthRepository.customerEmail,
        password: 'Replacement123!',
      )).isRight(), isTrue);
      expect((await repository.resetPassword(
        email: DemoAuthRepository.customerEmail,
        code: DemoAuthRepository.demoCode,
        password: 'AnotherPassword123!',
      )).isLeft(), isTrue);
    });

    test('unknown recovery emails do not disclose account existence', () async {
      expect((await repository.forgotPassword(email: 'unknown@example.com')).isRight(), isTrue);
      expect((await repository.resetPassword(
        email: 'unknown@example.com',
        code: DemoAuthRepository.demoCode,
        password: 'Replacement123!',
      )).isLeft(), isTrue);
    });

    test('profile edits preserve identity and role and emit the updated session', () async {
      final original = await _login(repository);
      final next = repository.onAuthStateChanged.first;
      final updated = await _success(repository.updateProfile(
        name: '  Updated Name ',
        phone: '  +201234567890  ',
        city: '  Cairo  ',
      ));
      expect(updated.id, original.id);
      expect(updated.role, original.role);
      expect(updated.email, original.email);
      expect(updated.name, 'Updated Name');
      expect(updated.phone, '+201234567890');
      expect(updated.city, 'Cairo');
      expect((await next).user, updated);
      final cleared = await _success(repository.updateProfile(name: updated.name, phone: ' ', city: ''));
      expect(cleared.phone, isNull);
      expect(cleared.city, isNull);
      await _success(repository.logout());
      expect((await repository.updateProfile(name: 'Unauthorized')).isLeft(), isTrue);
    });

    test('a fresh demo repository does not restore accounts or sessions', () async {
      await _login(repository);
      await _success(repository.updateProfile(name: 'Changed'));
      final fresh = DemoAuthRepository();
      addTearDown(fresh.dispose);
      expect((await _success(fresh.checkAuthState())).user, isNull);
      expect((await _login(fresh)).name, 'Demo Customer');
    });
  });

  group('Auth and session state', () {
    test('signup emits confirmationRequired rather than authenticated', () async {
      final repository = DemoAuthRepository();
      final bloc = AuthBloc(repository: repository);
      addTearDown(repository.dispose);
      addTearDown(bloc.close);
      final completed = bloc.stream.firstWhere((state) => state.status == AuthStatus.confirmationRequired);
      bloc.add(const SignUpRequested(
        name: 'New Customer',
        email: 'new@example.com',
        password: 'Password123!',
        role: UserRole.customer,
      ));
      expect((await completed).email, 'new@example.com');
      expect((await _success(repository.checkAuthState())).user, isNull);
    });

    test('login failures are state, without a BuildContext', () async {
      final repository = DemoAuthRepository();
      final bloc = AuthBloc(repository: repository);
      addTearDown(repository.dispose);
      addTearDown(bloc.close);
      final failed = bloc.stream.firstWhere((state) => state.status == AuthStatus.failure);
      bloc.add(const LoginRequested(email: 'nobody@example.com', password: 'not-valid'));
      expect((await failed).errorMessage, 'auth.invalid_credentials');
      expect(bloc.state.isLoading, isFalse);
    });

    test('duplicate submissions do not start a second request', () async {
      final repository = _DelayedLoginRepository();
      final bloc = AuthBloc(repository: repository);
      addTearDown(repository.dispose);
      addTearDown(bloc.close);
      final completed = bloc.stream.firstWhere((state) => state.status == AuthStatus.authenticated);
      bloc.add(const LoginRequested(email: 'one@example.com', password: 'password'));
      bloc.add(const LoginRequested(email: 'two@example.com', password: 'password'));
      await repository.started.future;
      repository.response.complete(right(_user));
      await completed;
      expect(repository.calls, 1);
    });

    test('session follows login and logout', () async {
      final repository = DemoAuthRepository();
      final bloc = SessionBloc(repository: repository);
      addTearDown(repository.dispose);
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((state) => state.status == SessionStatus.unauthenticated);
      final loggedIn = bloc.stream.firstWhere((state) => state.status == SessionStatus.authenticated);
      await _login(repository);
      expect((await loggedIn).user?.role, UserRole.customer);
      final loggedOut = bloc.stream.firstWhere((state) => state.status == SessionStatus.unauthenticated);
      bloc.add(const SessionLogoutRequested());
      expect((await loggedOut).user, isNull);
    });

    test('a failed logout keeps the actual session and exposes an error', () async {
      final repository = _FailedLogoutRepository();
      final bloc = SessionBloc(repository: repository);
      addTearDown(repository.dispose);
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((state) => state.status == SessionStatus.unauthenticated);
      final loggedIn = bloc.stream.firstWhere((state) => state.status == SessionStatus.authenticated);
      await _login(repository);
      await loggedIn;
      final failed = bloc.stream.firstWhere((state) => state.errorMessage != null);
      bloc.add(const SessionLogoutRequested());
      final state = await failed;
      expect(state.status, SessionStatus.authenticated);
      expect(state.user, isNotNull);
      expect(state.isLoading, isFalse);
      expect(state.errorMessage, 'errors.network');
    });

    test('a stale startup check cannot overwrite a newer login', () async {
      final repository = _DelayedRestoreRepository();
      final bloc = SessionBloc(repository: repository);
      addTearDown(repository.dispose);
      await repository.started.future;
      final signedIn = bloc.stream.firstWhere((state) => state.status == SessionStatus.authenticated);
      await _login(repository);
      await signedIn;
      repository.response.complete(right(const AuthSession()));
      await bloc.close();
      expect(bloc.state.status, SessionStatus.authenticated);
    });
  });

  group('Central route guard', () {
    test('protects all three tabs when signed out', () {
      const session = SessionState(status: SessionStatus.unauthenticated);
      for (final route in [AppRoutes.home, AppRoutes.notifications, AppRoutes.profile]) {
        expect(redirectForSession(session, route), AppRoutes.login);
      }
      expect(redirectForSession(session, AppRoutes.signup), isNull);
      expect(redirectForSession(session, AppRoutes.verifyEmail), isNull);
    });

    test('authenticated users skip auth without disrupting tab navigation', () {
      const session = SessionState(status: SessionStatus.authenticated, user: _user);
      expect(redirectForSession(session, AppRoutes.login), AppRoutes.home);
      expect(redirectForSession(session, AppRoutes.profile), isNull);
    });

    test('recovery sessions cannot bypass the new-password form', () {
      final session = SessionState.fromSession(const AuthSession(user: _user, needsPasswordUpdate: true));
      expect(session.status, SessionStatus.passwordRecovery);
      expect(redirectForSession(session, AppRoutes.home), AppRoutes.resetPassword);
      expect(redirectForSession(session, AppRoutes.profile), AppRoutes.resetPassword);
      expect(redirectForSession(session, AppRoutes.login), AppRoutes.resetPassword);
      expect(redirectForSession(session, AppRoutes.resetPassword), isNull);
    });

    test('startup and session errors have a retryable gate', () {
      expect(redirectForSession(const SessionState(), AppRoutes.home), AppRoutes.splash);
      expect(redirectForSession(const SessionState(status: SessionStatus.failure), AppRoutes.home), AppRoutes.splash);
    });
  });
}

class _DelayedLoginRepository extends DemoAuthRepository {
  final response = Completer<Either<Failure, AppUser>>();
  final started = Completer<void>();
  int calls = 0;

  @override
  FutureEither<AppUser> login({required String email, required String password}) {
    calls++;
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}

class _FailedLogoutRepository extends DemoAuthRepository {
  @override
  FutureEither<void> logout() async => left(const NetworkFailure('errors.network'));
}

class _DelayedRestoreRepository extends DemoAuthRepository {
  final response = Completer<Either<Failure, AuthSession>>();
  final started = Completer<void>();

  @override
  FutureEither<AuthSession> checkAuthState() {
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}
