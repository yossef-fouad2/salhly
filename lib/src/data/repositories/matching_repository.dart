import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/failure.dart';
import '../../utils/task_runner.dart';
import '../../utils/typedefs.dart';
import '../models/auth_session.dart';
import '../models/marketplace.dart';
import '../models/matching.dart';
import '../models/provider_profile.dart';
import '../models/user_model.dart';
import '../models/service_request.dart';
import 'auth_repository.dart';
import 'catalog_repository.dart';
import 'demo_marketplace_store.dart';
import 'provider_repository.dart';

typedef _Check = void Function();

class MatchingRepository {
  MatchingRepository({
    required AuthRepository authRepository,
    SupabaseClient? client,
    DemoMarketplaceStore? demoStore,
    ProviderRepository? providerRepository,
    CatalogRepository? catalogRepository,
    DateTime Function()? now,
    this._timeout = const Duration(seconds: 30),
  }) : _auth = authRepository,
       _client = client,
       _demo = demoStore ?? DemoMarketplaceStore(),
       _providers =
           providerRepository ??
           ProviderRepository(authRepository: authRepository, client: client),
       _catalog = catalogRepository ?? CatalogRepository(client: client),
       _now = now ?? DateTime.now;

  final AuthRepository _auth;
  final SupabaseClient? _client;
  final DemoMarketplaceStore _demo;
  final ProviderRepository _providers;
  final CatalogRepository _catalog;
  final DateTime Function() _now;
  final Duration _timeout;
  final _writing = <String>{};
  final _pending = <String, ProviderMatchingDraft>{};
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static const _sqlErrors = {
    'matching.errors.access',
    'matching.errors.not_found',
    'matching.errors.invalid',
    'matching.errors.consent',
    'matching.errors.location',
    'matching.errors.experience',
    'matching.errors.ineligible',
    'matching.errors.conflict',
    'matching.errors.status',
    'matching.errors.unpublished',
    'matching.errors.stale',
  };
  static const _setupErrors = {'PGRST202', 'PGRST205', '42883', '42P01'};
  bool get isDemo => _auth.isDemo;
  bool hasPendingSave({required String userId}) => _pending.containsKey(userId);

  FutureEither<MatchResults> loadMatches(
    MatchingQuery query, {
    required String userId,
    MatchingCursor? before,
    int limit = 20,
  }) => _withActor(userId, UserRole.customer, (user, check) async {
    final invalid = query.validate();
    if (invalid != null) throw ServerFailure(invalid);
    if (limit < 1 ||
        limit > 50 ||
        (before != null &&
            (!before.valid ||
                before.tieKey !=
                    matchingTieKey(query.requestId, before.providerId) ||
                (!isDemo && !_uuid.hasMatch(before.providerId))))) {
      throw const ServerFailure('matching.errors.invalid');
    }
    if (before != null &&
        (before.queryKey != query.cursorKey || before.mode != query.mode)) {
      throw const ServerFailure('matching.errors.stale');
    }
    if (isDemo) return _demoMatches(query, userId, check, before, limit);
    final result = MatchResults.fromJson(
      await _rpc('get_provider_matches', {
        'p_request_id': query.requestId,
        'p_mode': query.mode.wireName,
        'p_latitude': query.hasLocation ? query.parsedLatitude : null,
        'p_longitude': query.hasLocation ? query.parsedLongitude : null,
        'p_location_consent': query.hasLocation && query.locationConsent,
        'p_weekday': query.weekday,
        'p_minute': query.minute,
        'p_before_score_bps': before?.scoreBps,
        'p_before_tie_key': before?.tieKey,
        'p_before_provider_id': before?.providerId,
        'p_rules_revision': before?.rulesRevision,
        'p_before_query_key': before?.queryKey,
        'p_limit': limit,
      }, check),
    );
    if (result.listing.requestId != query.requestId ||
        result.mode != query.mode ||
        result.items.length > limit ||
        (result.hasMore && result.items.length != limit) ||
        (before != null && result.rules.revision != before.rulesRevision)) {
      throw const ServerFailure('matching.errors.invalid');
    }
    for (final candidate in result.items) {
      if (!_uuid.hasMatch(candidate.providerId) ||
          candidate.providerId == userId ||
          (!query.hasLocation && candidate.distanceKm != null) ||
          (query.weekday == null && candidate.available != null) ||
          (candidate.factors[0].reason == 'no_query_location') !=
              !query.hasLocation ||
          (candidate.factors[2].reason == 'no_time_preference') !=
              (query.weekday == null) ||
          (before != null &&
              _compareCursor(candidate, before, query.mode) <= 0)) {
        throw const ServerFailure('matching.errors.invalid');
      }
    }
    return result;
  });

