import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/marketplace.dart';
import '../../data/models/service_request.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../../utils/failure.dart';
import '../auth/bloc/session_bloc.dart';
import 'marketplace_session.dart';

enum CustomerQuotesOperation {
  idle,
  loading,
  loadingMore,
  publishing,
  accepting,
}

class CustomerQuotesState extends Equatable {
  const CustomerQuotesState({
    this.book,
    this.summary = '',
    this.city = '',
    this.consent = false,
    this.operation = CustomerQuotesOperation.idle,
    this.uncertain = false,
    this.errorMessage,
    this.notice,
    this.revoked = false,
  });
  final CustomerQuoteBook? book;
  final String summary;
  final String city;
  final bool consent;
  final CustomerQuotesOperation operation;
  final bool uncertain;
  final String? errorMessage;
  final String? notice;
  final bool revoked;

  bool get busy => operation != CustomerQuotesOperation.idle;
  bool get hasUnsavedChanges =>
      summary.isNotEmpty || city.isNotEmpty || consent;
  bool get canPublish =>
      !busy &&
      !uncertain &&
      !revoked &&
      book?.requestStatus == ServiceRequestStatus.open &&
      book?.listing == null;
  bool get canAccept =>
      !busy &&
      !uncertain &&
      !revoked &&
      book?.requestStatus == ServiceRequestStatus.open &&
      book?.listing != null &&
      book?.job == null;

  CustomerQuotesState copyWith({
    CustomerQuoteBook? book,
    String? summary,
    String? city,
    bool? consent,
    CustomerQuotesOperation? operation,
    bool? uncertain,
    String? errorMessage,
    String? notice,
  }) => CustomerQuotesState(
    book: book ?? this.book,
    summary: summary ?? this.summary,
    city: city ?? this.city,
    consent: consent ?? this.consent,
    operation: operation ?? this.operation,
    uncertain: uncertain ?? this.uncertain,
    errorMessage: errorMessage,
    notice: notice,
    revoked: revoked,
  );

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    book,
    summary,
    city,
    consent,
    operation,
    uncertain,
    errorMessage,
    notice,
    revoked,
  ];
}

class CustomerQuotesCubit extends Cubit<CustomerQuotesState> {
  CustomerQuotesCubit({
    required this.userId,
    required this.requestId,
    required this._repository,
    required SessionBloc session,
  }) : super(const CustomerQuotesState()) {
    _session = MarketplaceSession(
      session: session,
      userId: userId,
      role: UserRole.customer,
      onRevoked: _clear,
    );
  }
  final String userId;
  final String requestId;
  final MarketplaceRepository _repository;
  late final MarketplaceSession _session;
  ({String summary, String city, bool consent})? _pendingPublication;
  ProviderQuote? _pendingAcceptance;
  bool _acceptConsent = false;

  Future<void> refresh() => _load(more: false);
  Future<void> loadMore() => _load(more: true);

  Future<void> _load({required bool more}) async {
    if (isClosed ||
        !_session.active ||
        state.busy ||
        state.uncertain ||
        (more && (state.book?.hasMore != true || state.book!.quotes.isEmpty))) {
      return;
    }
    final previous = state.book;
    emit(
      state.copyWith(
        operation: more
            ? CustomerQuotesOperation.loadingMore
            : CustomerQuotesOperation.loading,
        uncertain: _repository.hasPendingOperation(requestId, userId: userId),
      ),
    );
    final result = await _repository.loadCustomerQuotes(
      requestId,
      userId: userId,
      before: more ? previous!.quotes.last.cursor : null,
    );
    if (isClosed || !_session.active) return;
    result.fold(_failRead, (book) {
      if (book.customerId != userId || book.requestId != requestId) {
        return _session.revoke();
      }
      final quotes = {
        if (more)
          for (final quote in previous!.quotes) quote.id: quote,
        for (final quote in book.quotes) quote.id: quote,
      };
      emit(
        state.copyWith(
          book: CustomerQuoteBook(
            requestId: book.requestId,
            customerId: book.customerId,
            requestStatus: book.requestStatus,
            listing: book.listing,
            quotes: List.unmodifiable(quotes.values),
            hasMore: book.hasMore && book.quotes.isNotEmpty,
            job: book.job,
          ),
          operation: CustomerQuotesOperation.idle,
          summary: book.listing == null ? state.summary : '',
          city: book.listing == null ? state.city : '',
          consent: book.listing == null && state.consent,
        ),
      );
    });
  }

  void updateSummary(String value) {
    if (!isClosed && _session.active && state.canPublish) {
      emit(state.copyWith(summary: value, consent: false));
    }
  }

  void updateCity(String value) {
    if (!isClosed && _session.active && state.canPublish) {
      emit(state.copyWith(city: value, consent: false));
    }
  }

  void setConsent(bool value) {
    if (!isClosed && _session.active && state.canPublish) {
      emit(state.copyWith(consent: value));
    }
  }

