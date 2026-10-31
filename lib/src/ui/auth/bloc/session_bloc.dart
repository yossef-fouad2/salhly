import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/models/auth_session.dart';
import '../../../data/models/user_model.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../utils/error_handler.dart';

sealed class SessionEvent {
  const SessionEvent();
}

class SessionCheckRequested extends SessionEvent {
  const SessionCheckRequested();
}

class SessionUserChanged extends SessionEvent {
  const SessionUserChanged(this.session);
  final AuthSession session;
}

class SessionLogoutRequested extends SessionEvent {
  const SessionLogoutRequested();
}

class _SessionFailed extends SessionEvent {
  const _SessionFailed(this.message);
  final String message;
}

enum SessionStatus {
  unknown,
  authenticated,
  unauthenticated,
  passwordRecovery,
  failure,
}

class SessionState extends Equatable {
  const SessionState({
    this.status = SessionStatus.unknown,
    this.user,
    this.isLoading = false,
    this.errorMessage,
  });

  factory SessionState.fromSession(AuthSession session) => SessionState(
        status: session.user == null
            ? SessionStatus.unauthenticated
            : session.needsPasswordUpdate
                ? SessionStatus.passwordRecovery
                : SessionStatus.authenticated,
        user: session.user,
      );

  final SessionStatus status;
  final AppUser? user;
  final bool isLoading;
  final String? errorMessage;

  @override
  List<Object?> get props => [status, user, isLoading, errorMessage];
}

class SessionBloc extends Bloc<SessionEvent, SessionState> {
  SessionBloc({required this._repository})
      : super(const SessionState()) {
    on<SessionCheckRequested>(_check);
    on<SessionUserChanged>((event, emit) {
      _revision++;
      emit(SessionState.fromSession(event.session));
    });
    on<_SessionFailed>((event, emit) {
      _revision++;
      emit(SessionState(status: SessionStatus.failure, errorMessage: event.message));
    });
    on<SessionLogoutRequested>(_logout);

    // Subscribe before checking so a sign-in during startup cannot be missed.
    _subscription = _repository.onAuthStateChanged.listen(
      (session) => add(SessionUserChanged(session)),
      onError: (Object error) => add(_SessionFailed(AppErrorHandler.format(error))),
    );
    add(const SessionCheckRequested());
  }

  final AuthRepository _repository;
  late final StreamSubscription<AuthSession> _subscription;
  int _revision = 0;

  Future<void> _check(SessionCheckRequested event, Emitter<SessionState> emit) async {
    final revision = ++_revision;
    final result = await _repository.checkAuthState();
    if (emit.isDone || revision != _revision) return;
    result.fold(
      (failure) => emit(SessionState(
        status: SessionStatus.failure,
        errorMessage: failure.message,
      )),
      (session) => emit(SessionState.fromSession(session)),
    );
  }

  Future<void> _logout(SessionLogoutRequested event, Emitter<SessionState> emit) async {
    if (state.isLoading) return;
    final revision = ++_revision;
    final previous = state;
    emit(SessionState(status: state.status, user: state.user, isLoading: true));
    final result = await _repository.logout();
    if (emit.isDone || revision != _revision) return;
    result.fold(
      (failure) => emit(SessionState(
        status: previous.status,
        user: previous.user,
        errorMessage: failure.message,
      )),
      (_) => emit(const SessionState(status: SessionStatus.unauthenticated)),
    );
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    return super.close();
  }
}
