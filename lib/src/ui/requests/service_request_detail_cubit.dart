import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/service_request.dart';
import '../../data/repositories/service_request_repository.dart';
import '../../utils/failure.dart';

class ServiceRequestDetailState extends Equatable {
  const ServiceRequestDetailState({
    this.request,
    this.loading = false,
    this.cancelling = false,
    this.readingPhotoId,
    this.errorMessage,
  });
  final ServiceRequest? request;
  final bool loading;
  final bool cancelling;
  final String? readingPhotoId;
  final String? errorMessage;
  bool get busy => loading || cancelling || readingPhotoId != null;
  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    request,
    loading,
    cancelling,
    readingPhotoId,
    errorMessage,
  ];
}

class ServiceRequestDetailCubit extends Cubit<ServiceRequestDetailState> {
  ServiceRequestDetailCubit({
    required this.userId,
    required this.requestId,
    required this._repository,
  }) : super(const ServiceRequestDetailState());
  final String userId;
  final String requestId;
  final ServiceRequestRepository _repository;

  Future<void> load() async {
    if (isClosed || state.busy) return;
    emit(ServiceRequestDetailState(request: state.request, loading: true));
    final result = await _repository.loadRequest(requestId, userId: userId);
    if (isClosed) return;
    result.fold(
      _fail,
      (request) => emit(ServiceRequestDetailState(request: request)),
    );
  }

  Future<void> cancel() async {
    if (isClosed ||
        state.busy ||
        state.request?.status != ServiceRequestStatus.open) {
      return;
    }
    emit(ServiceRequestDetailState(request: state.request, cancelling: true));
    final result = await _repository.cancelRequest(requestId, userId: userId);
    if (isClosed) return;
    result.fold(
      _fail,
      (request) => emit(ServiceRequestDetailState(request: request)),
    );
  }

  Future<Uint8List?> readPhoto(String photoId) async {
    if (isClosed ||
        state.busy ||
        !(state.request?.photos.any((photo) => photo.id == photoId) ?? false)) {
      return null;
    }
    emit(
      ServiceRequestDetailState(
        request: state.request,
        readingPhotoId: photoId,
      ),
    );
    final result = await _repository.loadPhoto(
      userId: userId,
      requestId: requestId,
      photoId: photoId,
    );
    if (isClosed) return null;
    return result.fold(
      (failure) {
        _fail(failure);
        return null;
      },
      (bytes) {
        emit(ServiceRequestDetailState(request: state.request));
        return bytes;
      },
    );
  }

  void _fail(Failure failure) => emit(
    ServiceRequestDetailState(
      request: state.request,
      errorMessage: failure.message,
    ),
  );
}
