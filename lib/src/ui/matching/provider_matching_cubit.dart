import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/matching.dart';
import '../../data/models/service_category.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/matching_repository.dart';
import '../../utils/failure.dart';
import '../auth/bloc/session_bloc.dart';
import '../marketplace/marketplace_session.dart';

enum ProviderMatchingOperation { idle, loading, saving }

class ProviderMatchingState extends Equatable {
  const ProviderMatchingState({
    required this.draft,
    this.profile,
    this.metadata,
    this.categories = const [],
    this.catalogLoaded = false,
    this.metadataLoading = false,
    this.metadataError,
    this.catalogError,
    this.operation = ProviderMatchingOperation.idle,
    this.uncertain = false,
    this.reloadRequired = false,
    this.formVersion = 0,
    this.errorMessage,
    this.notice,
    this.revoked = false,
  });

  final ProviderMatchingDraft draft;
  final ProviderMatchingProfile? profile;
  final MatchingEligibility? metadata;
  final List<ServiceCategory> categories;
  final bool catalogLoaded;
  final bool metadataLoading;
  final String? metadataError;
  final String? catalogError;
  final ProviderMatchingOperation operation;
  final bool uncertain;
  final bool reloadRequired;
  final int formVersion;
  final String? errorMessage;
  final String? notice;
  final bool revoked;

  bool get busy => operation != ProviderMatchingOperation.idle;
  bool get canEdit => !busy && !uncertain && !revoked && profile != null;
  List<ServiceCategory> get currentCategories =>
      metadataError != null || catalogError != null || !catalogLoaded
      ? const []
      : categories
            .where(
              (category) =>
                  category.isActive &&
                  metadata?.skillIds.contains(category.id) == true,
            )
            .toList(growable: false);
  List<String> get oldExperienceIds {
    final current = currentCategories.map((category) => category.id).toSet();
    return draft.experienceYears.keys
        .where((id) => !current.contains(id))
        .toList();
  }

  bool get canEnableDiscovery =>
      !metadataLoading &&
      metadataError == null &&
      catalogError == null &&
      catalogLoaded &&
      metadata?.eligible == true &&
      currentCategories.isNotEmpty;
  bool get canSave =>
      canEdit && !reloadRequired && (!draft.discoverable || canEnableDiscovery);
  bool get hasUnsavedChanges {
    final saved = profile;
    if (saved == null || draft == ProviderMatchingDraft.fromProfile(saved)) {
      return false;
    }
    // matches parses years; invalid in-progress input must remain a draft, not throw.
    return draft.copyWith(consent: true).validate() != null ||
        !draft.matches(saved) ||
        draft.consent;
  }

  static const _unchanged = Object();

  ProviderMatchingState copyWith({
    ProviderMatchingDraft? draft,
    ProviderMatchingProfile? profile,
    MatchingEligibility? metadata,
    List<ServiceCategory>? categories,
    bool? catalogLoaded,
    bool? metadataLoading,
    Object? metadataError = _unchanged,
    Object? catalogError = _unchanged,
    ProviderMatchingOperation? operation,
    bool? uncertain,
    bool? reloadRequired,
    int? formVersion,
    Object? errorMessage = _unchanged,
    String? notice,
  }) => ProviderMatchingState(
    draft: draft ?? this.draft,
    profile: profile ?? this.profile,
    metadata: metadata ?? this.metadata,
    categories: categories ?? this.categories,
    catalogLoaded: catalogLoaded ?? this.catalogLoaded,
    metadataLoading: metadataLoading ?? this.metadataLoading,
    metadataError: identical(metadataError, _unchanged)
        ? this.metadataError
        : metadataError as String?,
    catalogError: identical(catalogError, _unchanged)
        ? this.catalogError
        : catalogError as String?,
    operation: operation ?? this.operation,
    uncertain: uncertain ?? this.uncertain,
    reloadRequired: reloadRequired ?? this.reloadRequired,
    formVersion: formVersion ?? this.formVersion,
    errorMessage: identical(errorMessage, _unchanged)
        ? this.errorMessage
        : errorMessage as String?,
    notice: notice,
    revoked: revoked,
  );

  @override
  bool get stringify => false;

  @override
  List<Object?> get props => [
    draft,
    profile,
    metadata,
    categories,
    catalogLoaded,
    metadataLoading,
    metadataError,
    catalogError,
    operation,
    uncertain,
    reloadRequired,
    formVersion,
    errorMessage,
    notice,
    revoked,
  ];
}

class ProviderMatchingCubit extends Cubit<ProviderMatchingState> {
  ProviderMatchingCubit({
    required this.userId,
    required this._repository,
    required this._catalogRepository,
    required SessionBloc session,
  }) : super(
         ProviderMatchingState(
           draft: ProviderMatchingDraft(providerId: userId),
         ),
       ) {
    _session = MarketplaceSession(
      session: session,
      userId: userId,
      role: UserRole.provider,
      onRevoked: _clear,
    );
    if (!_session.active) _clear();
  }

  final String userId;
  final MatchingRepository _repository;
  final CatalogRepository _catalogRepository;
  late final MarketplaceSession _session;
  bool _catalogAttempted = false;
  bool get active => !isClosed && _session.active;

  Future<void> load({bool discardEdits = false}) async {
    if (!active || state.busy || state.uncertain) return;
    emit(
      state.copyWith(
        operation: ProviderMatchingOperation.loading,
        uncertain: _repository.hasPendingSave(userId: userId),
        errorMessage: null,
      ),
    );
    final metadata = _loadMetadata();
    final result = await _repository.loadProfile(userId: userId);
    if (!active) return;
    result.fold(_failRead, (profile) {
      if (profile.providerId != userId) return _session.revoke();
      final replace = discardEdits || !state.hasUnsavedChanges;
      emit(
        state.copyWith(
          profile: profile,
          draft: replace
              ? ProviderMatchingDraft.fromProfile(profile)
              : state.draft,
          operation: ProviderMatchingOperation.idle,
          formVersion: state.formVersion + (replace ? 1 : 0),
          reloadRequired:
              !replace && state.draft.expectedRevision != profile.revision,
        ),
      );
    });
    if (active) await metadata;
  }

