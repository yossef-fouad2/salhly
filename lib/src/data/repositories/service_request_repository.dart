import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/auth_session.dart';
import '../models/service_request.dart';
import '../models/user_model.dart';
import '../../utils/failure.dart';
import '../../utils/logger.dart';
import '../../utils/task_runner.dart';
import '../../utils/typedefs.dart';
import 'auth_repository.dart';
import 'catalog_repository.dart';

typedef _CheckCustomer = void Function();

class ServiceRequestRepository {
  ServiceRequestRepository({
    required AuthRepository authRepository,
    this._client,
    DateTime Function()? now,
    this._timeout = const Duration(seconds: 30),
  }) : _auth = authRepository,
       _now = now ?? DateTime.now;

  final AuthRepository _auth;
  final SupabaseClient? _client;
  final DateTime Function() _now;
  final Duration _timeout;
  final _demoRequests = <String, ServiceRequest>{};
  final _demoPhotos = <String, List<RequestPhotoInput>>{};
  final _writingUsers = <String>{};
  final _uncertainRequests = <String>{};
  static const _bucket = 'request-photos';
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static const _sqlErrors = {
    'requests.errors.access',
    'requests.errors.not_found',
    'requests.errors.conflict',
    'requests.errors.category',
    'requests.errors.title',
    'requests.errors.description',
    'requests.errors.city',
    'requests.errors.address',
    'requests.errors.preferred_time',
    'requests.errors.photos',
    'requests.errors.photo_type',
    'requests.errors.photo_size',
    'requests.errors.consent',
    'requests.errors.status',
    'requests.errors.invalid_request',
  };

  bool get isDemo => _auth.isDemo;

  FutureEither<ServiceRequestPage> loadRequests({
    required String userId,
    ServiceRequest? before,
    int limit = 20,
  }) => _withCustomer(userId, (check) async {
    if (limit < 1 ||
        limit > 50 ||
        (before != null &&
            (before.customerId != userId ||
                !ServiceRequestDraft.validId(before.id)))) {
      throw const ServerFailure('requests.errors.invalid_request');
    }
    final List<ServiceRequest> rows;
    if (isDemo) {
      rows =
          _demoRequests.values
              .where(
                (request) =>
                    request.customerId == userId &&
                    (before == null ||
                        request.createdAt.isBefore(before.createdAt) ||
                        (request.createdAt.isAtSameMomentAs(before.createdAt) &&
                            request.id.compareTo(before.id) < 0)),
              )
              .toList()
            ..sort((a, b) {
              final time = b.createdAt.compareTo(a.createdAt);
              return time == 0 ? b.id.compareTo(a.id) : time;
            });
    } else {
      var query = _client!
          .from('service_requests')
          .select('*, photos:service_request_photos(*)')
          .eq('customer_id', userId);
      if (before != null) {
        final stamp = before.createdAt.toUtc().toIso8601String();
        query = query.or(
          'created_at.lt.$stamp,and(created_at.eq.$stamp,id.lt.${before.id})',
        );
      }
      final data = await query
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(limit + 1)
          .timeout(_timeout);
      check();
      rows = data.map((json) => _record(json, userId)).toList();
    }
    return ServiceRequestPage(
      items: rows.take(limit).toList(),
      hasMore: rows.length > limit,
    );
  });

  FutureEither<ServiceRequest> loadRequest(
    String requestId, {
    required String userId,
  }) => _withCustomer(userId, (check) async {
    _requireId(requestId);
    return await _find(requestId, userId, check) ??
        (throw const ServerFailure('requests.errors.not_found'));
  });

