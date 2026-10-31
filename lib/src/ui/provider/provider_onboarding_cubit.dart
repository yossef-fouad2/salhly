import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/provider_profile.dart';
import '../../data/models/service_category.dart';
import '../../data/models/verification_document.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/provider_repository.dart';
import '../../services/verification_document_picker.dart';

enum ProviderOperation { idle, loading, saving, picking, submitting, reading }

class ProviderOnboardingState extends Equatable {
  const ProviderOnboardingState({
    this.profile,
    this.categories = const [],
    this.step = 0,
    this.operation = ProviderOperation.idle,
    this.isDirty = false,
    this.document,
    this.consent = false,
    this.errorMessage,
    this.notice,
  });

  final ProviderProfile? profile;
  final List<ServiceCategory> categories;
  final int step;
  final ProviderOperation operation;
  final bool isDirty;
  final VerificationDocument? document;
  final bool consent;
  final String? errorMessage;
  final String? notice;

  bool get isBusy => operation != ProviderOperation.idle;
  bool get canEdit => !isBusy && (profile?.canEdit ?? false);
  bool get hasUnsavedChanges => isDirty || document != null;
  bool get isWriting =>
      operation == ProviderOperation.saving ||
      operation == ProviderOperation.submitting;

  ProviderOnboardingState copyWith({
    ProviderProfile? profile,
    List<ServiceCategory>? categories,
    int? step,
    ProviderOperation? operation,
    bool? isDirty,
    VerificationDocument? document,
    bool clearDocument = false,
    bool? consent,
    String? errorMessage,
    String? notice,
  }) => ProviderOnboardingState(
    profile: profile ?? this.profile,
    categories: categories ?? this.categories,
    step: step ?? this.step,
    operation: operation ?? this.operation,
    isDirty: isDirty ?? this.isDirty,
    document: clearDocument ? null : document ?? this.document,
    consent: consent ?? this.consent,
    errorMessage: errorMessage,
    notice: notice,
  );

  @override
  List<Object?> get props => [
    profile,
    categories,
    step,
    operation,
    isDirty,
    document,
    consent,
    errorMessage,
    notice,
  ];
}

/// One page-scoped draft. Typing is local; only explicit actions do I/O.
class ProviderOnboardingCubit extends Cubit<ProviderOnboardingState> {
  ProviderOnboardingCubit({
    required this._userId,
    required this._repository,
    required this._catalog,
    required this._documentPicker,
  }) : super(const ProviderOnboardingState());

  final String _userId;
  final ProviderRepository _repository;
  final CatalogRepository _catalog;
  final VerificationDocumentPicker _documentPicker;

  Future<void> load() async {
    if (state.isBusy) return;
    emit(state.copyWith(operation: ProviderOperation.loading));
    final (profileResult, catalogResult) = await (
      _repository.loadProfile(_userId),
      _catalog.loadCategories(),
    ).wait;
    if (isClosed) return;
    profileResult.fold((failure) => _fail(failure.message), (profile) {
      String? catalogError;
      final categories = catalogResult.fold((failure) {
        catalogError = failure.message;
        return state.categories;
      }, (categories) => categories);
      // Reconcile review status even if the separate catalog request failed.
      // An unsaved local draft must not be overwritten by a status check.
      final draft = state.isDirty
          ? state.profile!.copyWith(verification: profile.verification)
          : profile;
      emit(
        state.copyWith(
          profile: draft,
          categories: categories,
          step: state.profile == null && profile.verification != null
              ? 2
              : state.step,
          operation: ProviderOperation.idle,
          clearDocument: !profile.canSubmit,
          consent: profile.canSubmit ? state.consent : false,
          errorMessage: catalogError,
        ),
      );
    });
  }

  void setStep(int step) {
    if (state.isBusy || step < 0 || step > 2) return;
    emit(state.copyWith(step: step));
  }

  void updateBio(String value) {
    if (!state.canEdit) return;
    _edit(state.profile!.copyWith(bio: value));
  }

  void toggleSkill(String id) {
    if (!state.canEdit) return;
    final skills = [...state.profile!.skillIds];
    if (!skills.remove(id)) {
      if (!state.categories.any((item) => item.id == id)) return;
      if (skills.length >= 20) {
        _fail('provider.errors.skills');
        return;
      }
      skills.add(id);
    }
    _edit(state.profile!.copyWith(skillIds: skills));
  }

