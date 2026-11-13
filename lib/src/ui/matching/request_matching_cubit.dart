import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/matching.dart';
import '../../data/models/service_request.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/matching_repository.dart';
import '../../utils/failure.dart';
import '../auth/bloc/session_bloc.dart';
import '../marketplace/marketplace_session.dart';

enum MatchingOperation { idle, loading, loadingMore }

class RequestMatchingState extends Equatable {
  const RequestMatchingState({
    required this.query,
    this.appliedQuery,
    this.results,
    this.operation = MatchingOperation.idle,
    this.stale = false,
    this.formVersion = 0,
    this.errorMessage,
    this.revoked = false,
  });

  final MatchingQuery query;
  final MatchingQuery? appliedQuery;
  final MatchResults? results;
  final MatchingOperation operation;
  final bool stale;
  final int formVersion;
  final String? errorMessage;
  final bool revoked;

  bool get busy => operation != MatchingOperation.idle;
  bool get hasUnappliedChanges => query != appliedQuery;
  bool get showingPrevious => results != null && (hasUnappliedChanges || stale);
  bool get canLoadMore =>
      !busy &&
      !revoked &&
      !stale &&
      !hasUnappliedChanges &&
      results?.hasMore == true &&
      results!.items.isNotEmpty;

  static const _unchanged = Object();

  RequestMatchingState copyWith({
    MatchingQuery? query,
    MatchingQuery? appliedQuery,
    Object? results = _unchanged,
    MatchingOperation? operation,
    bool? stale,
    int? formVersion,
    String? errorMessage,
  }) => RequestMatchingState(
    query: query ?? this.query,
    appliedQuery: appliedQuery ?? this.appliedQuery,
    results: identical(results, _unchanged)
        ? this.results
        : results as MatchResults?,
    operation: operation ?? this.operation,
    stale: stale ?? this.stale,
    formVersion: formVersion ?? this.formVersion,
    errorMessage: errorMessage,
    revoked: revoked,
  );

  @override
  bool get stringify => false;

  @override
  List<Object?> get props => [
    query,
    appliedQuery,
    results,
    operation,
    stale,
    formVersion,
    errorMessage,
    revoked,
  ];
}

class RequestMatchingCubit extends Cubit<RequestMatchingState> {
  RequestMatchingCubit({
    required this.userId,
    required this.requestId,
    required this._repository,
    required SessionBloc session,
    DateTime Function()? now,
    this.staleAfter = const Duration(minutes: 5),
  }) : _now = now ?? DateTime.now,
       super(RequestMatchingState(query: MatchingQuery(requestId: requestId))) {
    _session = MarketplaceSession(
      session: session,
      userId: userId,
      role: UserRole.customer,
      onRevoked: _clear,
    );
    if (!_session.active) _clear();
  }

  final String userId;
  final String requestId;
  final MatchingRepository _repository;
  final DateTime Function() _now;
  final Duration staleAfter;
  late final MarketplaceSession _session;
  DateTime? _loadedAt;
  MatchingQuery? _inFlightQuery;
  int _readVersion = 0;
  Timer? _staleTimer;
  bool _pageVisible = true;

  bool get active => !isClosed && _session.active;

  set pageVisible(bool value) => _pageVisible = value;

  void updateLatitude(String value) =>
      _edit(state.query.copyWith(latitude: value, locationConsent: false));
  void updateLongitude(String value) =>
      _edit(state.query.copyWith(longitude: value, locationConsent: false));
  void setLocationConsent(bool value) =>
      _edit(state.query.copyWith(locationConsent: value));
  void setWeekday(int? value) => _edit(state.query.copyWith(weekday: value));
  void updateTime(String value) => _edit(state.query.copyWith(time: value));

  void _edit(MatchingQuery query) {
    if (active) emit(state.copyWith(query: query));
  }

  Future<void> setMode(MatchMode mode) async {
    if (!active || mode == state.query.mode) return;
    _edit(state.query.copyWith(mode: mode));
    await apply();
  }

  Future<void> clearInputs() async {
    if (!active) return;
    emit(
      state.copyWith(
        query: MatchingQuery(requestId: requestId, mode: state.query.mode),
        formVersion: state.formVersion + 1,
      ),
    );
    await apply();
  }

  Future<void> apply() async {
    if (!active) return;
    final error = state.query.validate();
    if (error != null) {
      emit(state.copyWith(errorMessage: error));
      return;
    }
    if (state.busy && _inFlightQuery == state.query) return;
    await _load(state.query, more: false);
  }

  Future<void> refresh() async {
    if (!active || state.busy) return;
    await _load(state.appliedQuery ?? state.query, more: false);
  }

  void markStale() {
    if (active && state.results != null) emit(state.copyWith(stale: true));
  }