  FutureEither<ServiceRequest> submitRequest(
    ServiceRequestDraft draft, {
    required String userId,
  }) => _withCustomer(userId, (check) async {
    _requireId(draft.id);
    if (!draft.consent) throw const ServerFailure('requests.errors.consent');
    final attemptKey = '$userId/${draft.id}';
    final previouslyUncertain = _uncertainRequests.contains(attemptKey);
    final ServiceRequest? existing;
    try {
      existing = await _find(draft.id, userId, check);
    } catch (_) {
      check();
      if (previouslyUncertain) {
        throw const ServerFailure('requests.errors.submit_uncertain');
      }
      rethrow;
    }
    if (existing != null) {
      if (!_matches(existing, draft, userId)) {
        throw const ServerFailure('requests.errors.conflict');
      }
      _uncertainRequests.remove(attemptKey);
      return existing;
    }
    if (isDemo && _demoRequests.containsKey(draft.id)) {
      throw const ServerFailure('requests.errors.conflict');
    }
    final validation = draft.validate(now: _now());
    if (validation != null) {
      if (previouslyUncertain) {
        throw const ServerFailure('requests.errors.submit_uncertain');
      }
      throw ServerFailure(validation);
    }
    if (!isDemo && !_uuid.hasMatch(draft.categoryId!)) {
      throw const ServerFailure('requests.errors.category');
    }
    final manifest = [
      for (final (index, photo) in draft.photos.indexed)
        ServiceRequestPhoto(
          id: photo.id,
          storagePath: '$userId/${draft.id}/${photo.id}.${photo.extension}',
          mimeType: photo.mimeType,
          sizeBytes: photo.sizeBytes,
          position: index + 1,
        ),
    ];
    if (isDemo) {
      final categories = (await CatalogRepository().loadCategories()).fold(
        (failure) => throw failure,
        (value) => value,
      );
      check();
      final category = categories
          .where(
            (category) => category.id == draft.categoryId && category.isActive,
          )
          .firstOrNull;
      if (category == null) {
        throw const ServerFailure('requests.errors.category');
      }
      final now = _now().toUtc();
      final request = ServiceRequest(
        id: draft.id,
        customerId: userId,
        categoryId: category.id,
        categoryNameEn: category.name('en'),
        categoryNameAr: category.name('ar'),
        categoryIconKey: category.iconKey,
        title: draft.title.trim(),
        description: draft.description.trim(),
        city: draft.city.trim(),
        address: draft.address.trim(),
        preferredAt: draft.preferredAt?.toUtc(),
        status: ServiceRequestStatus.open,
        createdAt: now,
        consentedAt: now,
        photos: manifest,
      );
      _demoRequests[draft.id] = request;
      _demoPhotos[draft.id] = List.unmodifiable(draft.photos);
      return request;
    }

    final storage = _client!.storage.from(_bucket);
    final attemptedPaths = <String>{};
    final conflictingPaths = <String>{};
    var publicationStarted = false;
    try {
      for (final (index, photo) in draft.photos.indexed) {
        check();
        final path = manifest[index].storagePath;
        attemptedPaths.add(path);
        try {
          await storage
              .uploadBinary(
                path,
                photo.bytes,
                fileOptions: FileOptions(
                  contentType: photo.mimeType,
                  upsert: false,
                ),
                retryAttempts: 0,
              )
              .timeout(_timeout);
        } on StorageException catch (error) {
          if (error.statusCode != '409') rethrow;
          // Never delete an existing object. Reuse a staged retry only if its bytes match.
          conflictingPaths.add(path);
          final staged = await _download(path, photo.id, check);
          if (staged.sizeBytes != photo.sizeBytes ||
              staged.mimeType != photo.mimeType ||
              !Iterable<int>.generate(photo.sizeBytes)
                  .every((i) => staged.bytes[i] == photo.bytes[i])) {
            throw const ServerFailure('requests.errors.conflict');
          }
        }
        check();
      }
      publicationStarted = true;
      _uncertainRequests.add(attemptKey);
      final data = await _client
          .rpc<Object?>(
            'submit_service_request',
            params: {
              'p_request_id': draft.id,
              'p_category_id': draft.categoryId,
              'p_title': draft.title.trim(),
              'p_description': draft.description.trim(),
              'p_city': draft.city.trim(),
              'p_address': draft.address.trim(),
              'p_preferred_at': draft.preferredAt?.toUtc().toIso8601String(),
              'p_photos': manifest
                  .map(
                    (photo) => {
                      'id': photo.id,
                      'storage_path': photo.storagePath,
                      'mime_type': photo.mimeType,
                      'size_bytes': photo.sizeBytes,
                    },
                  )
                  .toList(),
              'p_consent': draft.consent,
            },
          )
          .timeout(_timeout);
      check();
      final request = _record(data, userId, id: draft.id);
      if (!_matches(request, draft, userId)) {
        throw const ServerFailure('requests.errors.conflict');
      }
      _uncertainRequests.remove(attemptKey);
      return request;
    } catch (error) {
      check();
      final ServiceRequest? canonical;
      try {
        canonical = await _find(draft.id, userId, check);
      } catch (_) {
        check();
        if (publicationStarted || previouslyUncertain) {
          _uncertainRequests.add(attemptKey);
          throw const ServerFailure('requests.errors.submit_uncertain');
        }
        AppLogger.warning(
          'Request photo cleanup deferred; reconciliation unavailable.',
        );
        throw _safeFailure(error, fallback: 'requests.errors.submit_failed');
      }
      if (canonical != null) {
        if (!_matches(canonical, draft, userId)) {
          throw const ServerFailure('requests.errors.conflict');
        }
        _uncertainRequests.remove(attemptKey);
        return canonical;
      }
      // An absent read cannot prove an in-flight server transaction will not commit.
      final definitiveRejection =
          error is PostgrestException && _sqlErrors.contains(error.message);
      if (previouslyUncertain || (publicationStarted && !definitiveRejection)) {
        _uncertainRequests.add(attemptKey);
        throw const ServerFailure('requests.errors.submit_uncertain');
      }
      _uncertainRequests.remove(attemptKey);
      final cleanup = attemptedPaths.difference(conflictingPaths).toList();
      if (cleanup.isNotEmpty) {
        try {
          check();
          // SQL independently rejects deleting referenced objects, including after cancellation.
          await storage.remove(cleanup).timeout(_timeout);
          check();
        } catch (_) {
          check();
          AppLogger.warning('Unreferenced request photo cleanup deferred.');
        }
      }
      throw _safeFailure(error, fallback: 'requests.errors.submit_failed');
    }
  }, writes: true);

