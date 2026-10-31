import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/models/verification_document.dart';
import 'package:salahly/src/data/repositories/auth_repository.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';
import 'package:salahly/src/utils/error_handler.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/logger.dart';
import 'package:salahly/src/utils/task_runner.dart';
import 'package:salahly/src/utils/typedefs.dart';

typedef _CheckAccess = void Function();

class ProviderRepository {
  ProviderRepository({required this._authRepository, this._client});

  final AuthRepository _authRepository;
  final SupabaseClient? _client;
  final _demoProfiles = <String, ProviderProfile>{};
  final _demoDocuments = <String, VerificationDocument>{};
  final _writingUsers = <String>{};
  final _random = Random.secure();

  static const _bucket = 'provider-verification';
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static const _sqlErrorKeys = {
    'provider.errors.access',
    'provider.errors.invalid_profile',
    'provider.errors.bio',
    'provider.errors.skills',
    'provider.errors.areas',
    'provider.errors.availability',
    'provider.errors.incomplete',
    'provider.errors.consent',
    'provider.errors.locked',
    'provider.errors.document_unavailable',
    'provider.errors.document_type',
    'provider.errors.document_size',
  };

  bool get isDemo => _authRepository.isDemo;

  FutureEither<ProviderProfile> loadProfile(String userId) {
    return _withProvider(userId, (check) => _loadProfile(userId, check));
  }

  FutureEither<ProviderProfile> saveProfile(ProviderProfile profile) {
    return _withProvider(profile.userId, (check) async {
      final validation = profile.validate();
      if (validation != null) throw ServerFailure(validation);
      if (isDemo) {
        final current =
            _demoProfiles[profile.userId] ??
            ProviderProfile.empty(profile.userId);
        if (!current.canEdit) {
          throw const ServerFailure('provider.errors.locked');
        }
        final categories = (await CatalogRepository().loadCategories()).fold(
          (failure) => throw failure,
          (value) => value,
        );
        check();
        final activeIds = categories
            .where((category) => category.isActive)
            .map((category) => category.id)
            .toSet();
        if (!activeIds.containsAll(profile.skillIds)) {
          throw const ServerFailure('provider.errors.skills');
        }
        final saved = profile.copyWith(
          bio: profile.bio.trim(),
          serviceAreas: profile.serviceAreas
              .map((area) => area.trim())
              .toList(),
          verification: current.verification,
        );
        _demoProfiles[profile.userId] = saved;
        return saved;
      }
      final data = await _client!.rpc<Object?>(
        'save_provider_onboarding',
        params: {
          'p_provider_id': profile.userId,
          'p_bio': profile.bio.trim(),
          'p_skill_ids': profile.skillIds,
          'p_service_areas': profile.serviceAreas
              .map((area) => area.trim())
              .toList(),
          'p_availability': profile.availability
              .map((hours) => hours.toJson())
              .toList(),
        },
      );
      check();
      return _profileFrom(data, profile.userId);
    }, writes: true);
  }

