import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/marketplace.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../auth/bloc/session_bloc.dart';
import 'marketplace_session.dart';

class ProviderBrowseState extends Equatable {
  const ProviderBrowseState({
    this.items = const [],
    this.loaded = false,
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = false,
    this.eligible = true,
    this.errorMessage,
    this.revoked = false,
  });

  final List<QuoteOpportunity> items;
  final bool loaded;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final bool eligible;
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
    eligible,
    errorMessage,
    revoked,
  ];
}

class ProviderBrowseCubit extends Cubit<ProviderBrowseState> {
  ProviderBrowseCubit({
    required this.userId,
    required this.myQuotes,
    required this._repository,
    required SessionBloc session,
  }) : super(const ProviderBrowseState()) {
    _session = MarketplaceSession(
      session: session,
      userId: userId,
      role: UserRole.provider,
      onRevoked: _clear,
    );
  }

  final String userId;
  final bool myQuotes;
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
    final before = !more
        ? null
        : myQuotes
        ? previous.items.last.quote?.cursor
        : previous.items.last.listing.cursor;
    emit(
      ProviderBrowseState(
        items: previous.items,
        loaded: previous.loaded,
        loading: !more,
        loadingMore: more,
        hasMore: previous.hasMore,
        eligible: previous.eligible,
      ),
    );
    final result = myQuotes
        ? await _repository.loadMyQuotes(userId: userId, before: before)
        : (await _repository.loadFeed(userId: userId, before: before)).map(
            (page) => MarketplacePage<QuoteOpportunity>(
              items: [
                for (final listing in page.items)
                  QuoteOpportunity(listing: listing, canQuote: page.eligible),
              ],
              hasMore: page.hasMore,
              eligible: page.eligible,
            ),
          );
    if (isClosed || !_session.active) return;
    result.fold(
      (failure) {
        if (marketplaceAccessError(failure.message)) return _session.revoke();
        emit(
          ProviderBrowseState(
            items: previous.items,
            loaded: previous.loaded,
            hasMore: previous.hasMore,
            eligible: previous.eligible,
            errorMessage: failure.message,
          ),
        );
      },
      (page) {
        final records = {
          if (more)
            for (final item in previous.items) item.listing.requestId: item,
          for (final item in page.items) item.listing.requestId: item,
        };
        emit(
          ProviderBrowseState(
            items: List.unmodifiable(records.values),
            loaded: true,
            hasMore: page.hasMore && page.items.isNotEmpty,
            eligible: page.eligible,
          ),
        );
      },
    );
  }

  void _clear() {
    if (!isClosed) {
      emit(
        const ProviderBrowseState(
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
