import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/matching.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';
import 'package:salahly/src/ui/matching/provider_matching_cubit.dart';
import 'package:salahly/src/ui/matching/request_matching_cubit.dart';
import 'package:salahly/src/utils/failure.dart';

import 'matching_ui_fakes.dart';

Future<SessionBloc> _session(
  DemoAuthRepository auth, {
  bool provider = false,
}) async {
  await auth.login(
    email: provider
        ? DemoAuthRepository.marketplaceProviderEmail
        : DemoAuthRepository.customerEmail,
    password: DemoAuthRepository.demoPassword,
  );
  final session = SessionBloc(repository: auth);
  await session.stream.firstWhere(
    (state) => state.status == SessionStatus.authenticated,
  );
  addTearDown(session.close);
  addTearDown(auth.dispose);
  return session;
}

Future<void> _replaceSameAccount(
  DemoAuthRepository auth,
  SessionBloc session, {
  bool provider = false,
}) async {
  final out = session.stream.firstWhere(
    (state) => state.status == SessionStatus.unauthenticated,
  );
  await auth.logout();
  await out;
  final back = session.stream.firstWhere(
    (state) => state.status == SessionStatus.authenticated,
  );
  await auth.login(
    email: provider
        ? DemoAuthRepository.marketplaceProviderEmail
        : DemoAuthRepository.customerEmail,
    password: DemoAuthRepository.demoPassword,
  );
  await back;
}

