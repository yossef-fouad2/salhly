import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/service_category.dart';
import '../../data/models/service_request.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/service_request_repository.dart';
import '../../services/request_photo_picker.dart';

enum RequestFormOperation { idle, loading, picking, submitting }

class ServiceRequestFormState extends Equatable {
  const ServiceRequestFormState({
    required this.draft,
    this.categories = const [],
    this.catalogLoaded = false,
    this.step = 0,
    this.operation = RequestFormOperation.idle,
    this.isDirty = false,
    this.outcomeUncertain = false,
    this.submitted,
    this.errorMessage,
  });

  final ServiceRequestDraft draft;
  final List<ServiceCategory> categories;
  final bool catalogLoaded;
  final int step;
  final RequestFormOperation operation;
  final bool isDirty;
  final bool outcomeUncertain;
  final ServiceRequest? submitted;
  final String? errorMessage;

  bool get isBusy => operation != RequestFormOperation.idle;
  bool get canEdit => !isBusy && !outcomeUncertain && submitted == null;
  bool get hasUnsavedChanges => isDirty || outcomeUncertain;

  ServiceRequestFormState copyWith({
    ServiceRequestDraft? draft,
    List<ServiceCategory>? categories,
    bool? catalogLoaded,
    int? step,
    RequestFormOperation? operation,
    bool? isDirty,
    bool? outcomeUncertain,
    ServiceRequest? submitted,
    String? errorMessage,
  }) => ServiceRequestFormState(
    draft: draft ?? this.draft,
    categories: categories ?? this.categories,
    catalogLoaded: catalogLoaded ?? this.catalogLoaded,
    step: step ?? this.step,
    operation: operation ?? this.operation,
    isDirty: isDirty ?? this.isDirty,
    outcomeUncertain: outcomeUncertain ?? this.outcomeUncertain,
    submitted: submitted ?? this.submitted,
    errorMessage: errorMessage,
  );

  @override
  bool get stringify => false;

  @override
  List<Object?> get props => [
    draft,
    categories,
    catalogLoaded,
    step,
    operation,
    isDirty,
    outcomeUncertain,
    submitted,
    errorMessage,
  ];
}