  Future<void> _loadMetadata({bool retryCatalog = false}) async {
    if (!active || state.metadataLoading) return;
    final loadCatalog = !_catalogAttempted || retryCatalog;
    _catalogAttempted = true;
    emit(state.copyWith(metadataLoading: true));
    final provider = _repository.loadEligibility(userId: userId);
    final catalog = loadCatalog ? _catalogRepository.loadCategories() : null;
    final providerResult = await provider;
    if (!active) return;
    providerResult.fold(
      (failure) {
        if (failure.message == 'provider.errors.access' ||
            _accessError(failure.message)) {
          return _session.revoke();
        }
        emit(state.copyWith(metadataError: failure.message));
      },
      (eligibility) =>
          emit(state.copyWith(metadata: eligibility, metadataError: null)),
    );
    if (catalog != null) {
      final categories = await catalog;
      if (!active) return;
      categories.fold(
        (failure) => emit(state.copyWith(catalogError: failure.message)),
        (items) => emit(
          state.copyWith(
            categories: List.unmodifiable(items),
            catalogLoaded: true,
            catalogError: null,
          ),
        ),
      );
    }
    if (active) emit(state.copyWith(metadataLoading: false));
  }

  Future<void> retryMetadata() =>
      _loadMetadata(retryCatalog: state.catalogError != null);

  void setDiscoverable(bool value) {
    if (!active || !state.canEdit) return;
    if (value && !state.canEnableDiscovery) {
      emit(state.copyWith(errorMessage: 'matching.errors.ineligible'));
      return;
    }
    _edit(state.draft.copyWith(discoverable: value, consent: false));
  }

  void updateLatitude(String value) =>
      _edit(state.draft.copyWith(latitude: value, consent: false));
  void updateLongitude(String value) =>
      _edit(state.draft.copyWith(longitude: value, consent: false));
  void setConsent(bool value) => _edit(state.draft.copyWith(consent: value));

  void updateExperience(String categoryId, String value) {
    if (state.metadataLoading ||
        !state.currentCategories.any((category) => category.id == categoryId)) {
      return;
    }
    _edit(
      state.draft.copyWith(
        experienceYears: {...state.draft.experienceYears, categoryId: value},
        consent: false,
      ),
    );
  }

  void removeExperience(String categoryId) {
    final years = {...state.draft.experienceYears}..remove(categoryId);
    _edit(state.draft.copyWith(experienceYears: years, consent: false));
  }

  void _edit(ProviderMatchingDraft draft) {
    if (active && state.canEdit) {
      emit(state.copyWith(draft: draft, errorMessage: null));
    }
  }

  Future<void> save() async {
    if (!active || !state.canSave) return;
    final error = state.draft.validate();
    if (error != null) {
      emit(state.copyWith(errorMessage: error));
      return;
    }
    final original = state.draft;
    emit(
      state.copyWith(
        operation: ProviderMatchingOperation.saving,
        errorMessage: null,
      ),
    );
    final result = await _repository.saveProfile(original, userId: userId);
    if (!active) return;
    result.fold(_failMutation, _saved);
  }

  Future<void> retryPending() async {
    if (!active || state.busy || !state.uncertain) return;
    emit(
      state.copyWith(
        operation: ProviderMatchingOperation.saving,
        errorMessage: null,
      ),
    );
    final result = await _repository.retryPendingSave(userId: userId);
    if (!active) return;
    result.fold(_failMutation, _saved);
  }

  void _saved(ProviderMatchingProfile profile) {
    if (profile.providerId != userId) return _session.revoke();
    emit(
      state.copyWith(
        profile: profile,
        draft: ProviderMatchingDraft.fromProfile(profile),
        operation: ProviderMatchingOperation.idle,
        uncertain: false,
        reloadRequired: false,
        formVersion: state.formVersion + 1,
        errorMessage: null,
        notice: profile.discoverable
            ? 'matching.settings_saved_discoverable'
            : 'matching.settings_saved_private',
      ),
    );
  }

  void _failRead(Failure failure) {
    if (_accessError(failure.message)) return _session.revoke();
    emit(
      state.copyWith(
        operation: ProviderMatchingOperation.idle,
        errorMessage: failure.message,
      ),
    );
  }

  void _failMutation(Failure failure) {
    if (_accessError(failure.message)) return _session.revoke();
    final uncertain =
        _repository.hasPendingSave(userId: userId) ||
        failure.message == 'matching.errors.uncertain' ||
        (state.uncertain &&
            !const {
              'matching.errors.conflict',
              'matching.errors.ineligible',
              'matching.errors.invalid',
              'matching.errors.consent',
              'matching.errors.location',
              'matching.errors.experience',
            }.contains(failure.message));
    emit(
      state.copyWith(
        operation: ProviderMatchingOperation.idle,
        uncertain: uncertain,
        reloadRequired:
            !uncertain && failure.message == 'matching.errors.conflict',
        errorMessage: failure.message,
      ),
    );
  }

  bool _accessError(String message) =>
      marketplaceAccessError(message) ||
      const {
        'matching.errors.access',
        'matching.errors.not_found',
      }.contains(message);

  void _clear() {
    if (!isClosed) {
      emit(
        ProviderMatchingState(
          draft: ProviderMatchingDraft(providerId: userId),
          revoked: true,
          errorMessage: 'matching.errors.access',
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