  FutureEither<ProviderMatchingProfile> loadProfile({required String userId}) =>
      _withActor(userId, UserRole.provider, (user, check) async {
        if (isDemo) return _demoProfile(user);
        return _liveProfile(userId, check);
      });

  FutureEither<MatchingEligibility> loadEligibility({required String userId}) =>
      _withActor(userId, UserRole.provider, (user, check) async {
        final active = await _activeCategories(check);
        final fixture = isDemo ? _demo.providers[userId] : null;
        if (fixture != null) {
          return MatchingEligibility(
            skillIds: fixture.skillIds.where(active.contains).toList(),
            eligible:
                fixture.verified &&
                fixture.role == UserRole.provider &&
                fixture.skillIds.any(active.contains) &&
                fixture.serviceAreas.isNotEmpty,
          );
        }
        final profile = (await _providers.loadProfile(userId))
            .fold((failure) => throw failure, (value) => value);
        check();
        return MatchingEligibility(
          skillIds: profile.skillIds.where(active.contains).toList(),
          eligible:
              profile.verification?.status ==
                  ProviderVerificationStatus.verified &&
              profile.skillIds.any(active.contains) &&
              profile.serviceAreas.isNotEmpty,
        );
      });

  FutureEither<ProviderMatchingProfile> saveProfile(
    ProviderMatchingDraft draft, {
    required String userId,
  }) => _withActor(userId, UserRole.provider, (user, check) async {
    if (draft.providerId != userId) {
      throw const ServerFailure('matching.errors.access');
    }
    final invalid = draft.validate();
    if (invalid != null) throw ServerFailure(invalid);
    if (isDemo) return _saveDemo(draft, user, check);
    return _saveLive(draft, check);
  }, writes: true);

  FutureEither<ProviderMatchingProfile> retryPendingSave({
    required String userId,
  }) => _withActor(userId, UserRole.provider, (user, check) async {
    final draft = _pending[userId];
    if (draft == null) {
      if (isDemo) return _demoProfile(user);
      return _liveProfile(userId, check);
    }
    return _saveLive(draft, check);
  }, writes: true);

  Future<ProviderMatchingProfile> _liveProfile(
    String userId,
    _Check check,
  ) async {
    final value = ProviderMatchingProfile.fromJson(
      await _rpc('get_provider_matching_profile', {}, check),
    );
    if (value.providerId != userId) {
      throw const ServerFailure('matching.errors.access');
    }
    return value;
  }

  Future<ProviderMatchingProfile> _saveLive(
    ProviderMatchingDraft draft,
    _Check check,
  ) async {
    final previous = _pending[draft.providerId];
    if (previous != null &&
        (previous.expectedRevision != draft.expectedRevision ||
            previous.discoverable != draft.discoverable ||
            previous.parsedLatitude != draft.parsedLatitude ||
            previous.parsedLongitude != draft.parsedLongitude ||
            previous.consent != draft.consent ||
            previous.parsedExperienceYears.length !=
                draft.parsedExperienceYears.length ||
            previous.parsedExperienceYears.entries.any(
              (entry) => draft.parsedExperienceYears[entry.key] != entry.value,
            ))) {
      throw const ServerFailure('matching.errors.uncertain');
    }
    check();
    _pending[draft.providerId] = draft;
    try {
      final value = ProviderMatchingProfile.fromJson(
        await _rpc('save_provider_matching_profile', {
          'p_discoverable': draft.discoverable,
          'p_latitude': draft.parsedLatitude,
          'p_longitude': draft.parsedLongitude,
          'p_experience_years': draft.parsedExperienceYears,
          'p_expected_revision': draft.expectedRevision,
          'p_consent': draft.consent,
        }, check),
      );
      if (!draft.matches(value) ||
          value.revision != draft.expectedRevision + 1) {
        throw const ServerFailure('matching.errors.invalid');
      }
      check();
      _pending.remove(draft.providerId);
      return value;
    } catch (error) {
      check();
      if (previous == null &&
          error is PostgrestException &&
          (_sqlErrors.contains(error.message) ||
              _setupErrors.contains(error.code))) {
        _pending.remove(draft.providerId);
        throw _safeFailure(error);
      }
      try {
        final canonical = await _liveProfile(draft.providerId, check);
        check();
        if (canonical.revision == draft.expectedRevision + 1 &&
            draft.matches(canonical)) {
          _pending.remove(draft.providerId);
          return canonical;
        }
        if (canonical.revision > draft.expectedRevision) {
          _pending.remove(draft.providerId);
          throw const _ResolvedConflict();
        }
      } on _ResolvedConflict {
        throw const ServerFailure('matching.errors.conflict');
      } catch (_) {
        check();
      }
      // A missing/unchanged read cannot rule out a still-running timed-out save.
      throw const ServerFailure('matching.errors.uncertain');
    }
  }