/// A local draft until explicit submission; a stable ID makes retries safe.
class ServiceRequestFormCubit extends Cubit<ServiceRequestFormState> {
  ServiceRequestFormCubit({
    required this._userId,
    required this._repository,
    required this._catalog,
    required this._photoPicker,
    String? initialCategoryId,
    String initialCity = '',
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       super(
         ServiceRequestFormState(
           draft: ServiceRequestDraft.create(
             categoryId: initialCategoryId,
             city: initialCity,
           ),
         ),
       );

  final String _userId;
  final ServiceRequestRepository _repository;
  final CatalogRepository _catalog;
  final RequestPhotoPicker _photoPicker;
  final DateTime Function() _now;

  Future<void> load() async {
    if (!state.canEdit) return;
    emit(state.copyWith(operation: RequestFormOperation.loading));
    final result = await _catalog.loadCategories();
    if (isClosed) return;
    result.fold((failure) => _fail(failure.message), (categories) {
      final available =
          state.draft.categoryId == null ||
          categories.any((category) => category.id == state.draft.categoryId);
      emit(
        state.copyWith(
          categories: List.unmodifiable(categories),
          catalogLoaded: true,
          draft: available
              ? state.draft
              : state.draft.copyWith(clearCategory: true, consent: false),
          operation: RequestFormOperation.idle,
          errorMessage: available ? null : 'requests.errors.category',
        ),
      );
    });
  }

  void selectCategory(String id) {
    if (!state.categories.any((category) => category.id == id)) return;
    _edit(state.draft.copyWith(categoryId: id));
  }

  void updateTitle(String value) => _edit(state.draft.copyWith(title: value));
  void updateDescription(String value) =>
      _edit(state.draft.copyWith(description: value));
  void updateCity(String value) => _edit(state.draft.copyWith(city: value));
  void updateAddress(String value) =>
      _edit(state.draft.copyWith(address: value));
  void updatePreferredAt(DateTime? value) => _edit(
    state.draft.copyWith(
      preferredAt: value?.toUtc(),
      clearPreferredAt: value == null,
    ),
  );

  void _edit(ServiceRequestDraft draft) {
    if (!state.canEdit || draft == state.draft) return;
    emit(state.copyWith(draft: draft.copyWith(consent: false), isDirty: true));
  }

  void setConsent(bool value) {
    if (!state.canEdit) return;
    emit(
      state.copyWith(
        draft: state.draft.copyWith(consent: value),
        isDirty: true,
      ),
    );
  }

  void previousStep() {
    if (!state.canEdit || state.step == 0) return;
    emit(state.copyWith(step: state.step - 1));
  }

  void nextStep() {
    if (!state.canEdit || !state.catalogLoaded || state.step >= 2) return;
    final error = state.draft.validate(now: _now());
    if (error != null && _stepFor(error) <= state.step) {
      _fail(error, step: _stepFor(error));
      return;
    }
    emit(state.copyWith(step: state.step + 1));
  }

  Future<void> pickPhoto() async {
    if (!state.canEdit) return;
    if (state.draft.photos.length >= 3) {
      _fail('requests.errors.photos');
      return;
    }
    emit(state.copyWith(operation: RequestFormOperation.picking));
    final result = await _photoPicker.pick();
    if (isClosed) return;
    result.fold((failure) => _fail(failure.message), (photo) {
      emit(
        state.copyWith(
          operation: RequestFormOperation.idle,
          draft: photo == null
              ? state.draft
              : state.draft.copyWith(
                  photos: [...state.draft.photos, photo],
                  consent: false,
                ),
          isDirty: state.isDirty || photo != null,
        ),
      );
    });
  }

  void removePhoto(String id) {
    if (!state.canEdit) return;
    _edit(
      state.draft.copyWith(
        photos: state.draft.photos.where((photo) => photo.id != id).toList(),
      ),
    );
  }

  Future<void> submit() async {
    if (state.isBusy || state.submitted != null) return;
    if (!state.outcomeUncertain) {
      final error = state.draft.validate(now: _now());
      if (error != null) {
        _fail(error, step: _stepFor(error));
        return;
      }
      if (!state.catalogLoaded ||
          !state.categories.any(
            (category) => category.id == state.draft.categoryId,
          )) {
        _fail('requests.errors.category', step: 0);
        return;
      }
    }
    // An ambiguous result retries this exact frozen draft, even if time has passed.
    emit(state.copyWith(operation: RequestFormOperation.submitting));
    final result = await _repository.submitRequest(
      state.draft,
      userId: _userId,
    );
    if (isClosed) return;
    result.fold(
      (failure) {
        final uncertain =
            state.outcomeUncertain ||
            failure.message == 'requests.errors.submit_uncertain';
        emit(
          state.copyWith(
            operation: RequestFormOperation.idle,
            outcomeUncertain: uncertain,
            step: uncertain ? 2 : _stepFor(failure.message),
            errorMessage: failure.message,
          ),
        );
      },
      (request) {
        emit(
          state.copyWith(
            submitted: request,
            draft: state.draft.copyWith(photos: const [], consent: false),
            operation: RequestFormOperation.idle,
            isDirty: false,
            outcomeUncertain: false,
          ),
        );
      },
    );
  }

  static int _stepFor(String message) => switch (message) {
    'requests.errors.category' ||
    'requests.errors.title' ||
    'requests.errors.description' ||
    'requests.errors.photos' ||
    'requests.errors.photo_size' ||
    'requests.errors.photo_type' => 0,
    'requests.errors.city' ||
    'requests.errors.address' ||
    'requests.errors.preferred_time' => 1,
    _ => 2,
  };

  void _fail(String message, {int? step}) => emit(
    state.copyWith(
      operation: RequestFormOperation.idle,
      errorMessage: message,
      step: step,
    ),
  );
}