  FutureEither<ProviderProfile> submitVerification({
    required String userId,
    required VerificationDocument document,
    required bool consent,
  }) {
    return _withProvider(userId, (check) async {
      if (!consent) throw const ServerFailure('provider.errors.consent');
      final profile = await _loadProfile(userId, check);
      check();
      if (!profile.canSubmit) {
        throw const ServerFailure('provider.errors.locked');
      }
      final validation = profile.validate(forSubmission: true);
      if (validation != null) throw ServerFailure(validation);

      final token = List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final path = '$userId/$token.${document.extension}';
      if (isDemo) {
        final submitted = profile.copyWith(
          verification: ProviderVerification(
            id: 'demo-$token',
            documentPath: path,
            mimeType: document.mimeType,
            sizeBytes: document.sizeBytes,
            status: ProviderVerificationStatus.pending,
            submittedAt: DateTime.now().toUtc(),
          ),
        );
        _demoProfiles[userId] = submitted;
        _demoDocuments[userId] = document;
        return submitted;
      }

      final storage = _client!.storage.from(_bucket);
      try {
        await storage.uploadBinary(
          path,
          document.bytes,
          fileOptions: FileOptions(
            contentType: document.mimeType,
            upsert: false,
          ),
          retryAttempts: 0,
        );
        check();
        final data = await _client.rpc<Object?>(
          'submit_provider_verification',
          params: {
            'p_provider_id': userId,
            'p_document_path': path,
            'p_consent': consent,
          },
        );
        check();
        final submitted = _profileFrom(data, userId);
        if (submitted.verification?.documentPath != path) {
          throw const ServerFailure('provider.errors.upload');
        }
        return submitted;
      } catch (error) {
        final original = _safeFailure(
          error,
          fallback: 'provider.errors.upload',
        );
        // Never retry or clean up using a replacement account's credentials.
        try {
          check();
        } on Failure {
          AppLogger.warning(
            'Verification cleanup deferred; authorization unavailable.',
          );
          rethrow;
        }
        if (error is StorageException && error.statusCode == '409') {
          throw original;
        }
        final ProviderProfile canonical;
        try {
          canonical = await _loadProfile(userId, check);
          check();
        } catch (_) {
          check();
          AppLogger.warning(
            'Verification reconciliation failed; cleanup deferred.',
          );
          throw ServerFailure('provider.errors.cleanup', error: original);
        }
        // A lost response can still mean the transaction committed, even reviewed.
        if (canonical.verification?.documentPath == path) return canonical;
        try {
          // SQL also denies deletion of referenced evidence across commit races.
          await storage.remove([path]);
          check();
        } catch (_) {
          check();
          AppLogger.warning(
            'Verification cleanup failed; reload before retrying.',
          );
          throw ServerFailure('provider.errors.cleanup', error: original);
        }
        throw original;
      }
    }, writes: true);
  }

  FutureEither<Uint8List> loadDocument({
    required String userId,
    required String verificationId,
  }) {
    return _withProvider(userId, (check) async {
      final profile = await _loadProfile(userId, check);
      check();
      final verification = profile.verification;
      if (verificationId.isEmpty ||
          verification == null ||
          verification.id != verificationId ||
          !RegExp('^${RegExp.escape(userId)}/[0-9a-f]{32}\\.(jpg|png)\$')
              .hasMatch(verification.documentPath)) {
        throw const ServerFailure('provider.errors.document_unavailable');
      }
      if (verification.sizeBytes <= 0 ||
          verification.sizeBytes > VerificationDocument.maxBytes) {
        throw const ServerFailure('provider.errors.document_size');
      }
      if (verification.mimeType != 'image/jpeg' &&
          verification.mimeType != 'image/png') {
        throw const ServerFailure('provider.errors.document_type');
      }
      final VerificationDocument document;
      if (isDemo) {
        final stored = _demoDocuments[userId];
        if (stored == null) {
          throw const ServerFailure('provider.errors.document_unavailable');
        }
        document = stored;
      } else {
        final bytes = BytesBuilder(copy: false);
        try {
          final stream = _client!.storage
              .from(_bucket)
              .downloadStream(verification.documentPath);
          await for (final chunk in stream) {
            check();
            if (bytes.length + chunk.length > VerificationDocument.maxBytes) {
              throw const ServerFailure('provider.errors.document_size');
            }
            bytes.add(chunk);
          }
        } on Failure {
          rethrow;
        } catch (_) {
          check();
          throw const ServerFailure('provider.errors.document_unavailable');
        }
        check();
        document = VerificationDocument.fromBytes(bytes.takeBytes());
      }
      if (document.sizeBytes != verification.sizeBytes ||
          document.mimeType != verification.mimeType ||
          !verification.documentPath.endsWith('.${document.extension}')) {
        throw const ServerFailure('provider.errors.document_unavailable');
      }
      return document.bytes;
    });
  }