  FutureEither<ServiceRequest> cancelRequest(
    String requestId, {
    required String userId,
  }) => _withCustomer(userId, (check) async {
    _requireId(requestId);
    final current = await _find(requestId, userId, check);
    if (current == null) throw const ServerFailure('requests.errors.not_found');
    if (current.status == ServiceRequestStatus.cancelled) return current;
    if (isDemo) {
      final cancelled = ServiceRequest.fromJson({
        ...current.toJson(),
        'status': 'cancelled',
        'cancelled_at': _now().toUtc().toIso8601String(),
      });
      _demoRequests[requestId] = cancelled;
      return cancelled;
    }
    try {
      final data = await _client!
          .rpc<Object?>(
            'cancel_service_request',
            params: {'p_request_id': requestId},
          )
          .timeout(_timeout);
      check();
      final cancelled = _record(data, userId, id: requestId);
      if (cancelled.status != ServiceRequestStatus.cancelled) {
        throw const ServerFailure('requests.errors.cancel_failed');
      }
      return cancelled;
    } catch (_) {
      check();
      try {
        final canonical = await _find(requestId, userId, check);
        if (canonical?.status == ServiceRequestStatus.cancelled) {
          return canonical!;
        }
      } catch (_) {
        check();
      }
      throw const ServerFailure('requests.errors.cancel_failed');
    }
  }, writes: true);

  FutureEither<Uint8List> loadPhoto({
    required String userId,
    required String requestId,
    required String photoId,
  }) => _withCustomer(userId, (check) async {
    _requireId(requestId);
    _requireId(photoId);
    final request = await _find(requestId, userId, check);
    final photo = request?.photos
        .where((photo) => photo.id == photoId)
        .firstOrNull;
    if (request == null || photo == null) {
      throw const ServerFailure('requests.errors.photo_unavailable');
    }
    final RequestPhotoInput? input;
    if (isDemo) {
      input = _demoPhotos[requestId]
          ?.where((photo) => photo.id == photoId)
          .firstOrNull;
    } else {
      input = await _download(photo.storagePath, photoId, check);
    }
    check();
    if (input == null ||
        input.sizeBytes != photo.sizeBytes ||
        input.mimeType != photo.mimeType ||
        photo.storagePath != '$userId/$requestId/$photoId.${input.extension}') {
      throw const ServerFailure('requests.errors.photo_unavailable');
    }
    return input.bytes;
  });