void main() {
  group('request matching', () {
    late DemoAuthRepository auth;
    late SessionBloc session;
    late MatchingUiRepository repository;
    late RequestMatchingCubit cubit;
    var now = uiNow;
    setUp(() async {
      auth = DemoAuthRepository();
      session = await _session(auth);
      repository = MatchingUiRepository(auth);
      now = uiNow;
      cubit = RequestMatchingCubit(
        userId: uiCustomerId,
        requestId: uiRequestId,
        repository: repository,
        session: session,
        now: () => now,
      );
      addTearDown(cubit.close);
      await cubit.refresh();
    });

    test('separate query starts blank and sends coordinates only after explicit consent', () async {
      final initial = repository.reads.single.query;
      expect(initial.latitude, isEmpty);
      expect(initial.longitude, isEmpty);
      expect(initial.locationConsent, isFalse);
      expect(initial.weekday, isNull);
      expect(initial.time, isEmpty);
      cubit.updateLatitude('30.04');
      await cubit.apply();
      expect(cubit.state.errorMessage, 'matching.errors.location');
      cubit.updateLongitude('31.20');
      await cubit.apply();
      expect(cubit.state.errorMessage, 'matching.errors.consent');
      expect(repository.reads, hasLength(1));
      cubit.setLocationConsent(true);
      await cubit.apply();
      expect(repository.reads.last.query.parsedLatitude, 30.04);
      expect(repository.reads.last.query.parsedLongitude, 31.20);
      expect(repository.reads.last.before, isNull);
      cubit.updateLongitude('31.21');
      expect(cubit.state.query.locationConsent, isFalse);
      expect(cubit.state.hasUnappliedChanges, isTrue);
      expect(cubit.state.canLoadMore, isFalse);
    });

    test(
      'explicit paired local day/time accepts Arabic digits and can be cleared',
      () async {
        cubit.setWeekday(1);
        await cubit.apply();
        expect(cubit.state.errorMessage, 'matching.errors.time');
        cubit.updateTime('\u0661\u0664:\u0663\u0660');
        await cubit.apply();
        expect(repository.reads.last.query.weekday, 1);
        expect(repository.reads.last.query.minute, 870);
        await cubit.clearInputs();
        expect(cubit.state.query.weekday, isNull);
        expect(cubit.state.query.time, isEmpty);
        expect(cubit.state.query.locationConsent, isFalse);
        expect(cubit.state.formVersion, 1);
      },
    );

    test('refresh uses applied inputs, never unsent edits', () async {
      cubit.updateLatitude('30.04');
      cubit.updateLongitude('31.20');
      await cubit.refresh();
      expect(repository.reads.last.query.hasLocation, isFalse);
      expect(cubit.state.query.latitude, '30.04');
      expect(cubit.state.showingPrevious, isTrue);
    });

    test(
      'mode change supersedes a late page and resets query-bound pagination',
      () async {
        final old = Completer<Either<Failure, MatchResults>>();
        repository.pendingMatches = old;
        final refreshing = cubit.refresh();
        repository.pendingMatches = null;
        final changed = matchingCandidate(
          providerId: 'all-eligible-only',
          name: 'Synthetic All Eligible',
        );
        repository.results = matchingResults(items: [changed]);
        await cubit.setMode(MatchMode.allEligible);
        old.complete(right(matchingResults()));
        await refreshing;
        expect(cubit.state.results!.mode, MatchMode.allEligible);
        expect(cubit.state.results!.items, [changed]);
        expect(repository.reads.last.before, isNull);
        expect(repository.reads.last.query.mode, MatchMode.allEligible);
      },
    );

    test(
      'new applied point supersedes loading more without splicing rows',
      () async {
        final pool = matchingCandidates(22);
        repository.results = matchingResults(
          items: pool.take(20).toList(),
          hasMore: true,
        );
        await cubit.refresh();
        final old = Completer<Either<Failure, MatchResults>>();
        repository.pendingMatches = old;
        final more = cubit.loadMore();
        cubit.updateLatitude('30.04');
        cubit.updateLongitude('31.20');
        cubit.setLocationConsent(true);
        repository.pendingMatches = null;
        final changed = matchingCandidate(
          providerId: 'new-query-provider',
          name: 'Synthetic New Query',
        );
        repository.results = matchingResults(items: [changed]);
        await cubit.apply();
        old.complete(right(matchingResults(items: pool.skip(20).toList())));
        await more;
        expect(cubit.state.results!.items, [changed]);
        expect(cubit.state.appliedQuery!.hasLocation, isTrue);
        expect(repository.reads.last.before, isNull);
      },
    );

    test(
      'bounded pages preserve global order and dedupe identical stable IDs',
      () async {
        final pool = matchingCandidates(22);
        repository.results = matchingResults(
          items: pool.take(20).toList(),
          hasMore: true,
        );
        await cubit.refresh();
        repository.results = matchingResults(
          items: [pool[19], ...pool.skip(20)],
        );
        await cubit.loadMore();
        expect(repository.reads.last.limit, 20);
        expect(
          repository.reads.last.before,
          pool[19].cursor(
            const MatchingRules(),
            MatchMode.recommended,
            query: cubit.state.appliedQuery!,
          ),
        );
        expect(
          repository.reads.last.before!.queryKey,
          cubit.state.appliedQuery!.cursorKey,
        );
        expect(cubit.state.results!.items, pool);
        expect(cubit.state.results!.hasMore, isFalse);
      },
    );

    test(
      'changed duplicate restarts instead of replacing an old rank in place',
      () async {
        final pool = matchingCandidates(21);
        repository.results = matchingResults(
          items: pool.take(20).toList(),
          hasMore: true,
        );
        await cubit.refresh();
        final changed = matchingCandidate(
          providerId: pool.first.providerId,
          name: pool.first.providerName,
          years: 10,
        );
        repository.onMatches = (query, before) async => right(
          matchingResults(
            query: query,
            items: before == null ? [changed] : [changed, pool.last],
          ),
        );
        await cubit.loadMore();
        expect(repository.reads, hasLength(4));
        expect(repository.reads[2].before, isNotNull);
        expect(repository.reads.last.before, isNull);
        expect(cubit.state.results!.items, [changed]);
        expect(cubit.state.stale, isFalse);
      },
    );

    test(
      'globally out-of-order new row restarts without sorting mixed snapshots',
      () async {
        final previous = matchingCandidate();
        repository.results = matchingResults(items: [previous], hasMore: true);
        await cubit.refresh();
        final better = matchingCandidate(
          providerId: 'higher-score-new',
          name: 'Synthetic Higher Score',
          years: 10,
        );
        repository.onMatches = (query, before) async =>
            right(matchingResults(query: query, items: [better]));
        await cubit.loadMore();
        expect(repository.reads.last.before, isNull);
        expect(cubit.state.results!.items, [better]);
      },
    );

    test(
      'changed rules restart first page before new configuration is displayed',
      () async {
        repository.results = matchingResults(hasMore: true);
        await cubit.refresh();
        const rules = MatchingRules(
          revision: 2,
          distanceWeight: 70,
          ratingWeight: 50,
          availabilityWeight: 40,
          experienceWeight: 40,
        );
        final changed = matchingCandidate(
          providerId: 'new-rules-provider',
          name: 'Synthetic New Rules',
          rules: rules,
        );
        repository.onMatches = (query, before) async => right(
          matchingResults(query: query, rules: rules, items: [changed]),
        );
        await cubit.loadMore();
        expect(repository.reads.last.before, isNull);
        expect(cubit.state.results!.rules, rules);
        expect(cubit.state.results!.items, [changed]);
      },
    );

    test(
      'server stale cursor and aged page refresh rather than append',
      () async {
        repository.results = matchingResults(hasMore: true);
        await cubit.refresh();
        repository.onMatches = (query, before) async => before == null
            ? right(matchingResults(query: query, hasMore: true))
            : left(const ServerFailure('matching.errors.stale'));
        await cubit.loadMore();
        expect(repository.reads.last.before, isNull);
        now = now.add(const Duration(minutes: 6));
        await cubit.loadMore();
        expect(repository.reads.last.before, isNull);
      },
    );

    test('ordinary read failure retains content but unavailable ownership erases it', () async {
      final previous = cubit.state.results;
      repository.readFailure = const NetworkFailure('errors.network');
      await cubit.refresh();
      expect(cubit.state.results, same(previous));
      expect(cubit.state.stale, isTrue);
      cubit.updateLatitude('30.04');
      repository.readFailure = const ServerFailure('matching.errors.not_found');
      await cubit.refresh();
      expect(cubit.state.results, isNull);
      expect(cubit.state.revoked, isTrue);
      expect(cubit.state.query.latitude, isEmpty);
    });

    for (final error in [
      'matching.errors.unpublished',
      'matching.errors.status',
    ]) {
      test(
        '$error clears prior candidates without publishing or selecting',
        () async {
          repository.readFailure = ServerFailure(error);
          await cubit.refresh();
          expect(cubit.state.results, isNull);
          expect(cubit.state.revoked, isFalse);
          expect(cubit.state.errorMessage, error);
        },
      );
    }

    test(
      'same-account replacement permanently ignores a late matching response',
      () async {
        repository.pendingMatches = Completer();
        final loading = cubit.refresh();
        await _replaceSameAccount(auth, session);
        repository.pendingMatches!.complete(right(matchingResults()));
        await loading;
        expect(cubit.state.revoked, isTrue);
        expect(cubit.state.results, isNull);
        final calls = repository.reads.length;
        await cubit.refresh();
        expect(repository.reads, hasLength(calls));
      },
    );
  });

  group('provider matching settings', () {
    late DemoAuthRepository auth;
    late SessionBloc session;
    late MatchingUiRepository repository;
    late MatchingUiCatalog catalog;
    late ProviderMatchingCubit cubit;
    setUp(() async {
      auth = DemoAuthRepository();
      session = await _session(auth, provider: true);
      repository = MatchingUiRepository(auth);
      catalog = MatchingUiCatalog();
      cubit = ProviderMatchingCubit(
        userId: uiProviderId,
        repository: repository,
        catalogRepository: catalog,
        session: session,
      );
      addTearDown(cubit.close);
      await cubit.load();
    });

    test('blank optional defaults stay separate from eligibility and self-reported zero', () async {
      expect(cubit.state.draft.discoverable, isFalse);
      expect(cubit.state.draft.consent, isFalse);
      expect(cubit.state.draft.latitude, isEmpty);
      expect(cubit.state.draft.longitude, isEmpty);
      expect(cubit.state.draft.experienceYears, isEmpty);
      expect(cubit.state.hasUnsavedChanges, isFalse);
      expect(cubit.state.currentCategories.map((item) => item.id), [
        'demo-plumbing',
      ]);
      cubit.updateExperience('demo-plumbing', '0');
      await cubit.save();
      expect(repository.drafts.single.consent, isFalse);
      expect(repository.profile.discoverable, isFalse);
      expect(repository.profile.experienceYears, {'demo-plumbing': 0});
      expect(cubit.state.hasUnsavedChanges, isFalse);
    });

    test(
      'enabled saves need fresh disclosure consent after every relevant edit',
      () async {
        cubit.setDiscoverable(true);
        await cubit.save();
        expect(cubit.state.errorMessage, 'matching.errors.consent');
        cubit.setConsent(true);
        cubit.updateLatitude('30.04');
        cubit.updateLongitude('31.20');
        expect(cubit.state.draft.consent, isFalse);
        cubit.setConsent(true);
        cubit.updateExperience('demo-plumbing', '4');
        expect(cubit.state.draft.consent, isFalse);
        await cubit.save();
        expect(repository.drafts, isEmpty);
        cubit.setConsent(true);
        await cubit.save();
        expect(repository.profile.discoverable, isTrue);
        expect(repository.profile.latitude, 30.04);
        expect(repository.profile.providerName, repository.currentName);
        expect(cubit.state.draft.consent, isFalse);
        expect(cubit.state.hasUnsavedChanges, isFalse);
      },
    );

    test('ineligible or pending provider may save privately but cannot enable discovery', () async {
      repository.eligibility = MatchingEligibility(
        skillIds: const ['demo-plumbing'],
        eligible: false,
      );
      await cubit.load();
      cubit.setDiscoverable(true);
      expect(cubit.state.draft.discoverable, isFalse);
      expect(cubit.state.canEnableDiscovery, isFalse);
      cubit.updateLatitude('30.04');
      cubit.updateLongitude('31.20');
      await cubit.save();
      expect(repository.profile.discoverable, isFalse);
      expect(repository.drafts.single.consent, isFalse);
    });

    test('metadata failures do not overwrite authoritative settings or grant approval', () async {
      cubit.updateLatitude('30.04');
      cubit.updateLongitude('31.20');
      repository.eligibilityFailure = const NetworkFailure('errors.network');
      await cubit.load();
      expect(cubit.state.profile, isNotNull);
      expect(cubit.state.draft.latitude, '30.04');
      expect(cubit.state.metadataError, 'errors.network');
      expect(cubit.state.currentCategories, isEmpty);
      expect(cubit.state.canEnableDiscovery, isFalse);
      expect(cubit.state.canSave, isTrue);
    });

    test('catalog is loaded once across refreshes, with an explicit failed-catalog retry', () async {
      await cubit.load();
      await cubit.retryMetadata();
      expect(catalog.loads, 1);
      final failingCatalog = MatchingUiCatalog()
        ..failure = const NetworkFailure('errors.network');
      final other = ProviderMatchingCubit(
        userId: uiProviderId,
        repository: repository,
        catalogRepository: failingCatalog,
        session: session,
      );
      addTearDown(other.close);
      await other.load();
      expect(other.state.profile, isNotNull);
      expect(other.state.catalogError, 'errors.network');
      expect(other.state.canEnableDiscovery, isFalse);
      failingCatalog.failure = null;
      await other.load();
      expect(failingCatalog.loads, 1);
      await other.retryMetadata();
      expect(failingCatalog.loads, 2);
      expect(other.state.canEnableDiscovery, isTrue);
    });

    test(
      'saved old experience is removable, never inferred to be a current skill',
      () async {
        repository.profile = matchingProfile(
          years: const {'demo-plumbing': 4, 'demo-electrical': 9},
          revision: 1,
        );
        await cubit.load(discardEdits: true);
        expect(cubit.state.oldExperienceIds, ['demo-electrical']);
        cubit.updateExperience('demo-electrical', '20');
        expect(cubit.state.draft.experienceYears['demo-electrical'], '9');
        cubit.removeExperience('demo-electrical');
        await cubit.save();
        expect(repository.profile.experienceYears, {'demo-plumbing': 4});
      },
    );

    test('invalid in-progress years do not throw or reach a save', () async {
      for (final input in ['-1', '61', '1e3', '1.5', 'text']) {
        cubit.updateExperience('demo-plumbing', input);
        expect(cubit.state.hasUnsavedChanges, isTrue);
        await cubit.save();
        expect(cubit.state.errorMessage, 'matching.errors.experience');
      }
      expect(repository.drafts, isEmpty);
    });

    test(
      'save freezes the immutable original draft and rejects competing edits',
      () async {
        cubit.updateLatitude('30.04');
        cubit.updateLongitude('31.20');
        final original = cubit.state.draft;
        repository.pendingSave = Completer();
        final saving = cubit.save();
        cubit.updateLatitude('40.00');
        cubit.setDiscoverable(true);
        await cubit.save();
        await cubit.load();
        expect(repository.drafts, [original]);
        expect(cubit.state.draft, same(original));
        expect(cubit.state.canEdit, isFalse);
        repository.pendingSave!.complete(right(repository.saved(original)));
        await saving;
        expect(cubit.state.profile!.latitude, 30.04);
        expect(cubit.state.draft.expectedRevision, 1);
      },
    );

    test('response loss retries the exact retained action through subsequent network errors', () async {
      cubit.updateExperience('demo-plumbing', '4');
      final original = cubit.state.draft;
      repository.saveFailure = const ServerFailure('matching.errors.uncertain');
      await cubit.save();
      cubit.updateExperience('demo-plumbing', '10');
      await cubit.save();
      expect(repository.drafts, [original]);
      expect(cubit.state.canEdit, isFalse);
      repository.retryFailure = const NetworkFailure('errors.network');
      await cubit.retryPending();
      expect(cubit.state.uncertain, isTrue);
      repository.retryFailure = null;
      await cubit.retryPending();
      expect(
        repository.retries.every((draft) => identical(draft, original)),
        isTrue,
      );
      expect(cubit.state.uncertain, isFalse);
      expect(cubit.state.profile!.experienceYears, {'demo-plumbing': 4});
    });

    test(
      'reopened page uses repository-held intent, not the newly loaded fields',
      () async {
        final original = ProviderMatchingDraft(
          providerId: uiProviderId,
          latitude: '30.04',
          longitude: '31.20',
        );
        repository.storedPending = true;
        repository.retainedDraft = original;
        await cubit.load();
        expect(cubit.state.uncertain, isTrue);
        expect(cubit.state.draft.latitude, isEmpty);
        expect(cubit.state.canEdit, isFalse);
        await cubit.retryPending();
        expect(repository.retries.single, same(original));
        expect(cubit.state.profile!.latitude, 30.04);
        expect(cubit.state.uncertain, isFalse);
      },
    );

    test(
      'definitive conflict never claims success and requires canonical reload',
      () async {
        cubit.updateExperience('demo-plumbing', '4');
        repository.saveFailure = const ServerFailure(
          'matching.errors.uncertain',
        );
        await cubit.save();
        repository.retryFailure = const ServerFailure(
          'matching.errors.conflict',
        );
        await cubit.retryPending();
        expect(cubit.state.uncertain, isFalse);
        expect(cubit.state.reloadRequired, isTrue);
        expect(cubit.state.notice, isNull);
        expect(cubit.state.profile!.revision, 0);
        expect(cubit.state.canSave, isFalse);
        repository.profile = matchingProfile(
          years: const {'demo-plumbing': 8},
          revision: 2,
        );
        await cubit.load(discardEdits: true);
        expect(cubit.state.draft.expectedRevision, 2);
        expect(cubit.state.reloadRequired, isFalse);
        expect(cubit.state.draft.consent, isFalse);
      },
    );

    test('server remains authoritative when current eligibility changes before save', () async {
      cubit.setDiscoverable(true);
      cubit.setConsent(true);
      repository.saveFailure = const ServerFailure(
        'matching.errors.ineligible',
      );
      await cubit.save();
      expect(cubit.state.profile!.discoverable, isFalse);
      expect(cubit.state.notice, isNull);
      expect(cubit.state.errorMessage, 'matching.errors.ineligible');
    });

    test('read error retains private edits; SQL access failure wipes settings and metadata', () async {
      cubit.updateLatitude('30.04');
      repository.profileFailure = const NetworkFailure('errors.network');
      await cubit.load();
      expect(cubit.state.profile, isNotNull);
      expect(cubit.state.draft.latitude, '30.04');
      repository.profileFailure = const ServerFailure('matching.errors.access');
      await cubit.load();
      expect(cubit.state.profile, isNull);
      expect(cubit.state.metadata, isNull);
      expect(cubit.state.categories, isEmpty);
      expect(cubit.state.draft.latitude, isEmpty);
      expect(cubit.state.revoked, isTrue);
    });

    test('same-account replacement ignores a late settings save and cannot revive origin', () async {
      cubit.updateLatitude('30.04');
      cubit.updateLongitude('31.20');
      final original = cubit.state.draft;
      repository.pendingSave = Completer();
      final saving = cubit.save();
      await _replaceSameAccount(auth, session, provider: true);
      repository.pendingSave!.complete(right(repository.saved(original)));
      await saving;
      expect(cubit.state.revoked, isTrue);
      expect(cubit.state.profile, isNull);
      expect(cubit.state.draft.latitude, isEmpty);
      expect(cubit.state.notice, isNull);
    });
  });
}