  Future<ProviderProfile> _loadProfile(
    String userId,
    _CheckAccess check,
  ) async {
    if (isDemo) {
      return _demoProfiles[userId] ?? ProviderProfile.empty(userId);
    }
    final data = await _client!.rpc<Object?>(
      'get_provider_onboarding',
      params: {'p_provider_id': userId},
    );
    check();
    return _profileFrom(data, userId);
  }

  ProviderProfile _profileFrom(Object? data, String userId) {
    try {
      final profile = ProviderProfile.fromJson(data as Map<String, dynamic>);
      if (profile.userId != userId) {
        throw const ServerFailure('provider.errors.access');
      }
      if (profile.validate() != null) {
        throw const ServerFailure('provider.errors.invalid_profile');
      }
      return profile;
    } on Failure {
      rethrow;
    } catch (_) {
      throw const ServerFailure('provider.errors.invalid_profile');
    }
  }

  FutureEither<T> _withProvider<T>(
    String userId,
    Future<T> Function(_CheckAccess check) action, {
    bool writes = false,
  }) {
    return runTask(() async {
      StreamSubscription<AuthSession>? subscription;
      StreamSubscription<AuthState>? sdkSubscription;
      GoTrueClient? sdkAuth;
      var invalidated = false;
      var ownsWriteLock = false;
      bool matches(AuthSession session) =>
          userId.trim().isNotEmpty &&
          session.user?.id == userId &&
          session.user?.role == UserRole.provider &&
          !session.needsPasswordUpdate;

      void check() {
        if (invalidated ||
            (sdkAuth != null && sdkAuth.currentSession?.user.id != userId)) {
          throw const ServerFailure('provider.errors.access');
        }
      }

      try {
        if (!isDemo && _client == null) {
          throw const ServerFailure('errors.database_setup');
        }
        if (!isDemo && !_uuid.hasMatch(userId)) {
          throw const ServerFailure('provider.errors.access');
        }
        if (!isDemo) {
          sdkAuth = _client!.auth;
          var firstEvent = true;
          sdkSubscription = sdkAuth.onAuthStateChange.listen(
            (state) {
              // The first event is replayed. Restoring the same session can
              // replace the Session object without emitting a new auth event.
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
        // Keep an operation invalidated even after logout followed by same-user login.
        subscription = _authRepository.onAuthStateChanged.listen(
          (session) {
            if (!matches(session)) invalidated = true;
          },
          onError: (Object _) => invalidated = true,
          onDone: () => invalidated = true,
        );
        check();
        // Only this initial check reads the role/profile over the network.
        final session = (await _authRepository.checkAuthState()).fold(
          (_) => throw const ServerFailure('provider.errors.access'),
          (value) => value,
        );
        check();
        if (!matches(session)) {
          throw const ServerFailure('provider.errors.access');
        }
        if (writes) {
          ownsWriteLock = _writingUsers.add(userId);
          if (!ownsWriteLock) {
            throw const ServerFailure('provider.errors.locked');
          }
        }
        final result = await action(check);
        check();
        return result;
      } catch (error) {
        check();
        throw _safeFailure(error);
      } finally {
        if (ownsWriteLock) _writingUsers.remove(userId);
        unawaited(subscription?.cancel());
        unawaited(sdkSubscription?.cancel());
      }
    });
  }

  Failure _safeFailure(
    Object error, {
    String fallback = 'errors.request_failed',
  }) {
    if (error is Failure) return error;
    if (error is PostgrestException) {
      if (_sqlErrorKeys.contains(error.message)) {
        return ServerFailure(error.message);
      }
      if (error.code == 'PGRST202' || error.code == '42883') {
        return const ServerFailure('errors.database_setup');
      }
      return ServerFailure(AppErrorHandler.format(error));
    }
    if (error is TimeoutException || error is AuthRetryableFetchException) {
      return const NetworkFailure('errors.network');
    }
    // Backend exceptions can contain object paths or tokens. Do not retain/log them.
    return ServerFailure(fallback);
  }
}