  void updateAreas(String value) {
    if (!state.canEdit) return;
    _edit(
      state.profile!.copyWith(
        serviceAreas: value
            .split('\n')
            .map((area) => area.trim())
            .where((area) => area.isNotEmpty)
            .toList(),
      ),
    );
  }

  void updateAvailability(int weekday, ProviderAvailability? hours) {
    if (!state.canEdit) return;
    final availability = [
      for (final item in state.profile!.availability)
        if (item.weekday != weekday) item,
      ?hours,
    ]..sort((a, b) => a.weekday.compareTo(b.weekday));
    _edit(state.profile!.copyWith(availability: availability));
  }

  void _edit(ProviderProfile profile) {
    emit(state.copyWith(profile: profile, isDirty: true));
  }

  Future<void> save() async {
    final profile = state.profile;
    if (!state.canEdit || profile == null) return;
    final error = profile.validate();
    if (error != null) return _fail(error);
    emit(state.copyWith(operation: ProviderOperation.saving));
    final result = await _repository.saveProfile(profile);
    if (isClosed) return;
    result.fold(
      (failure) => _fail(failure.message),
      (saved) => emit(
        state.copyWith(
          profile: saved,
          isDirty: false,
          operation: ProviderOperation.idle,
          notice: 'provider.saved',
        ),
      ),
    );
  }

  Future<void> pickDocument() async {
    if (state.isBusy || !(state.profile?.canSubmit ?? false)) return;
    emit(state.copyWith(operation: ProviderOperation.picking));
    final result = await _documentPicker.pick();
    if (isClosed) return;
    result.fold(
      (failure) => _fail(failure.message),
      (document) => emit(
        state.copyWith(
          operation: ProviderOperation.idle,
          document: document,
          consent: document == null ? state.consent : false,
        ),
      ),
    );
  }

  void removeDocument() {
    if (state.isBusy) return;
    emit(state.copyWith(clearDocument: true, consent: false));
  }

  void setConsent(bool value) {
    if (state.isBusy || !(state.profile?.canSubmit ?? false)) return;
    emit(state.copyWith(consent: value));
  }

  Future<void> submit() async {
    final profile = state.profile;
    if (state.isBusy || profile == null || !profile.canSubmit) return;
    final error = profile.validate(forSubmission: true);
    if (error != null) {
      _fail(
        error,
        step: switch (error) {
          'provider.errors.bio' || 'provider.errors.skills' => 0,
          'provider.errors.areas' || 'provider.errors.availability' => 1,
          _ => null,
        },
      );
      return;
    }
    final document = state.document;
    if (document == null) return _fail('provider.errors.document_required');
    if (!state.consent) return _fail('provider.errors.consent');

    emit(state.copyWith(operation: ProviderOperation.submitting));
    final saveResult = await _repository.saveProfile(profile);
    if (isClosed) return;
    final saved = saveResult.fold((failure) {
      _fail(failure.message);
      return null;
    }, (value) => value);
    if (saved == null) return;
    emit(state.copyWith(profile: saved, isDirty: false));
    final result = await _repository.submitVerification(
      userId: _userId,
      document: document,
      consent: state.consent,
    );
    if (isClosed) return;
    result.fold(
      (failure) => _fail(failure.message),
      (submitted) => emit(
        state.copyWith(
          profile: submitted,
          operation: ProviderOperation.idle,
          clearDocument: true,
          consent: false,
          notice: 'provider.submitted',
        ),
      ),
    );
  }

  Future<Uint8List?> readDocument() async {
    final verification = state.profile?.verification;
    if (state.isBusy || verification == null) return null;
    emit(state.copyWith(operation: ProviderOperation.reading));
    final result = await _repository.loadDocument(
      userId: _userId,
      verificationId: verification.id,
    );
    if (isClosed) return null;
    return result.fold(
      (failure) {
        _fail(failure.message);
        return null;
      },
      (bytes) {
        emit(state.copyWith(operation: ProviderOperation.idle));
        return bytes;
      },
    );
  }

  void _fail(String message, {int? step}) {
    emit(
      state.copyWith(
        operation: ProviderOperation.idle,
        errorMessage: message,
        step: step,
      ),
    );
  }
}
