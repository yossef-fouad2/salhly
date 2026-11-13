import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/marketplace.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../../utils/failure.dart';
import '../auth/bloc/session_bloc.dart';
import 'marketplace_session.dart';

class JobDetailState extends Equatable {
  const JobDetailState({
    this.role,
    this.job,
    this.loading = false,
    this.transitioning = false,
    this.uncertain = false,
    this.pendingTarget,
    this.errorMessage,
    this.revoked = false,
  });
  final UserRole? role;
  final ServiceJob? job;
  final bool loading;
  final bool transitioning;
  final bool uncertain;
  final JobStatus? pendingTarget;
  final String? errorMessage;
  final bool revoked;
  bool get busy => loading || transitioning;
  List<JobStatus> get actions =>
      role == null ? const [] : job?.status.actionsFor(role!) ?? const [];

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    role,
    job,
    loading,
    transitioning,
    uncertain,
    pendingTarget,
    errorMessage,
    revoked,
  ];
}

class JobDetailCubit extends Cubit<JobDetailState> {
  JobDetailCubit({
    required this.userId,
    required this.jobId,
    required this._repository,
    required SessionBloc session,
  }) : super(const JobDetailState()) {
    _session = MarketplaceSession(
      session: session,
      userId: userId,
      onRevoked: _clear,
    );
  }
  final String userId;
  final String jobId;
  final MarketplaceRepository _repository;
  late final MarketplaceSession _session;
  ServiceJob? _pendingJob;

  bool _owns(ServiceJob job) => job.id == jobId && job.roleFor(userId) != null;

  Future<void> load() async {
    if (isClosed || !_session.active || state.busy || state.uncertain) return;
    final pending = _repository.hasPendingOperation(jobId, userId: userId);
    emit(
      JobDetailState(
        role: state.role,
        job: state.job,
        loading: true,
        uncertain: pending,
      ),
    );
    final result = await _repository.loadJob(jobId, userId: userId);
    if (isClosed || !_session.active) return;
    result.fold(_failRead, (job) {
      if (!_owns(job)) return _session.revoke();
      emit(
        JobDetailState(role: job.roleFor(userId), job: job, uncertain: pending),
      );
    });
  }

  Future<void> transition(JobStatus target) async {
    if (isClosed ||
        !_session.active ||
        state.busy ||
        state.uncertain ||
        !state.actions.contains(target)) {
      return;
    }
    _pendingJob = state.job;
    await _runPending(target);
  }

  Future<void> retryPending() async {
    if (isClosed || !_session.active || state.busy || !state.uncertain) return;
    if (_pendingJob != null && state.pendingTarget != null) {
      await _runPending(state.pendingTarget!);
      return;
    }
    emit(
      JobDetailState(
        role: state.role,
        job: state.job,
        transitioning: true,
        uncertain: true,
      ),
    );
    final result = await _repository.retryPending(jobId, userId: userId);
    if (isClosed || !_session.active) return;
    String? error;
    result.fold((failure) {
      error = failure.message;
      if (marketplaceAccessError(failure.message)) return _session.revoke();
      emit(
        JobDetailState(
          role: state.role,
          job: state.job,
          uncertain: marketplaceStillUncertain(true, failure.message),
          errorMessage: failure.message,
        ),
      );
    }, (_) => emit(JobDetailState(role: state.role, job: state.job)));
    if (_session.active && !state.uncertain) {
      await load();
      if (!isClosed && _session.active && error != null) {
        emit(
          JobDetailState(role: state.role, job: state.job, errorMessage: error),
        );
      }
    }
  }

  Future<void> _runPending(JobStatus target) async {
    final job = _pendingJob!;
    emit(
      JobDetailState(
        role: state.role,
        job: state.job,
        transitioning: true,
        uncertain: state.uncertain,
        pendingTarget: target,
      ),
    );
    final result = await _repository.transitionJob(job, target, userId: userId);
    if (isClosed || !_session.active) return;
    result.fold(
      (failure) {
        if (marketplaceAccessError(failure.message)) return _session.revoke();
        final uncertain = marketplaceStillUncertain(
          state.uncertain,
          failure.message,
        );
        if (!uncertain) _pendingJob = null;
        emit(
          JobDetailState(
            role: state.role,
            job: state.job,
            uncertain: uncertain,
            pendingTarget: uncertain ? target : null,
            errorMessage: failure.message,
          ),
        );
      },
      (updated) {
        if (!_owns(updated)) return _session.revoke();
        _pendingJob = null;
        emit(JobDetailState(role: updated.roleFor(userId), job: updated));
      },
    );
  }

  void _failRead(Failure failure) {
    if (marketplaceAccessError(failure.message)) return _session.revoke();
    emit(
      JobDetailState(
        role: state.role,
        job: state.job,
        uncertain: state.uncertain,
        errorMessage: failure.message,
      ),
    );
  }

  void _clear() {
    _pendingJob = null;
    if (!isClosed) {
      emit(
        const JobDetailState(
          revoked: true,
          errorMessage: 'marketplace.errors.access',
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    await _session.close();
    _pendingJob = null;
    return super.close();
  }
}