  Future<Map<String, dynamic>> _rpc(
    String name,
    Map<String, Object?> params,
    _Check check,
  ) async {
    check();
    final data = await _client!
        .rpc<Object?>(name, params: params)
        .timeout(_timeout);
    check();
    if (data is! Map<String, dynamic>) {
      throw const ServerFailure('matching.errors.invalid');
    }
    return data;
  }

  Future<MatchResults> _demoMatches(
    MatchingQuery query,
    String userId,
    _Check check,
    MatchingCursor? before,
    int limit,
  ) async {
    final active = await _activeCategories(check);
    final request = _demo.requests[query.requestId];
    if (request == null || request.customerId != userId) {
      throw const ServerFailure('matching.errors.not_found');
    }
    final listing = _demo.listings[query.requestId];
    if (listing == null) {
      throw const ServerFailure('matching.errors.unpublished');
    }
    if (request.status != ServiceRequestStatus.open) {
      throw const ServerFailure('matching.errors.status');
    }
    final rules = _demo.matchingRules;
    if (rules.validate() != null) {
      throw const ServerFailure('matching.errors.invalid');
    }
    if (before != null && before.rulesRevision != rules.revision) {
      throw const ServerFailure('matching.errors.stale');
    }
    final candidates = <ProviderMatch>[];
    for (final profile in _demo.matchingProfiles.values) {
      final quote = _demo.quotes.values
          .where(
            (quote) =>
                quote.providerId == profile.providerId &&
                quote.requestId == query.requestId,
          )
          .firstOrNull;
      final provider =
          _demo.providers[profile.providerId] ??
          _demo.matchingProviders[profile.providerId];
      if (!profile.discoverable ||
          profile.consentedAt == null ||
          profile.providerId == userId ||
          (quote != null &&
              quote.status != QuoteStatus.pending &&
              quote.status != QuoteStatus.withdrawn) ||
          provider == null ||
          !provider.verified ||
          provider.role != UserRole.provider ||
          !active.contains(listing.categoryId) ||
          !provider.skillIds.contains(listing.categoryId) ||
          !provider.serviceAreas.any(
            (area) =>
                area.trim().toLowerCase() == listing.city.trim().toLowerCase(),
          )) {
        continue;
      }
      final score = scoreProviderMatch(
        query: query,
        rules: rules,
        profile: profile,
        categoryId: listing.categoryId,
        availability:
            _demo.matchingAvailability[profile.providerId] ?? const [],
      );
      if (!validProviderMatch(score, rules, listing.requestId)) {
        throw const ServerFailure('matching.errors.invalid');
      }
      if (before == null || _compareCursor(score, before, query.mode) > 0) {
        candidates.add(score);
      }
    }
    candidates.sort(
      (left, right) => compareProviderMatches(left, right, query.mode),
    );
    return MatchResults(
      listing: listing,
      rules: rules,
      mode: query.mode,
      items: candidates.take(limit).toList(),
      hasMore: candidates.length > limit,
    );
  }

  int _compareCursor(
    ProviderMatch value,
    MatchingCursor before,
    MatchMode mode,
  ) {
    if (mode == MatchMode.recommended && value.scoreBps != before.scoreBps) {
      return before.scoreBps.compareTo(value.scoreBps);
    }
    final tie = value.tieKey.compareTo(before.tieKey);
    return tie == 0 ? value.providerId.compareTo(before.providerId) : tie;
  }

  Future<Set<String>> _activeCategories(_Check check) async {
    final categories = (await _catalog.loadCategories()).fold(
      (failure) => throw failure,
      (value) => value,
    );
    check();
    return categories
        .where((category) => category.isActive)
        .map((category) => category.id)
        .toSet();
  }

  ProviderMatchingProfile _demoProfile(AppUser user) =>
      _demo.matchingProfiles[user.id] ??
      ProviderMatchingProfile(
        providerId: user.id,
        providerName: user.name.trim(),
      );

