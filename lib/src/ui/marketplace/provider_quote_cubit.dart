import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/marketplace.dart';
import '../../data/models/service_request.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../../utils/failure.dart';
import '../auth/bloc/session_bloc.dart';
import 'marketplace_session.dart';

enum ProviderQuoteOperation { idle, loading, saving, withdrawing }

class ProviderQuoteState extends Equatable {
  const ProviderQuoteState({
    required this.draft,
    this.opportunity,
    this.operation = ProviderQuoteOperation.idle,
    this.uncertain = false,
    this.formVersion = 0,
    this.errorMessage,
    this.notice,
    this.revoked = false,
  });
  final QuoteDraft draft;
  final QuoteOpportunity? opportunity;
  final ProviderQuoteOperation operation;
  final bool uncertain;
  final int formVersion;
  final String? errorMessage;
  final String? notice;
  final bool revoked;

  bool get busy => operation != ProviderQuoteOperation.idle;
  bool get mutableTerms =>
      opportunity?.quote == null ||
      opportunity?.quote?.status == QuoteStatus.pending ||
      opportunity?.quote?.status == QuoteStatus.withdrawn;
  bool get canEdit =>
      !busy &&
      !uncertain &&
      !revoked &&
      opportunity?.canQuote == true &&
      mutableTerms;
  bool get canWithdraw =>
      !busy &&
      !uncertain &&
      !revoked &&
      opportunity?.listing.requestStatus == ServiceRequestStatus.open &&
      opportunity?.quote?.status == QuoteStatus.pending;
  bool get hasUnsavedChanges {
    final quote = opportunity?.quote;
    return quote == null
        ? [draft.amount, draft.duration, draft.notes].any((v) => v.isNotEmpty)
        : !draft.matches(quote);
  }

  ProviderQuoteState copyWith({
    QuoteDraft? draft,
    QuoteOpportunity? opportunity,
    ProviderQuoteOperation? operation,
    bool? uncertain,
    int? formVersion,
    String? errorMessage,
    String? notice,
  }) => ProviderQuoteState(
    draft: draft ?? this.draft,
    opportunity: opportunity ?? this.opportunity,
    operation: operation ?? this.operation,
    uncertain: uncertain ?? this.uncertain,
    formVersion: formVersion ?? this.formVersion,
    errorMessage: errorMessage,
    notice: notice,
    revoked: revoked,
  );

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    draft,
    opportunity,
    operation,
    uncertain,
    formVersion,
    errorMessage,
    notice,
    revoked,
  ];
}

class ProviderQuoteCubit extends Cubit<ProviderQuoteState> {
  ProviderQuoteCubit({
    required this.userId,
    required this.requestId,
    required this._repository,
    required SessionBloc session,
  }) : super(ProviderQuoteState(draft: QuoteDraft(requestId: requestId))) {
    _session = MarketplaceSession(
      session: session,
      userId: userId,
      role: UserRole.provider,
      onRevoked: _clear,
    );
  }
  final String userId;
  final String requestId;
  final MarketplaceRepository _repository;
  late final MarketplaceSession _session;
  QuoteDraft? _pendingDraft;
  ProviderQuote? _pendingWithdrawal;

  Future<void> load({bool discardEdits = false}) async {
    if (isClosed || !_session.active || state.busy || state.uncertain) return;
    emit(
      state.copyWith(
        operation: ProviderQuoteOperation.loading,
        uncertain: _repository.hasPendingOperation(requestId, userId: userId),
      ),
    );
    final result = await _repository.loadProviderRequest(
      requestId,
      userId: userId,
    );
    if (isClosed || !_session.active) return;
    result.fold(_failRead, (opportunity) {
      if (opportunity.listing.requestId != requestId ||
          (opportunity.quote != null &&
              opportunity.quote!.providerId != userId)) {
        return _session.revoke();
      }
      final replace = discardEdits || !state.hasUnsavedChanges;
      emit(
        state.copyWith(
          opportunity: opportunity,
          operation: ProviderQuoteOperation.idle,
          draft: replace
              ? opportunity.quote == null
                    ? QuoteDraft(requestId: requestId)
                    : QuoteDraft.fromQuote(opportunity.quote!)
              : state.draft,
          formVersion: state.formVersion + (replace ? 1 : 0),
        ),
      );
    });
  }