  Future<RequestPhotoInput> _download(
    String path,
    String photoId,
    _CheckCustomer check,
  ) async {
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk
          in _client!.storage
              .from(_bucket)
              .downloadStream(path)
              .timeout(_timeout)) {
        check();
        if (bytes.length + chunk.length > RequestPhotoInput.maxBytes) {
          throw const ServerFailure('requests.errors.photo_size');
        }
        bytes.add(chunk);
      }
      check();
      return RequestPhotoInput.fromBytes(bytes.takeBytes(), id: photoId);
    } on Failure {
      rethrow;
    } catch (_) {
      check();
      throw const ServerFailure('requests.errors.photo_unavailable');
    }
  }

  Future<ServiceRequest?> _find(
    String id,
    String userId,
    _CheckCustomer check,
  ) async {
    if (isDemo) {
      final request = _demoRequests[id];
      return request?.customerId == userId ? request : null;
    }
    final data = await _client!
        .rpc<Object?>('get_service_request', params: {'p_request_id': id})
        .timeout(_timeout);
    check();
    return data == null ? null : _record(data, userId, id: id);
  }

  ServiceRequest _record(Object? data, String userId, {String? id}) {
    try {
      final request = ServiceRequest.fromJson(data as Map<String, dynamic>);
      if (request.customerId != userId || (id != null && id != request.id)) {
        throw const ServerFailure('requests.errors.access');
      }
      return request;
    } on Failure {
      rethrow;
    } catch (_) {
      throw const ServerFailure('requests.errors.invalid_request');
    }
  }

  bool _matches(
    ServiceRequest request,
    ServiceRequestDraft draft,
    String userId,
  ) {
    final sameTime = request.preferredAt == null
        ? draft.preferredAt == null
        : draft.preferredAt != null &&
              request.preferredAt!.isAtSameMomentAs(draft.preferredAt!);
    if (request.id != draft.id ||
        request.customerId != userId ||
        request.categoryId != draft.categoryId ||
        request.title != draft.title.trim() ||
        request.description != draft.description.trim() ||
        request.city != draft.city.trim() ||
        request.address != draft.address.trim() ||
        !sameTime ||
        request.photos.length != draft.photos.length) {
      return false;
    }
    return Iterable<int>.generate(draft.photos.length).every((i) {
      final local = draft.photos[i];
      final remote = request.photos[i];
      return remote.id == local.id &&
          remote.mimeType == local.mimeType &&
          remote.sizeBytes == local.sizeBytes &&
          remote.storagePath ==
              '$userId/${draft.id}/${local.id}.${local.extension}';
    });
  }

  void _requireId(String id) {
    if (!ServiceRequestDraft.validId(id)) {
      throw const ServerFailure('requests.errors.not_found');
    }
  }

  FutureEither<T> _withCustomer<T>(
    String userId,
    Future<T> Function(_CheckCustomer check) action, {
    bool writes = false,
  }) => runTask(() async {
    StreamSubscription<AuthSession>? subscription;
    StreamSubscription<AuthState>? sdkSubscription;
    GoTrueClient? sdkAuth;
    var invalidated = false;
    var ownsLock = false;
    bool matches(AuthSession session) =>
        userId.isNotEmpty &&
        session.user?.id == userId &&
        session.user?.role == UserRole.customer &&
        !session.needsPasswordUpdate;
    void check() {
      if (invalidated ||
          (sdkAuth != null && sdkAuth.currentSession?.user.id != userId)) {
        throw const ServerFailure('requests.errors.access');
      }
    }

    try {
      if (!isDemo && _client == null) {
        throw const ServerFailure('errors.database_setup');
      }
      if (!isDemo && !_uuid.hasMatch(userId)) {
        throw const ServerFailure('requests.errors.access');
      }
      if (!isDemo) {
        sdkAuth = _client!.auth;
        var firstEvent = true;
        sdkSubscription = sdkAuth.onAuthStateChange.listen(
          (state) {
            final replay = firstEvent;
            firstEvent = false;
            if (state.session?.user.id != userId ||
                state.event == AuthChangeEvent.signedOut ||
                state.event == AuthChangeEvent.passwordRecovery ||
                (!replay &&
                    (state.event == AuthChangeEvent.signedIn ||
                        state.event == AuthChangeEvent.initialSession))) {
              invalidated = true;
            }
          },
          onError: (Object _) => invalidated = true,
          onDone: () => invalidated = true,
        );
      }
      subscription = _auth.onAuthStateChanged.listen(
        (session) {
          if (!matches(session)) invalidated = true;
        },
        onError: (Object _) => invalidated = true,
        onDone: () => invalidated = true,
      );
      check();
      final session = (await _auth.checkAuthState().timeout(_timeout)).fold(
        (_) => throw const ServerFailure('requests.errors.access'),
        (value) => value,
      );
      check();
      if (!matches(session)) {
        throw const ServerFailure('requests.errors.access');
      }
      if (writes) {
        ownsLock = _writingUsers.add(userId);
        if (!ownsLock) throw const ServerFailure('requests.errors.busy');
      }
      final result = await action(check);
      check();
      return result;
    } catch (error) {
      check();
      throw _safeFailure(error);
    } finally {
      if (ownsLock) _writingUsers.remove(userId);
      unawaited(subscription?.cancel());
      unawaited(sdkSubscription?.cancel());
    }
  });

  Failure _safeFailure(
    Object error, {
    String fallback = 'requests.errors.load_failed',
  }) {
    if (error is Failure) return error;
    if (error is PostgrestException) {
      if (_sqlErrors.contains(error.message)) {
        return ServerFailure(error.message);
      }
      if (const {'PGRST202', '42883', '42P01'}.contains(error.code)) {
        return const ServerFailure('errors.database_setup');
      }
    }
    if (error is TimeoutException || error is AuthRetryableFetchException) {
      return const NetworkFailure('errors.network');
    }
    return ServerFailure(fallback);
  }
}
