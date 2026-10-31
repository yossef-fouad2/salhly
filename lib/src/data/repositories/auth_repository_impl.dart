import '../../services/auth_service.dart';
import '../../utils/typedefs.dart';
import '../models/auth_session.dart';
import '../models/user_model.dart';
import 'auth_repository.dart';

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl({AuthService? authService})
      : _authService = authService ?? AuthService.instance;

  final AuthService _authService;

  @override
  bool get isDemo => false;

  @override
  Stream<AuthSession> get onAuthStateChanged => _authService.authStateChanges;

  @override
  FutureEither<AppUser> login({
    required String email,
    required String password,
  }) => _authService.login(email: email, password: password);

  @override
  FutureEither<SignUpResult> signUp({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) => _authService.signUp(
      name: name,
      email: email,
      password: password,
      role: role,
    );

  @override
  FutureEither<void> confirmEmail({required String email, required String code}) =>
      _authService.confirmEmail(email: email, code: code);

  @override
  FutureEither<void> resendConfirmation({required String email}) =>
      _authService.resendConfirmation(email: email);

  @override
  FutureEither<void> forgotPassword({required String email}) {
    return _authService.forgotPassword(email: email);
  }

  @override
  FutureEither<void> resetPassword({
    required String email,
    required String code,
    required String password,
  }) => _authService.resetPassword(email: email, code: code, password: password);

  @override
  FutureEither<AppUser> updateProfile({
    required String name,
    String? phone,
    String? city,
  }) => _authService.updateProfile(name: name, phone: phone, city: city);

  @override
  FutureEither<void> logout() => _authService.logout();

  @override
  FutureEither<AuthSession> checkAuthState() => _authService.getCurrentSession();

  @override
  Future<void> dispose() => _authService.dispose();
}