  void updateAmount(String value) => _edit(state.draft.copyWith(amount: value));
  void updateDuration(String value) =>
      _edit(state.draft.copyWith(duration: value));
  void updateNotes(String value) => _edit(state.draft.copyWith(notes: value));

  void _edit(QuoteDraft draft) {
    if (!isClosed && _session.active && state.canEdit) {
      emit(state.copyWith(draft: draft));
    }
  }

  Future<void> save() async {
    if (isClosed || !_session.active || !state.canEdit) return;
    final error = state.draft.validate();
    if (error != null) {
      emit(state.copyWith(errorMessage: error));
      return;
    }
    _pendingDraft = state.draft;
    _pendingWithdrawal = null;
    await _runPending();
  }

  Future<void> withdraw() async {
    if (isClosed || !_session.active || !state.canWithdraw) return;
    _pendingWithdrawal = state.opportunity!.quote;
    _pendingDraft = null;
    await _runPending();
  }

  Future<void> retryPending() async {
    if (isClosed || !_session.active || state.busy || !state.uncertain) return;
    if (_pendingDraft == null && _pendingWithdrawal == null) {
      emit(state.copyWith(operation: ProviderQuoteOperation.saving));
      final result = await _repository.retryPending(requestId, userId: userId);
      if (isClosed || !_session.active) return;
      String? error;
      result.fold(
        (failure) {
          error = failure.message;
          if (marketplaceAccessError(failure.message)) return _session.revoke();
          emit(
            state.copyWith(
              operation: ProviderQuoteOperation.idle,
              uncertain: marketplaceStillUncertain(true, failure.message),
              errorMessage: failure.message,
            ),
          );
        },
        (_) => emit(
          state.copyWith(
            operation: ProviderQuoteOperation.idle,
            uncertain: false,
          ),
        ),
      );
      if (_session.active && !state.uncertain) {
        await load(discardEdits: true);
        if (!isClosed && _session.active && error != null) {
          emit(state.copyWith(errorMessage: error));
        }
      }
      return;
    }
    await _runPending();
  }

  Future<void> _runPending() async {
    final draft = _pendingDraft;
    final withdrawn = _pendingWithdrawal;
    if (draft == null && withdrawn == null) return;
    emit(
      state.copyWith(
        operation: draft != null
            ? ProviderQuoteOperation.saving
            : ProviderQuoteOperation.withdrawing,
      ),
    );
    final result = draft != null
        ? await _repository.saveQuote(draft, userId: userId)
        : await _repository.withdrawQuote(withdrawn!, userId: userId);
    if (isClosed || !_session.active) return;
    result.fold(
      (failure) {
        if (marketplaceAccessError(failure.message)) return _session.revoke();
        // A later transport error cannot turn an ambiguous commit into a rejection.
        final uncertain = marketplaceStillUncertain(
          state.uncertain,
          failure.message,
        );
        if (!uncertain) {
          _pendingDraft = null;
          _pendingWithdrawal = null;
        }
        emit(
          state.copyWith(
            operation: ProviderQuoteOperation.idle,
            uncertain: uncertain,
            errorMessage: failure.message,
          ),
        );
      },
      (quote) {
        if (quote.providerId != userId || quote.requestId != requestId) {
          return _session.revoke();
        }
        _pendingDraft = null;
        _pendingWithdrawal = null;
        emit(
          state.copyWith(
            opportunity: QuoteOpportunity(
              listing: state.opportunity!.listing,
              quote: quote,
              canQuote: state.opportunity!.canQuote,
            ),
            draft: QuoteDraft.fromQuote(quote),
            operation: ProviderQuoteOperation.idle,
            uncertain: false,
            formVersion: state.formVersion + 1,
            notice: draft != null
                ? 'marketplace.quote_saved'
                : 'marketplace.quote_withdrawn',
          ),
        );
      },
    );
  }

  void _failRead(Failure failure) {
    if (marketplaceAccessError(failure.message)) return _session.revoke();
    emit(
      state.copyWith(
        operation: ProviderQuoteOperation.idle,
        errorMessage: failure.message,
      ),
    );
  }

  void _clear() {
    _pendingDraft = null;
    _pendingWithdrawal = null;
    if (!isClosed) {
      emit(
        ProviderQuoteState(
          draft: QuoteDraft(requestId: requestId),
          revoked: true,
          errorMessage: 'marketplace.errors.access',
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    await _session.close();
    _pendingDraft = null;
    _pendingWithdrawal = null;
    return super.close();
  }
}