  Future<void> refreshIfStale({bool force = false}) async {
    if (!active || state.busy) return;
    if (force || _isStale) await refresh();
  }

  bool get _isStale =>
      state.stale ||
      _loadedAt == null ||
      _now().difference(_loadedAt!) >= staleAfter;

  Future<void> loadMore() async {
    if (!active || state.busy) return;
    if (_isStale) return refresh();
    if (state.canLoadMore) await _load(state.appliedQuery!, more: true);
  }

  Future<void> _load(MatchingQuery query, {required bool more}) async {
    final validation = query.validate();
    if (!active || validation != null) {
      if (active) emit(state.copyWith(errorMessage: validation));
      return;
    }
    final version = ++_readVersion;
    final previous = state.results;
    _inFlightQuery = query;
    emit(
      state.copyWith(
        operation: more
            ? MatchingOperation.loadingMore
            : MatchingOperation.loading,
        stale: !more && previous != null,
      ),
    );
    final result = await _repository.loadMatches(
      query,
      userId: userId,
      before: more
          ? previous!.items.last.cursor(
              previous.rules,
              query.mode,
              query: query,
            )
          : null,
      limit: 20,
    );
    if (!active || version != _readVersion) return;
    _inFlightQuery = null;
    var restart = false;
    result.fold(
      (failure) {
        restart =
            more &&
            const {
              'matching.errors.stale',
              'matching.errors.invalid',
            }.contains(failure.message);
        if (restart) {
          emit(state.copyWith(operation: MatchingOperation.idle, stale: true));
        } else {
          _failRead(failure);
        }
      },
      (page) {
        if (page.listing.requestId != requestId) return _session.revoke();
        if (page.listing.requestStatus != ServiceRequestStatus.open) {
          _failRead(const ServerFailure('matching.errors.status'));
          return;
        }
        if (page.mode != query.mode ||
            (more &&
                (page.rules != previous!.rules ||
                    page.mode != previous.mode))) {
          restart = more;
          emit(
            state.copyWith(
              operation: MatchingOperation.idle,
              stale: true,
              errorMessage: 'matching.errors.stale',
            ),
          );
          return;
        }
        final priorById = {
          if (more)
            for (final item in previous!.items) item.providerId: item,
        };
        final changedDuplicate =
            more &&
            page.items.any(
              (item) =>
                  priorById[item.providerId] != null &&
                  priorById[item.providerId] != item,
            );
        final items = {
          if (more)
            for (final item in previous!.items) item.providerId: item,
          for (final item in page.items) item.providerId: item,
        };
        final merged = items.values.toList(growable: false);
        var outOfOrder = false;
        for (var index = 1; index < merged.length; index++) {
          if (compareProviderMatches(
                merged[index - 1],
                merged[index],
                query.mode,
              ) >=
              0) {
            outOfOrder = true;
            break;
          }
        }
        if (more &&
            (changedDuplicate ||
                outOfOrder ||
                page.listing != previous!.listing)) {
          restart = true;
          emit(
            state.copyWith(
              operation: MatchingOperation.idle,
              stale: true,
              errorMessage: 'matching.errors.stale',
            ),
          );
          return;
        }
        _loadedAt = _now();
        _staleTimer?.cancel();
        _staleTimer = Timer(staleAfter, () {
          markStale();
          if (active && _pageVisible && !state.busy) unawaited(refresh());
        });
        emit(
          state.copyWith(
            results: MatchResults(
              listing: page.listing,
              rules: page.rules,
              mode: page.mode,
              items: merged,
              hasMore: page.hasMore && page.items.isNotEmpty,
            ),
            appliedQuery: query,
            operation: MatchingOperation.idle,
            stale: false,
          ),
        );
      },
    );
    // Never append a cursor page computed with different rules or filters.
    if (restart && active && version == _readVersion) {
      await _load(query, more: false);
    }
  }

  void _failRead(Failure failure) {
    if (marketplaceAccessError(failure.message) ||
        const {
          'matching.errors.access',
          'matching.errors.not_found',
        }.contains(failure.message)) {
      return _session.revoke();
    }
    final unavailable = const {
      'matching.errors.unpublished',
      'matching.errors.status',
    }.contains(failure.message);
    emit(
      state.copyWith(
        results: unavailable ? null : state.results,
        operation: MatchingOperation.idle,
        stale: !unavailable && state.results != null,
        errorMessage: failure.message,
      ),
    );
  }

  void _clear() {
    _readVersion++;
    _staleTimer?.cancel();
    _loadedAt = null;
    _inFlightQuery = null;
    if (!isClosed) {
      emit(
        RequestMatchingState(
          query: MatchingQuery(requestId: requestId),
          revoked: true,
          errorMessage: 'matching.errors.access',
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    _readVersion++;
    _staleTimer?.cancel();
    await _session.close();
    return super.close();
  }
}