  Future<void> publish() async {
    if (isClosed || !_session.active || !state.canPublish) return;
    final summary = state.summary.trim();
    final city = state.city.trim();
    final error = summary.runes.length < 10 || summary.runes.length > 1000
        ? 'marketplace.errors.summary'
        : city.runes.length < 2 || city.runes.length > 100
        ? 'marketplace.errors.city'
        : !state.consent
        ? 'marketplace.errors.consent'
        : null;
    if (error != null) {
      emit(state.copyWith(errorMessage: error));
      return;
    }
    _pendingPublication = (
      summary: summary,
      city: city,
      consent: state.consent,
    );
    _pendingAcceptance = null;
    await _publishPending();
  }

  Future<void> accept(ProviderQuote quote, {required bool consent}) async {
    if (isClosed || !_session.active || !state.canAccept) return;
    if (!consent) {
      emit(state.copyWith(errorMessage: 'marketplace.errors.consent'));
      return;
    }
    if (quote.status != QuoteStatus.pending ||
        !state.book!.quotes.contains(quote)) {
      emit(state.copyWith(errorMessage: 'marketplace.errors.conflict'));
      return;
    }
    _pendingAcceptance = quote;
    _acceptConsent = consent;
    _pendingPublication = null;
    await _acceptPending();
  }

  Future<void> retryPending() async {
    if (isClosed || !_session.active || state.busy || !state.uncertain) return;
    if (_pendingPublication != null) {
      await _publishPending();
    } else if (_pendingAcceptance != null) {
      await _acceptPending();
    } else {
      emit(state.copyWith(operation: CustomerQuotesOperation.accepting));
      final result = await _repository.retryPending(requestId, userId: userId);
      if (isClosed || !_session.active) return;
      String? error;
      result.fold(
        (failure) {
          error = failure.message;
          _failMutation(failure);
        },
        (_) => emit(
          state.copyWith(
            operation: CustomerQuotesOperation.idle,
            uncertain: false,
          ),
        ),
      );
      if (_session.active && !state.uncertain) {
        await refresh();
        if (!isClosed && _session.active && error != null) {
          emit(state.copyWith(errorMessage: error));
        }
      }
    }
  }

  Future<void> _publishPending() async {
    final draft = _pendingPublication!;
    emit(state.copyWith(operation: CustomerQuotesOperation.publishing));
    final result = await _repository.publishListing(
      requestId,
      userId: userId,
      summary: draft.summary,
      city: draft.city,
      consent: draft.consent,
    );
    if (isClosed || !_session.active) return;
    result.fold(_failMutation, (listing) {
      if (listing.requestId != requestId) return _session.revoke();
      _pendingPublication = null;
      emit(
        state.copyWith(
          book: CustomerQuoteBook(
            requestId: requestId,
            customerId: userId,
            requestStatus: listing.requestStatus,
            listing: listing,
            quotes: state.book!.quotes,
            hasMore: state.book!.hasMore,
            job: state.book!.job,
          ),
          summary: '',
          city: '',
          consent: false,
          operation: CustomerQuotesOperation.idle,
          uncertain: false,
          notice: 'marketplace.published_notice',
        ),
      );
    });
  }

  Future<void> _acceptPending() async {
    final quote = _pendingAcceptance!;
    emit(state.copyWith(operation: CustomerQuotesOperation.accepting));
    final result = await _repository.acceptQuote(
      quote,
      userId: userId,
      consent: _acceptConsent,
    );
    if (isClosed || !_session.active) return;
    result.fold(_failMutation, (job) {
      if (job.customerId != userId || job.requestId != requestId) {
        return _session.revoke();
      }
      _pendingAcceptance = null;
      _acceptConsent = false;
      emit(
        state.copyWith(
          book: CustomerQuoteBook(
            requestId: requestId,
            customerId: userId,
            requestStatus: ServiceRequestStatus.assigned,
            listing: state.book!.listing?.withStatus(
              ServiceRequestStatus.assigned,
            ),
            quotes: const [],
            hasMore: false,
            job: job,
          ),
          operation: CustomerQuotesOperation.idle,
          uncertain: false,
          notice: 'marketplace.accepted_notice',
        ),
      );
    });
  }

  void _failRead(Failure failure) {
    if (marketplaceAccessError(failure.message)) return _session.revoke();
    emit(
      state.copyWith(
        operation: CustomerQuotesOperation.idle,
        errorMessage: failure.message,
      ),
    );
  }

  void _failMutation(Failure failure) {
    if (marketplaceAccessError(failure.message)) return _session.revoke();
    final uncertain = marketplaceStillUncertain(
      state.uncertain,
      failure.message,
    );
    if (!uncertain) {
      _pendingPublication = null;
      _pendingAcceptance = null;
      _acceptConsent = false;
    }
    emit(
      state.copyWith(
        operation: CustomerQuotesOperation.idle,
        uncertain: uncertain,
        errorMessage: failure.message,
      ),
    );
  }

  void _clear() {
    _pendingPublication = null;
    _pendingAcceptance = null;
    _acceptConsent = false;
    if (!isClosed) {
      emit(
        const CustomerQuotesState(
          revoked: true,
          errorMessage: 'marketplace.errors.access',
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    await _session.close();
    _pendingPublication = null;
    _pendingAcceptance = null;
    return super.close();
  }
}
