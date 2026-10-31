import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/models/auth_session.dart';
import '../../../data/models/user_model.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../utils/typedefs.dart';

enum AuthStatus {
  idle,
  submitting,
  authenticated,
  confirmationRequired,
  confirmationSent,
  recoveryCodeSent,
  passwordUpdated,
  failure,
}

class AuthState extends Equatable {
  const AuthState({
    this.status = AuthStatus.idle,
    this.email,
    this.errorMessage,
  });

  final AuthStatus status;
  final String? email;
  final String? errorMessage;

  bool get isLoading => status == AuthStatus.submitting;

  @override
  List<Object?> get props => [status, email, errorMessage];
}

sealed class AuthEvent {
  const AuthEvent();
}

class LoginRequested extends AuthEvent {
  const LoginRequested({required this.email, required this.password});
  final String email;
  final String password;
}

class SignUpRequested extends AuthEvent {
  const SignUpRequested({
    required this.name,
    required this.email,
    required this.password,
    required this.role,
  });
  final String name;
  final String email;
  final String password;
  final UserRole role;
}

class EmailConfirmationRequested extends AuthEvent {
  const EmailConfirmationRequested({required this.email, required this.code});
  final String email;
  final String code;
}

class ConfirmationResendRequested extends AuthEvent {
  const ConfirmationResendRequested({required this.email});
  final String email;
}

class ForgotPasswordRequested extends AuthEvent {
  const ForgotPasswordRequested({required this.email});
  final String email;
}

class PasswordResetRequested extends AuthEvent {
  const PasswordResetRequested({
    required this.email,
    required this.code,
    required this.password,
  });
  final String email;
  final String code;
  final String password;
}

/// Form commands only. Session state and navigation live outside this bloc.
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc({required this._repository})
      : super(const AuthState()) {
    on<LoginRequested>((event, emit) => _submit(
          emit,
          email: event.email,
          action: () => _repository.login(
            email: event.email,
            password: event.password,
          ),
          success: (_) => const AuthState(status: AuthStatus.authenticated),
        ));
    on<SignUpRequested>((event, emit) => _submit(
          emit,
          email: event.email,
          action: () => _repository.signUp(
            name: event.name,
            email: event.email,
            password: event.password,
            role: event.role,
          ),
          success: (result) => AuthState(
            status: result == SignUpResult.confirmationRequired
                ? AuthStatus.confirmationRequired
                : AuthStatus.authenticated,
            email: event.email.trim().toLowerCase(),
          ),
        ));
    on<EmailConfirmationRequested>((event, emit) => _submit(
          emit,
          action: () => _repository.confirmEmail(
            email: event.email,
            code: event.code,
          ),
          success: (_) => const AuthState(status: AuthStatus.authenticated),
        ));
    on<ConfirmationResendRequested>((event, emit) => _submit(
          emit,
          action: () => _repository.resendConfirmation(email: event.email),
          success: (_) => const AuthState(status: AuthStatus.confirmationSent),
        ));
    on<ForgotPasswordRequested>((event, emit) => _submit(
          emit,
          action: () => _repository.forgotPassword(email: event.email),
          success: (_) => AuthState(
            status: AuthStatus.recoveryCodeSent,
            email: event.email.trim().toLowerCase(),
          ),
        ));
    on<PasswordResetRequested>((event, emit) => _submit(
          emit,
          action: () => _repository.resetPassword(
            email: event.email,
            code: event.code,
            password: event.password,
          ),
          success: (_) => const AuthState(status: AuthStatus.passwordUpdated),
        ));
  }

  final AuthRepository _repository;

  Future<void> _submit<T>(
    Emitter<AuthState> emit, {
    required FutureEither<T> Function() action,
    required AuthState Function(T) success,
    String? email,
  }) async {
    if (state.isLoading) return;
    emit(const AuthState(status: AuthStatus.submitting));
    final result = await action();
    if (emit.isDone) return;
    result.fold(
      (failure) => emit(AuthState(
        status: failure.message == 'auth.email_not_confirmed' && email != null
            ? AuthStatus.confirmationRequired
            : AuthStatus.failure,
        errorMessage: failure.message,
        email: email?.trim().toLowerCase(),
      )),
      (value) => emit(success(value)),
    );
  }
}
