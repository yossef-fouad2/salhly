import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/service_request.dart';
import '../../data/repositories/service_request_repository.dart';

class ServiceRequestHistoryState extends Equatable {
  const ServiceRequestHistoryState({
    this.items = const [],
    this.loaded = false,
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = false,
    this.errorMessage,
  });
  final List<ServiceRequest> items;
  final bool loaded;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final String? errorMessage;
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
  ];
}

class ServiceRequestHistoryCubit extends Cubit<ServiceRequestHistoryState> {
  ServiceRequestHistoryCubit({required this.userId, required this._repository})
    : super(const ServiceRequestHistoryState());
  final String userId;
  final ServiceRequestRepository _repository;

  Future<void> refresh() => _load(more: false);
  Future<void> loadMore() => _load(more: true);

  Future<void> _load({required bool more}) async {
    if (isClosed ||
        state.busy ||
        (more && (!state.hasMore || state.items.isEmpty))) {
      return;
    }
    emit(
      ServiceRequestHistoryState(
        items: state.items,
        loaded: state.loaded,
        loading: !more,
        loadingMore: more,
        hasMore: state.hasMore,
      ),
    );
    final result = await _repository.loadRequests(
      userId: userId,
      before: more ? state.items.last : null,
    );
    if (isClosed) return;
    result.fold(
      (failure) => emit(
        ServiceRequestHistoryState(
          items: state.items,
          loaded: state.loaded,
          hasMore: state.hasMore,
          errorMessage: failure.message,
        ),
      ),
      (page) {
        final records = {
          if (more)
            for (final request in state.items) request.id: request,
        };
        for (final request in page.items) {
          records[request.id] = request;
        }
        emit(
          ServiceRequestHistoryState(
            items: List.unmodifiable(records.values),
            loaded: true,
            hasMore: page.hasMore,
          ),
        );
      },
    );
  }
}
