import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/marketplace.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../auth/bloc/session_bloc.dart';
import 'marketplace_session.dart';

class JobsState extends Equatable {
  const JobsState({
    this.items = const [],
    this.loaded = false,
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = false,
    this.errorMessage,
    this.revoked = false,
  });
  final List<ServiceJob> items;
  final bool loaded;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final String? errorMessage;
  final bool revoked;
  bool get busy => loading || loadingMore;
  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    items,
    loaded,
    loading,
    loadingMore,
    hasMore,
    errorMessage,
    revoked,
  ];
}

class JobsCubit extends Cubit<JobsState> {
  JobsCubit({
    required this.userId,
    required this._repository,
    required SessionBloc session,
  }) : super(const JobsState()) {
    _session = MarketplaceSession(
      session: session,
      userId: userId,
      onRevoked: _clear,
    );
  }
  final String userId;
  final MarketplaceRepository _repository;
  late final MarketplaceSession _session;

  Future<void> refresh() => _load(more: false);
  Future<void> loadMore() => _load(more: true);

  Future<void> _load({required bool more}) async {
    if (isClosed ||
        !_session.active ||
        state.busy ||
        (more && (!state.hasMore || state.items.isEmpty))) {
      return;
    }
    final previous = state;
    emit(
      JobsState(
        items: previous.items,
        loaded: previous.loaded,
        loading: !more,
        loadingMore: more,
        hasMore: previous.hasMore,
      ),
    );
    final result = await _repository.loadJobs(
      userId: userId,
      before: more ? previous.items.last.cursor : null,
    );
    if (isClosed || !_session.active) return;
    result.fold(
      (failure) {
        if (marketplaceAccessError(failure.message)) return _session.revoke();
        emit(
          JobsState(
            items: previous.items,
            loaded: previous.loaded,
            hasMore: previous.hasMore,
            errorMessage: failure.message,
          ),
        );
      },
      (page) {
        if (page.items.any((job) => job.roleFor(userId) == null)) {
          return _session.revoke();
        }
        final records = {
          if (more)
            for (final job in previous.items) job.id: job,
          for (final job in page.items) job.id: job,
        };
        emit(
          JobsState(
            items: List.unmodifiable(records.values),
            loaded: true,
            hasMore: page.hasMore && page.items.isNotEmpty,
          ),
        );
      },
    );
  }

  void _clear() {
    if (!isClosed) {
      emit(
        const JobsState(
          revoked: true,
          errorMessage: 'marketplace.errors.access',
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    await _session.close();
    return super.close();
  }
}