  Future<ProviderMatchingProfile> _saveDemo(
    ProviderMatchingDraft draft,
    AppUser user,
    _Check check,
  ) async {
    final previous = _demoProfile(user);
    if (previous.revision == draft.expectedRevision + 1 &&
        draft.matches(previous)) {
      return previous;
    }
    if (previous.revision != draft.expectedRevision) {
      throw const ServerFailure('matching.errors.conflict');
    }
    var current = previous;
    final withdrawalOnly =
        current.revision > 0 &&
        !draft.discoverable &&
        draft.parsedLatitude == current.latitude &&
        draft.parsedLongitude == current.longitude &&
        draft.parsedExperienceYears.length == current.experienceYears.length &&
        draft.parsedExperienceYears.entries.every(
          (entry) => current.experienceYears[entry.key] == entry.value,
        );
    if (!withdrawalOnly) {
      final active = await _activeCategories(check);
      final ownProfile = (await _providers.loadProfile(user.id))
          .fold((failure) => throw failure, (value) => value);
      check();
      current = _demoProfile(user);
      if (current.revision == draft.expectedRevision + 1 &&
          draft.matches(current)) {
        return current;
      }
      if (current.revision != draft.expectedRevision) {
        throw const ServerFailure('matching.errors.conflict');
      }
      final fixture = _demo.providers[user.id];
      final skills = fixture?.skillIds ?? ownProfile.skillIds;
      if (!active.containsAll(draft.parsedExperienceYears.keys) ||
          !skills.toSet().containsAll(draft.parsedExperienceYears.keys)) {
        throw const ServerFailure('matching.errors.experience');
      }
      if (draft.discoverable &&
          (fixture == null ||
              !fixture.verified ||
              fixture.role != UserRole.provider ||
              !fixture.skillIds.any(active.contains) ||
              fixture.serviceAreas.isEmpty)) {
        throw const ServerFailure('matching.errors.ineligible');
      }
    }
    var now = _now().toUtc();
    if (current.updatedAt != null && !now.isAfter(current.updatedAt!)) {
      now = current.updatedAt!.add(const Duration(microseconds: 1));
    }
    final saved = ProviderMatchingProfile(
      providerId: user.id,
      providerName: draft.discoverable
          ? user.name.trim()
          : current.providerName,
      discoverable: draft.discoverable,
      latitude: draft.parsedLatitude,
      longitude: draft.parsedLongitude,
      experienceYears: draft.parsedExperienceYears,
      revision: current.revision + 1,
      consentedAt: draft.discoverable ? now : current.consentedAt,
      updatedAt: now,
    );
    _demo.matchingProfiles[user.id] = saved;
    return saved;
  }

  FutureEither<T> _withActor<T>(
    String userId,
    UserRole role,
    Future<T> Function(AppUser, _Check) action, {
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
        session.user?.role == role &&
        !session.needsPasswordUpdate;
    void check() {
      if (invalidated ||
          (sdkAuth != null && sdkAuth.currentSession?.user.id != userId)) {
        throw const ServerFailure('matching.errors.access');
      }
    }

    try {
      if (!isDemo && _client == null) {
        throw const ServerFailure('errors.database_setup');
      }
      if (!isDemo && !_uuid.hasMatch(userId)) {
        throw const ServerFailure('matching.errors.access');
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
        (_) => throw const ServerFailure('matching.errors.access'),
        (value) => value,
      );
      check();
      if (!matches(session)) {
        throw const ServerFailure('matching.errors.access');
      }
      if (writes) {
        ownsLock = _writing.add(userId);
        if (!ownsLock) throw const ServerFailure('matching.errors.busy');
      }
      final result = await action(session.user!, check);
      check();
      return result;
    } catch (error) {
      check();
      throw _safeFailure(error);
    } finally {
      if (ownsLock) _writing.remove(userId);
      unawaited(subscription?.cancel());
      unawaited(sdkSubscription?.cancel());
    }
  });

  Failure _safeFailure(Object error) {
    if (error is Failure) return error;
    if (error is PostgrestException) {
      if (_sqlErrors.contains(error.message)) {
        return ServerFailure(error.message);
      }
      if (_setupErrors.contains(error.code)) {
        return const ServerFailure('errors.database_setup');
      }
    }
    if (error is TimeoutException || error is AuthRetryableFetchException) {
      return const NetworkFailure('errors.network');
    }
    if (error is FormatException || error is TypeError || error is StateError) {
      return const ServerFailure('matching.errors.invalid');
    }
    return const ServerFailure('matching.errors.load_failed');
  }
}

class _ResolvedConflict {
  const _ResolvedConflict();
}
