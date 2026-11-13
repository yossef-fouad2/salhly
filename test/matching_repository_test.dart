import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/marketplace.dart';
import 'package:salahly/src/data/models/matching.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/service_category.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/models/verification_document.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/demo_marketplace_store.dart';
import 'package:salahly/src/data/repositories/marketplace_repository.dart';
import 'package:salahly/src/data/repositories/matching_repository.dart';
import 'package:salahly/src/data/repositories/provider_repository.dart';
import 'package:salahly/src/data/repositories/service_request_repository.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'marketplace_fixtures.dart' as market;
import 'matching_fixtures.dart' as fixture;

const _sampleId = DemoMarketplaceStore.sampleProviderId;
const _newId = 'demo-matching-new';
const _experiencedId = 'demo-matching-experienced';
const _sample = AppUser(
  id: _sampleId,
  email: DemoAuthRepository.marketplaceProviderEmail,
  name: 'Sample Marketplace Provider',
  role: UserRole.provider,
);

void main() {
  group('MatchingRepository demo', () {
    late fixture.SessionAuth auth;
    late DemoMarketplaceStore store;
    late ProviderRepository providers;
    late _MutableCatalog catalog;
    late ServiceRequestRepository requests;
    late MarketplaceRepository marketplace;
    late MatchingRepository repository;

    setUp(() {
      auth = fixture.SessionAuth(demo: true);
      store = DemoMarketplaceStore();
      providers = ProviderRepository(authRepository: auth);
      catalog = _MutableCatalog();
      requests = ServiceRequestRepository(
        authRepository: auth,
        demoStore: store,
        now: () => fixture.instant,
      );
      marketplace = MarketplaceRepository(
        authRepository: auth,
        demoStore: store,
        now: () => fixture.instant,
      );
      repository = MatchingRepository(
        authRepository: auth,
        demoStore: store,
        providerRepository: providers,
        catalogRepository: catalog,
        now: () => fixture.instant,
      );
    });
    tearDown(() => auth.dispose());

    Future<void> publish({
      String id = fixture.requestId,
      String city = 'Cairo',
    }) async {
      auth.change(const AuthSession(user: fixture.customer));
      await fixture.success(
        requests.submitRequest(
          _requestDraft(id: id),
          userId: fixture.customerId,
        ),
      );
      await fixture.success(
        marketplace.publishListing(
          id,
          userId: fixture.customerId,
          summary: market.summary,
          city: city,
          consent: true,
        ),
      );
    }

    test('default samples are three honest discoveries but only one M7 quote account', () async {
      expect(store.providers.keys, [_sampleId]);
      expect(store.matchingProviders.keys.toSet(), {_newId, _experiencedId});
      expect(store.matchingProfiles.keys.toSet(), {
        _sampleId,
        _newId,
        _experiencedId,
      });
      expect(store.matchingProfiles[_sampleId]!.experienceYears, {
        'demo-plumbing': 4,
      });
      expect(store.matchingProfiles[_experiencedId]!.experienceYears, {
        'demo-plumbing': 10,
      });
      expect(store.matchingProfiles[_newId]!.experienceYears, isEmpty);
      expect(store.matchingProfiles[_newId]!.latitude, isNull);
      expect(store.matchingAvailability[_newId], isEmpty);
      expect(store.providers.containsKey('demo-provider'), isFalse);
      expect(store.matchingProfiles.containsKey('demo-provider'), isFalse);
      expect(store.quotes, isEmpty);
      expect(store.jobs, isEmpty);
      for (final provider in [
        ...store.providers.values,
        ...store.matchingProviders.values,
      ]) {
        expect(provider.role, UserRole.provider);
        expect(provider.skillIds, ['demo-plumbing']);
        expect(provider.serviceAreas, ['Cairo']);
      }
      final demoAuth = DemoAuthRepository();
      addTearDown(demoAuth.dispose);
      for (final email in [
        '$_newId@salahly.demo',
        '$_experiencedId@salahly.demo',
      ]) {
        await fixture.failure(
          demoAuth.login(
            email: email,
            password: DemoAuthRepository.demoPassword,
          ),
          'auth.invalid_credentials',
        );
      }
      await publish();
      for (final id in [_newId, _experiencedId]) {
        auth.change(
          AuthSession(
            user: AppUser(
              id: id,
              email: '$id@example.test',
              name: 'Discovery Fixture',
              role: UserRole.provider,
            ),
          ),
        );
        expect(
          (await fixture.success(marketplace.loadFeed(userId: id))).eligible,
          isFalse,
        );
        await fixture.failure(
          marketplace.saveQuote(market.draft(), userId: id),
          'marketplace.errors.not_found',
        );
      }
      expect(store.quotes, isEmpty);
      expect(store.jobs, isEmpty);
    });

    test('real demo customer publishes separately from private city and sample opts out/re-enables', () async {
      final demoAuth = DemoAuthRepository();
      addTearDown(demoAuth.dispose);
      final m5 = ProviderRepository(authRepository: demoAuth);
      final m6 = ServiceRequestRepository(
        authRepository: demoAuth,
        demoStore: store,
        now: () => fixture.instant,
      );
      final m7 = MarketplaceRepository(
        authRepository: demoAuth,
        demoStore: store,
        now: () => fixture.instant,
      );
      final matching = MatchingRepository(
        authRepository: demoAuth,
        demoStore: store,
        providerRepository: m5,
        now: () => fixture.instant,
      );
      Future<AppUser> login(String email) => fixture.success(
        demoAuth.login(email: email, password: DemoAuthRepository.demoPassword),
      );
      final customer = await login(DemoAuthRepository.customerEmail);
      final request = await fixture.success(
        m6.submitRequest(_requestDraft(), userId: customer.id),
      );
      await fixture.failure(
        matching.loadMatches(fixture.emptyQuery, userId: customer.id),
        'matching.errors.unpublished',
      );
      await fixture.failure(
        m7.publishListing(
          request.id,
          userId: customer.id,
          summary: market.summary,
          city: 'Cairo',
          consent: false,
        ),
        'marketplace.errors.consent',
      );
      await fixture.success(
        m7.publishListing(
          request.id,
          userId: customer.id,
          summary: market.summary,
          city: 'Cairo',
          consent: true,
        ),
      );
      final defaults = await fixture.success(
        matching.loadMatches(fixture.emptyQuery, userId: customer.id),
      );
      expect(request.city, 'Private district');
      expect(defaults.listing.city, 'Cairo');
      expect(defaults.listing.summary, isNot(request.title));
      expect(defaults.items, hasLength(3));
      for (final match in defaults.items) {
        expect(match.distanceKm, isNull);
        expect(match.available, isNull);
        expect(match.averageRating, isNull);
        expect(match.reviewCount, 0);
        expect(match.factors.first.reason, 'no_query_location');
        expect(match.factors[2].reason, 'no_time_preference');
        expect(match.props, isNot(contains(request.address)));
        expect(match.props, isNot(contains(customer.id)));
      }
      final sample = await login(DemoAuthRepository.marketplaceProviderEmail);
      final eligibility = await fixture.success(
        matching.loadEligibility(userId: sample.id),
      );
      expect(eligibility.eligible, isTrue);
      expect(eligibility.skillIds, ['demo-plumbing']);
      expect(
        (await fixture.success(m5.loadProfile(sample.id))).verification,
        isNull,
      );
      final profile = await fixture.success(
        matching.loadProfile(userId: sample.id),
      );
      await fixture.failure(
        matching.saveProfile(
          ProviderMatchingDraft.fromProfile(profile),
          userId: sample.id,
        ),
        'matching.errors.consent',
      );
      final optOutDraft = ProviderMatchingDraft.fromProfile(profile)
          .copyWith(discoverable: false);
      final optOut = await fixture.success(
        matching.saveProfile(optOutDraft, userId: sample.id),
      );
      expect(optOut.discoverable, isFalse);
      expect(optOut.revision, profile.revision + 1);
      expect(optOut.latitude, profile.latitude);
      expect(optOut.experienceYears, profile.experienceYears);
      expect(optOut.consentedAt, profile.consentedAt);
      expect(
        await fixture.success(
          matching.saveProfile(optOutDraft, userId: sample.id),
        ),
        optOut,
      );
      await login(DemoAuthRepository.customerEmail);
      expect(
        (await fixture.success(
          matching.loadMatches(fixture.emptyQuery, userId: customer.id),
        )).items.map((item) => item.providerId),
        isNot(contains(sample.id)),
      );
      await login(DemoAuthRepository.marketplaceProviderEmail);
      await fixture.success(
        demoAuth.updateProfile(name: 'Renamed Sample Provider'),
      );
      final reenableDraft = ProviderMatchingDraft.fromProfile(optOut)
          .copyWith(discoverable: true, consent: true);
      final reenabled = await fixture.success(
        matching.saveProfile(reenableDraft, userId: sample.id),
      );
      expect(reenabled.providerName, 'Renamed Sample Provider');
      expect(reenabled.consentedAt!.isAfter(profile.consentedAt!), isTrue);
      expect(reenabled.updatedAt!.isAfter(optOut.updatedAt!), isTrue);
      await fixture.success(
        demoAuth.updateProfile(name: 'Another Private Name'),
      );
      expect(
        await fixture.success(
          matching.saveProfile(reenableDraft, userId: sample.id),
        ),
        reenabled,
      );
      await fixture.success(m7.saveQuote(market.draft(), userId: sample.id));
      await login(DemoAuthRepository.customerEmail);
      final matches = await fixture.success(
        matching.loadMatches(fixture.emptyQuery, userId: customer.id),
      );
      expect(
        matches.items
            .singleWhere((item) => item.providerId == sample.id)
            .providerName,
        'Renamed Sample Provider',
      );
      expect(store.jobs, isEmpty);
      await fixture.failure(
        m5.loadProfile(customer.id),
        'provider.errors.access',
      );
    });

    test('withdrawal and its exact retry do not depend on unavailable catalog metadata', () async {
      auth.change(const AuthSession(user: _sample));
      final profile = await fixture.success(
        repository.loadProfile(userId: _sampleId),
      );
      store.providers[_sampleId] = _eligibleProvider(
        verified: false,
        skills: const [],
      );
      catalog.error = const NetworkFailure('errors.network');
      final draft = ProviderMatchingDraft.fromProfile(profile)
          .copyWith(discoverable: false);
      final withdrawn = await fixture.success(
        repository.saveProfile(draft, userId: _sampleId),
      );
      expect(withdrawn.discoverable, isFalse);
      expect(withdrawn.experienceYears, profile.experienceYears);
      expect(withdrawn.consentedAt, profile.consentedAt);
      expect(catalog.calls, 0);
      expect(
        await fixture.success(repository.saveProfile(draft, userId: _sampleId)),
        withdrawn,
      );
      expect(catalog.calls, 0);
      await fixture.failure(
        repository.saveProfile(
          ProviderMatchingDraft.fromProfile(withdrawn)
              .copyWith(discoverable: true, consent: true),
          userId: _sampleId,
        ),
        'errors.network',
      );
      expect(store.matchingProfiles[_sampleId], withdrawn);
    });

    test('near/far/new samples share full eligibility in both modes but not score order', () async {
      await publish();
      final recommended = await fixture.success(
        repository.loadMatches(
          fixture.queryWithSignals,
          userId: fixture.customerId,
        ),
      );
      expect(recommended.items.map((item) => item.providerId), [
        _sampleId,
        _experiencedId,
        _newId,
      ]);
      final near = recommended.items[0];
      final far = recommended.items[1];
      final unknown = recommended.items[2];
      expect(near.distanceKm, 0);
      expect(near.scoreBps, 7550);
      expect(near.evidenceBps, 7500);
      expect(far.distanceKm, greaterThan(0));
      expect(far.available, isFalse);
      expect(far.experienceYears, 10);
      expect(far.scoreBps, inExclusiveRange(5000, 7550));
      expect(unknown.distanceKm, isNull);
      expect(unknown.available, isNull);
      expect(unknown.experienceYears, isNull);
      expect(unknown.scoreBps, 5000);
      expect(unknown.evidenceBps, 0);
      final all = await fixture.success(
        repository.loadMatches(
          fixture.queryWithSignals.copyWith(mode: MatchMode.allEligible),
          userId: fixture.customerId,
        ),
      );
      expect(all.items.toSet(), recommended.items.toSet());
      expect(
        all.items.map((item) => item.providerId).toList(),
        isNot(recommended.items.map((item) => item.providerId).toList()),
      );
      for (final match in all.items) {
        expect(
          validProviderMatch(match, all.rules, all.listing.requestId),
          isTrue,
        );
        final wire = fixture.matchJson(match);
        for (final key in [
          'latitude',
          'longitude',
          'address',
          'phone',
          'verification',
          'document_path',
          'completed_jobs',
        ]) {
          expect(wire.containsKey(key), isFalse, reason: key);
        }
      }
    });

    test(
      'matching is owner-scoped and requires publication plus an open request',
      () async {
        await fixture.success(
          requests.submitRequest(_requestDraft(), userId: fixture.customerId),
        );
        await fixture.failure(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
          ),
          'matching.errors.unpublished',
        );
        await fixture.success(
          marketplace.publishListing(
            fixture.requestId,
            userId: fixture.customerId,
            summary: market.summary,
            city: 'Cairo',
            consent: true,
          ),
        );
        auth.change(const AuthSession(user: fixture.otherCustomer));
        await fixture.failure(
          repository.loadMatches(fixture.emptyQuery, userId: fixture.otherId),
          'matching.errors.not_found',
        );
        auth.change(const AuthSession(user: fixture.customer));
        await fixture.failure(
          repository.loadMatches(
            MatchingQuery(requestId: fixture.id(99)),
            userId: fixture.customerId,
          ),
          'matching.errors.not_found',
        );
        await fixture.success(
          requests.cancelRequest(fixture.requestId, userId: fixture.customerId),
        );
        await fixture.failure(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
          ),
          'matching.errors.status',
        );
        await publish(id: fixture.id(2));
        auth.change(const AuthSession(user: _sample));
        final quote = await fixture.success(
          marketplace.saveQuote(
            market.draft(request: fixture.id(2)),
            userId: _sampleId,
          ),
        );
        auth.change(const AuthSession(user: fixture.customer));
        await fixture.success(
          marketplace.acceptQuote(
            quote,
            userId: fixture.customerId,
            consent: true,
          ),
        );
        await fixture.failure(
          repository.loadMatches(
            MatchingQuery(requestId: fixture.id(2)),
            userId: fixture.customerId,
          ),
          'matching.errors.status',
        );
      },
    );

    test('current verification, role, skill, public service area and opt-out gate both modes', () async {
      await publish();
      final profile = store.matchingProfiles[_sampleId]!;
      store.matchingProfiles
        ..clear()
        ..[_sampleId] = profile;
      for (final provider in [
        _eligibleProvider(verified: false),
        _eligibleProvider(role: UserRole.customer),
        _eligibleProvider(skills: const []),
        _eligibleProvider(skills: const ['demo-electrical']),
        _eligibleProvider(areas: const []),
        _eligibleProvider(areas: const ['Private district']),
      ]) {
        store.providers[_sampleId] = provider;
        for (final mode in MatchMode.values) {
          expect(
            (await fixture.success(
              repository.loadMatches(
                fixture.emptyQuery.copyWith(mode: mode),
                userId: fixture.customerId,
              ),
            )).items,
            isEmpty,
          );
        }
      }
      store.providers[_sampleId] = _eligibleProvider(areas: const [' cairo ']);
      expect(
        (await fixture.success(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
          ),
        )).items,
        hasLength(1),
      );
      catalog.plumbingActive = false;
      expect(
        (await fixture.success(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
          ),
        )).items,
        isEmpty,
      );
      catalog.plumbingActive = true;
      store.matchingProfiles[_sampleId] = ProviderMatchingProfile(
        providerId: _sampleId,
        providerName: profile.providerName,
        revision: 2,
        updatedAt: fixture.instant,
      );
      expect(
        (await fixture.success(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
          ),
        )).items,
        isEmpty,
      );
    });

    test('a discoverable flag without publication consent cannot expose a provider', () async {
      await publish();
      store.matchingProfiles
        ..clear()
        ..[_sampleId] = ProviderMatchingProfile(
          providerId: _sampleId,
          providerName: 'Unconsented Provider',
          discoverable: true,
          revision: 1,
          updatedAt: fixture.instant,
        );
      expect(
        (await fixture.success(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
          ),
        )).items,
        isEmpty,
      );
    });

    test(
      'a customer cannot appear as their own eligible provider fixture',
      () async {
        await publish();
        store.matchingProfiles
          ..clear()
          ..[fixture.customerId] = ProviderMatchingProfile(
            providerId: fixture.customerId,
            providerName: 'Own Provider Fixture',
            discoverable: true,
            revision: 1,
            consentedAt: fixture.instant,
            updatedAt: fixture.instant,
          );
        store.matchingProviders[fixture.customerId] = _eligibleProvider();
        expect(
          (await fixture.success(
            repository.loadMatches(
              fixture.emptyQuery,
              userId: fixture.customerId,
            ),
          )).items,
          isEmpty,
        );
      },
    );

    test(
      'existing quote eligibility is the same for recommended and all modes',
      () async {
        await publish();
        final profile = store.matchingProfiles[_sampleId]!;
        store.matchingProfiles
          ..clear()
          ..[_sampleId] = profile;
        // Keep the request open to isolate quoteability from the closed-request guard.
        for (final (status, count) in [
          (QuoteStatus.pending, 1),
          (QuoteStatus.withdrawn, 1),
          (QuoteStatus.accepted, 0),
          (QuoteStatus.notSelected, 0),
          (QuoteStatus.cancelled, 0),
        ]) {
          final quote = ProviderQuote.fromJson(
            market.quote(provider: _sampleId, status: status),
          );
          store.quotes[quote.id] = quote;
          for (final mode in MatchMode.values) {
            final result = await fixture.success(
              repository.loadMatches(
                fixture.emptyQuery.copyWith(mode: mode),
                userId: fixture.customerId,
              ),
            );
            expect(
              result.items.length,
              count,
              reason: '${status.name}/${mode.name}',
            );
          }
        }
        expect(store.jobs, isEmpty);
      },
    );

    test('ordinary pending provider can save private preferences but cannot self-publish', () async {
      final demoAuth = DemoAuthRepository();
      addTearDown(demoAuth.dispose);
      final ordinary = await fixture.success(
        demoAuth.login(
          email: DemoAuthRepository.providerEmail,
          password: DemoAuthRepository.demoPassword,
        ),
      );
      final m5 = ProviderRepository(authRepository: demoAuth);
      final matching = MatchingRepository(
        authRepository: demoAuth,
        demoStore: store,
        providerRepository: m5,
        now: () => fixture.instant,
      );
      final empty = await fixture.success(
        matching.loadProfile(userId: ordinary.id),
      );
      expect(empty.revision, 0);
      expect(empty.discoverable, isFalse);
      await fixture.success(
        m5.saveProfile(
          ProviderProfile(
            userId: ordinary.id,
            bio: 'A pending ordinary provider with plumbing skills.',
            skillIds: const ['demo-plumbing'],
            serviceAreas: const ['Cairo'],
            availability: fixture.hours,
          ),
        ),
      );
      final pending = await fixture.success(
        m5.submitVerification(
          userId: ordinary.id,
          document: VerificationDocument.fromBytes(
            Uint8List.fromList([0xff, 0xd8, 0xff]),
          ),
          consent: true,
        ),
      );
      expect(pending.verification!.status, ProviderVerificationStatus.pending);
      final eligibility = await fixture.success(
        matching.loadEligibility(userId: ordinary.id),
      );
      expect(eligibility.skillIds, ['demo-plumbing']);
      expect(eligibility.eligible, isFalse);
      final privateDraft = fixture.draft(
        provider: ordinary.id,
        discoverable: false,
        experience: const {'demo-plumbing': '0'},
      );
      final saved = await fixture.success(
        matching.saveProfile(privateDraft, userId: ordinary.id),
      );
      expect(saved.discoverable, isFalse);
      expect(saved.experienceYears, {'demo-plumbing': 0});
      expect(saved.consentedAt, isNull);
      await fixture.failure(
        matching.saveProfile(
          ProviderMatchingDraft.fromProfile(saved)
              .copyWith(discoverable: true, consent: true),
          userId: ordinary.id,
        ),
        'matching.errors.ineligible',
      );
      expect(store.providers.containsKey(ordinary.id), isFalse);
      expect(
        (await fixture.success(m5.loadProfile(ordinary.id))).verification,
        pending.verification,
      );
      expect(store.quotes, isEmpty);
      expect(store.jobs, isEmpty);
    });

    test('experience validates current M5 skills and old inactive entries remain removable', () async {
      auth.change(const AuthSession(user: fixture.provider));
      await fixture.success(
        providers.saveProfile(
          ProviderProfile(
            userId: fixture.providerId,
            skillIds: const ['demo-plumbing'],
          ),
        ),
      );
      final draft = fixture.draft(
        discoverable: false,
        experience: const {'demo-plumbing': '2'},
      );
      await fixture.failure(
        repository.saveProfile(
          draft.copyWith(experienceYears: const {'demo-electrical': '3'}),
          userId: fixture.providerId,
        ),
        'matching.errors.experience',
      );
      final saved = await fixture.success(
        repository.saveProfile(draft, userId: fixture.providerId),
      );
      await fixture.success(
        providers.saveProfile(ProviderProfile.empty(fixture.providerId)),
      );
      catalog.plumbingActive = false;
      final metadata = await fixture.success(
        repository.loadEligibility(userId: fixture.providerId),
      );
      expect(metadata.skillIds, isEmpty);
      expect(metadata.eligible, isFalse);
      expect(
        (await fixture.success(
          repository.loadProfile(userId: fixture.providerId),
        )).experienceYears,
        {'demo-plumbing': 2},
      );
      final original = ProviderMatchingDraft.fromProfile(saved);
      final retained = await fixture.success(
        repository.saveProfile(original, userId: fixture.providerId),
      );
      expect(retained.experienceYears, saved.experienceYears);
      await fixture.failure(
        repository.saveProfile(
          ProviderMatchingDraft.fromProfile(retained)
              .copyWith(experienceYears: const {'demo-plumbing': '3'}),
          userId: fixture.providerId,
        ),
        'matching.errors.experience',
      );
      final removed = await fixture.success(
        repository.saveProfile(
          ProviderMatchingDraft.fromProfile(retained)
              .copyWith(experienceYears: const {}),
          userId: fixture.providerId,
        ),
      );
      expect(removed.experienceYears, isEmpty);
      expect(saved.experienceYears, {'demo-plumbing': 2});
    });

    test(
      'pure opt-out and exact retries survive later skill/verification loss',
      () async {
        auth.change(const AuthSession(user: _sample));
        final original = await fixture.success(
          repository.loadProfile(userId: _sampleId),
        );
        store.providers[_sampleId] = _eligibleProvider(
          verified: false,
          skills: const [],
        );
        catalog.plumbingActive = false;
        final draft = ProviderMatchingDraft.fromProfile(original)
            .copyWith(discoverable: false);
        final disabled = await fixture.success(
          repository.saveProfile(draft, userId: _sampleId),
        );
        expect(disabled.latitude, original.latitude);
        expect(disabled.experienceYears, original.experienceYears);
        expect(disabled.consentedAt, original.consentedAt);
        final calls = catalog.calls;
        catalog.error = const NetworkFailure('errors.network');
        expect(
          await fixture.success(
            repository.saveProfile(draft, userId: _sampleId),
          ),
          disabled,
        );
        expect(catalog.calls, calls);
        expect(disabled.updatedAt!.isAfter(original.updatedAt!), isTrue);
      },
    );

    test(
      'demo metadata exposes only current active skills and immutable lists',
      () async {
        auth.change(const AuthSession(user: _sample));
        final eligibility = await fixture.success(
          repository.loadEligibility(userId: _sampleId),
        );
        expect(eligibility.eligible, isTrue);
        expect(eligibility.skillIds, ['demo-plumbing']);
        expect(() => eligibility.skillIds.clear(), throwsUnsupportedError);
        catalog.plumbingActive = false;
        final inactive = await fixture.success(
          repository.loadEligibility(userId: _sampleId),
        );
        expect(inactive.eligible, isFalse);
        expect(inactive.skillIds, isEmpty);
        final skills = ['demo-plumbing'];
        final areas = ['Cairo'];
        final fixtureProvider = DemoMarketplaceProvider(
          skillIds: skills,
          serviceAreas: areas,
        );
        skills.clear();
        areas.clear();
        expect(fixtureProvider.skillIds, ['demo-plumbing']);
        expect(fixtureProvider.serviceAreas, ['Cairo']);
        expect(() => fixtureProvider.skillIds.clear(), throwsUnsupportedError);
        expect(
          () => fixtureProvider.serviceAreas.clear(),
          throwsUnsupportedError,
        );
      },
    );

    test('equal-score bounded keysets never duplicate ties and changed rules invalidate cursors', () async {
      await publish();
      store.matchingProfiles.clear();
      store.matchingProviders.clear();
      final ids = List.generate(12, (index) => fixture.id(100 + index));
      for (final id in ids.reversed) {
        store.matchingProfiles[id] = ProviderMatchingProfile(
          providerId: id,
          providerName: 'Unknown Provider',
          discoverable: true,
          revision: 1,
          consentedAt: fixture.instant,
          updatedAt: fixture.instant,
        );
        store.matchingProviders[id] = _eligibleProvider();
      }
      final expected = ids.toList()
        ..sort(
          (a, b) => matchingTieKey(
            fixture.requestId,
            a,
          ).compareTo(matchingTieKey(fixture.requestId, b)),
        );
      for (final mode in MatchMode.values) {
        final query = fixture.emptyQuery.copyWith(mode: mode);
        final full = await fixture.success(
          repository.loadMatches(query, userId: fixture.customerId, limit: 50),
        );
        expect(full.items.map((item) => item.scoreBps).toSet(), {5000});
        expect(full.items.map((item) => item.providerId), expected);
        final paged = await _allPages(repository, query, fixture.customerId);
        expect(paged, full.items);
      }
      final first = await fixture.success(
        repository.loadMatches(
          fixture.emptyQuery,
          userId: fixture.customerId,
          limit: 2,
        ),
      );
      final cursor = first.items.last.cursor(
        first.rules,
        first.mode,
        query: fixture.emptyQuery,
      );
      for (final changed in [
        fixture.emptyQuery.copyWith(
          latitude: '30.04',
          longitude: '31.24',
          locationConsent: true,
        ),
        fixture.emptyQuery.copyWith(weekday: 1, time: '09:00'),
        fixture.emptyQuery.copyWith(mode: MatchMode.allEligible),
      ]) {
        expect(
          (await fixture.success(
            repository.loadMatches(changed, userId: fixture.customerId),
          )).items.map((item) => item.scoreBps).toSet(),
          {5000},
        );
        await fixture.failure(
          repository.loadMatches(
            changed,
            userId: fixture.customerId,
            before: cursor,
          ),
          'matching.errors.stale',
        );
      }
      store.matchingRules = const MatchingRules(
        revision: 2,
        distanceWeight: 1,
        ratingWeight: 2,
        availabilityWeight: 4,
        experienceWeight: 6,
      );
      await fixture.failure(
        repository.loadMatches(
          fixture.emptyQuery,
          userId: fixture.customerId,
          before: cursor,
          limit: 2,
        ),
        'matching.errors.stale',
      );
      final refreshed = await fixture.success(
        repository.loadMatches(fixture.emptyQuery, userId: fixture.customerId),
      );
      expect(refreshed.rules.revision, 2);
      expect(refreshed.items.map((item) => item.scoreBps).toSet(), {5000});
      for (final limit in [0, 51]) {
        await fixture.failure(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
            limit: limit,
          ),
          'matching.errors.invalid',
        );
      }
    });

    test(
      'demo state is session-local and missing or recovery actors fail closed',
      () async {
        await publish();
        final fresh = MatchingRepository(authRepository: auth);
        await fixture.failure(
          fresh.loadMatches(fixture.emptyQuery, userId: fixture.customerId),
          'matching.errors.not_found',
        );
        for (final session in const [
          AuthSession(),
          AuthSession(user: fixture.customer, needsPasswordUpdate: true),
        ]) {
          auth.change(session);
          await _allDenied(repository);
        }
        expect(auth.hasListeners, isFalse);
        auth.change(const AuthSession(user: _sample));
        final loaded = await fixture.success(
          repository.retryPendingSave(userId: _sampleId),
        );
        expect(loaded, store.matchingProfiles[_sampleId]);
        expect(repository.hasPendingSave(userId: _sampleId), isFalse);
      },
    );
  });

  group('MatchingRepository live loopback SDK', () {
    late fixture.LoopbackBackend backend;
    late fixture.SessionAuth auth;
    late MatchingRepository repository;

    setUp(() async {
      backend = await fixture.LoopbackBackend.start();
      auth = fixture.SessionAuth(demo: false);
      repository = MatchingRepository(
        authRepository: auth,
        client: backend.client,
      );
    });
    tearDown(() async {
      expect(backend.unexpected, isEmpty);
      for (final call in backend.rpcs) {
        expect(call.method, 'POST');
        expect(call.uri.query, isEmpty);
        expect(
          call.uri.path,
          isIn([
            '/rest/v1/rpc/get_provider_matches',
            '/rest/v1/rpc/get_provider_matching_profile',
            '/rest/v1/rpc/save_provider_matching_profile',
          ]),
        );
      }
      expect(
        backend.calls.where(
          (call) =>
              !call.uri.path.startsWith('/auth/') &&
              !call.uri.path.startsWith('/rest/v1/rpc/'),
        ),
        isEmpty,
      );
      await backend.close();
      await auth.dispose();
    });

    Future<void> actAs(AppUser user) async {
      auth.change(AuthSession(user: user));
      await backend.setSession(userId: user.id);
    }

    test('RPC authorization is bound to the checked SDK session rather than a shared header', () async {
      await actAs(fixture.provider);
      backend.client.rest.headers['Authorization'] = 'Bearer another-account-token';
      await fixture.success(repository.saveProfile(fixture.draft(), userId: fixture.providerId));
      expect(
        backend.rpc('save_provider_matching_profile').single.authorization,
        'Bearer test-token-${fixture.providerId}',
      );
      expect(backend.client.rest.headers['Authorization'], 'Bearer another-account-token');
    });

    for (final mode in MatchMode.values) {
      test(
        '${mode.name} query uses exact RPC normalized coordinates, wall time and bounded keyset',
        () async {
          final query = fixture.queryWithSignals.copyWith(
            mode: mode,
            latitude: ' \u0663\u0660\u066b\u0660\u0664 ',
            longitude: '\u06f3\u06f1.\u06f2\u06f4',
            time: ' \u0660\u0669:\u0660\u0660 ',
          );
          final candidates = [
            fixture.score(query: query),
            fixture.score(
              query: query,
              profile: ProviderMatchingProfile(
                providerId: fixture.otherId,
                providerName: 'Unknown Provider',
              ),
              availability: const [],
            ),
          ]..sort((a, b) => compareProviderMatches(a, b, mode));
          final before = candidates.first.cursor(
            const MatchingRules(),
            mode,
            query: query,
          );
          backend.matchesResponse = fixture.resultsJson(
            query: query,
            items: [candidates.last],
          );
          await fixture.success(
            repository.loadMatches(
              query,
              userId: fixture.customerId,
              before: before,
              limit: 2,
            ),
          );
          final call = backend.rpcs.single;
          expect(call.uri.path, '/rest/v1/rpc/get_provider_matches');
          expect(call.authorization, 'Bearer test-token-${fixture.customerId}');
          expect(call.json, {
            'p_request_id': fixture.requestId,
            'p_mode': mode.wireName,
            'p_latitude': 30.04,
            'p_longitude': 31.24,
            'p_location_consent': true,
            'p_weekday': 1,
            'p_minute': 540,
            'p_before_score_bps': before.scoreBps,
            'p_before_tie_key': before.tieKey,
            'p_before_provider_id': before.providerId,
            'p_before_query_key': before.queryKey,
            'p_rules_revision': 1,
            'p_limit': 2,
          });
          final empty = fixture.emptyQuery.copyWith(
            mode: mode,
            locationConsent: true,
          );
          backend.matchesResponse = fixture.resultsJson(query: empty);
          await fixture.success(
            repository.loadMatches(empty, userId: fixture.customerId),
          );
          expect(backend.rpcs.last.json, {
            'p_request_id': fixture.requestId,
            'p_mode': mode.wireName,
            'p_latitude': null,
            'p_longitude': null,
            'p_location_consent': false,
            'p_weekday': null,
            'p_minute': null,
            'p_before_score_bps': null,
            'p_before_tie_key': null,
            'p_before_provider_id': null,
            'p_before_query_key': null,
            'p_rules_revision': null,
            'p_limit': 20,
          });
          await fixture.success(
            repository.loadMatches(
              empty,
              userId: fixture.customerId,
              limit: 50,
            ),
          );
          expect(backend.rpcs.last.json['p_limit'], 50);
          expect(auth.checkCalls, 3);
          expect(auth.hasListeners, isFalse);
        },
      );
    }

    test('owned load and save use only exact matching RPC parameters and normalized private values', () async {
      await actAs(fixture.provider);
      final loaded = await fixture.success(
        repository.loadProfile(userId: fixture.providerId),
      );
      expect(loaded, ProviderMatchingProfile.fromJson(fixture.profileJson()));
      expect(backend.rpc('get_provider_matching_profile').single.json, isEmpty);
      final draft = fixture
          .draft(
            experience: {fixture.categoryId: ' \u06f4 ', fixture.id(3): ' '},
          )
          .copyWith(
            latitude: ' \u0663\u0660\u066b\u0660\u0664 ',
            longitude: ' 31.24 ',
          );
      final saved = await fixture.success(
        repository.saveProfile(draft, userId: fixture.providerId),
      );
      expect(saved.revision, 1);
      expect(
        backend.rpc('save_provider_matching_profile').single.json,
        _saveParams,
      );
      expect(
        backend.rpc('save_provider_matching_profile').single.authorization,
        'Bearer test-token-${fixture.providerId}',
      );
      expect(repository.hasPendingSave(userId: fixture.providerId), isFalse);
      expect(auth.hasListeners, isFalse);
    });

    test('invalid request, coordinate, time, cursor and mutation inputs are rejected before HTTP', () async {
      for (final (query, key) in [
        (const MatchingQuery(requestId: 'bad'), 'matching.errors.not_found'),
        (
          fixture.queryWithSignals.copyWith(latitude: '30.041'),
          'matching.errors.location',
        ),
        (
          fixture.queryWithSignals.copyWith(longitude: ''),
          'matching.errors.location',
        ),
        (
          fixture.queryWithSignals.copyWith(locationConsent: false),
          'matching.errors.consent',
        ),
        (fixture.emptyQuery.copyWith(weekday: 1), 'matching.errors.time'),
        (
          fixture.emptyQuery.copyWith(weekday: 1, time: '24:00'),
          'matching.errors.time',
        ),
      ]) {
        await fixture.failure(
          repository.loadMatches(query, userId: fixture.customerId),
          key,
        );
      }
      for (final limit in [-1, 0, 51]) {
        await fixture.failure(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
            limit: limit,
          ),
          'matching.errors.invalid',
        );
      }
      final cursor = fixture
          .score(query: fixture.emptyQuery)
          .cursor(
            const MatchingRules(),
            MatchMode.recommended,
            query: fixture.emptyQuery,
          );
      for (final (score, tie, provider, revision, queryKey) in [
        (-1, cursor.tieKey, cursor.providerId, 1, cursor.queryKey),
        (10001, cursor.tieKey, cursor.providerId, 1, cursor.queryKey),
        (cursor.scoreBps, 'A' * 32, cursor.providerId, 1, cursor.queryKey),
        (cursor.scoreBps, '0' * 32, cursor.providerId, 1, cursor.queryKey),
        (
          cursor.scoreBps,
          matchingTieKey(fixture.requestId, 'demo-provider'),
          'demo-provider',
          1,
          cursor.queryKey,
        ),
        (
          cursor.scoreBps,
          matchingTieKey(
            fixture.requestId,
            'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
          ),
          'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
          1,
          cursor.queryKey,
        ),
        (cursor.scoreBps, cursor.tieKey, cursor.providerId, 0, cursor.queryKey),
        (cursor.scoreBps, cursor.tieKey, cursor.providerId, 1, 'bad'),
      ]) {
        await fixture.failure(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
            before: MatchingCursor(
              scoreBps: score,
              tieKey: tie,
              providerId: provider,
              rulesRevision: revision,
              mode: MatchMode.recommended,
              queryKey: queryKey,
            ),
          ),
          'matching.errors.invalid',
        );
      }
      await actAs(fixture.provider);
      await fixture.failure(
        repository.saveProfile(
          fixture.draft(provider: fixture.otherId),
          userId: fixture.providerId,
        ),
        'matching.errors.access',
      );
      for (final (draft, key) in [
        (
          fixture.draft(revision: fixture.maxRevision),
          'matching.errors.invalid',
        ),
        (fixture.draft().copyWith(consent: false), 'matching.errors.consent'),
        (fixture.draft().copyWith(latitude: 'NaN'), 'matching.errors.location'),
        (
          fixture.draft(experience: const {fixture.categoryId: '61'}),
          'matching.errors.experience',
        ),
      ]) {
        await fixture.failure(
          repository.saveProfile(draft, userId: fixture.providerId),
          key,
        );
      }
      expect(backend.calls, isEmpty);
    });

    test('response request, provider identity, mode, rules and private profile identity are checked', () async {
      for (final wire in <Object?>[
        null,
        <Object?>[],
        {'private': fixture.privateError},
        fixture.resultsJson(query: MatchingQuery(requestId: fixture.id(99))),
        fixture.resultsJson(
          query: fixture.emptyQuery.copyWith(mode: MatchMode.allEligible),
        ),
        {
          ...fixture.resultsJson(),
          'rules': {...fixture.rulesJson(), 'neutral_bps': 4999},
        },
        fixture.resultsJson(
          items: [
            fixture.score(
              query: fixture.emptyQuery,
              profile: ProviderMatchingProfile(
                providerId: 'demo-provider',
                providerName: 'Wrong Live Identity',
              ),
            ),
          ],
        ),
      ]) {
        backend.intercept = (_) => fixture.Reply.json(wire);
        await fixture.failure(
          repository.loadMatches(
            fixture.emptyQuery,
            userId: fixture.customerId,
          ),
          'matching.errors.invalid',
        );
      }
      await actAs(fixture.provider);
      backend.intercept = (_) =>
          fixture.Reply.json(fixture.profileJson(provider: fixture.otherId));
      await fixture.failure(
        repository.loadProfile(userId: fixture.providerId),
        'matching.errors.access',
      );
      backend.intercept = (_) =>
          fixture.Reply.json({...fixture.profileJson(), 'latitude': 30.041});
      await fixture.failure(
        repository.loadProfile(userId: fixture.providerId),
        'matching.errors.invalid',
      );
    });

    test('public responses cannot invent distance or availability without caller inputs', () async {
      for (final query in [
        fixture.queryWithSignals.copyWith(weekday: null, time: ''),
        fixture.queryWithSignals.copyWith(latitude: '', longitude: ''),
      ]) {
        backend.intercept = (_) => fixture.Reply.json(
          fixture.resultsJson(items: [fixture.score()], query: query),
        );
        await fixture.failure(
          repository.loadMatches(query, userId: fixture.customerId),
          'matching.errors.invalid',
        );
      }
    });

    test('a live matching response cannot include the requesting customer as a provider', () async {
      final self = fixture.score(
        query: fixture.emptyQuery,
        profile: ProviderMatchingProfile(
          providerId: fixture.customerId,
          providerName: 'Customer Provider',
        ),
      );
      backend.intercept = (_) =>
          fixture.Reply.json(fixture.resultsJson(items: [self]));
      await fixture.failure(
        repository.loadMatches(fixture.emptyQuery, userId: fixture.customerId),
        'matching.errors.invalid',
      );
    });

    test(
      'missing-factor reasons must agree with the actual caller query context',
      () async {
        for (final (query, factorIndex, wrongReason) in [
          (fixture.emptyQuery, 0, 'no_provider_origin'),
          (fixture.queryWithSignals, 0, 'no_query_location'),
          (fixture.emptyQuery, 2, 'no_declared_hours'),
          (fixture.queryWithSignals, 2, 'no_time_preference'),
        ]) {
          final match = fixture.score(
            query: query,
            profile: ProviderMatchingProfile(
              providerId: fixture.providerId,
              providerName: 'Unknown Provider',
            ),
            availability: const [],
          );
          final wire = fixture.resultsJson(query: query, items: [match]);
          final candidate =
              (wire['items'] as List).single as Map<String, dynamic>;
          ((candidate['factors'] as List)[factorIndex]
                  as Map<String, dynamic>)['reason'] =
              wrongReason;
          backend.intercept = (_) => fixture.Reply.json(wire);
          await fixture.failure(
            repository.loadMatches(query, userId: fixture.customerId),
            'matching.errors.invalid',
            reason: wrongReason,
          );
        }
      },
    );

    test('pages validate scores, factor order, duplicate identities, ordering and hasMore bounds', () async {
      final matches = [
        fixture.score(),
        fixture.score(
          profile: ProviderMatchingProfile(
            providerId: fixture.otherId,
            providerName: 'Unknown Provider',
          ),
          availability: const [],
        ),
      ];
      final wrongScore = fixture.resultsJson(
        query: fixture.queryWithSignals,
        items: matches,
      );
      ((wrongScore['items'] as List).first
              as Map<String, dynamic>)['score_bps'] =
          7551;
      final wrongFactors = fixture.resultsJson(
        query: fixture.queryWithSignals,
        items: matches,
      );
      final candidate =
          (wrongFactors['items'] as List).first as Map<String, dynamic>;
      candidate['factors'] = (candidate['factors'] as List).reversed.toList();
      for (final wire in [
        wrongScore,
        wrongFactors,
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          items: matches.reversed.toList(),
        ),
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          items: [matches.first, matches.first],
        ),
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          items: [matches.first],
          hasMore: true,
        ),
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          items: const [],
          hasMore: true,
        ),
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          items: matches,
          status: ServiceRequestStatus.cancelled,
        ),
      ]) {
        backend.intercept = (_) => fixture.Reply.json(wire);
        await fixture.failure(
          repository.loadMatches(
            fixture.queryWithSignals,
            userId: fixture.customerId,
            limit: 2,
          ),
          'matching.errors.invalid',
        );
      }
      backend.intercept = (_) => fixture.Reply.json(
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          items: matches,
          hasMore: true,
        ),
      );
      expect(
        (await fixture.success(
          repository.loadMatches(
            fixture.queryWithSignals,
            userId: fixture.customerId,
            limit: 2,
          ),
        )).hasMore,
        isTrue,
      );
      await fixture.failure(
        repository.loadMatches(
          fixture.queryWithSignals,
          userId: fixture.customerId,
          limit: 1,
        ),
        'matching.errors.invalid',
      );
    });

    test('keysets reject replayed anchors and rules revisions; stale query filters cannot reuse cursors', () async {
      final first = fixture.score();
      final next = fixture.score(
        profile: ProviderMatchingProfile(
          providerId: fixture.otherId,
          providerName: 'Unknown Provider',
        ),
        availability: const [],
      );
      final cursor = first.cursor(
        const MatchingRules(),
        MatchMode.recommended,
        query: fixture.queryWithSignals,
      );
      backend.intercept = (_) => fixture.Reply.json(
        fixture.resultsJson(query: fixture.queryWithSignals, items: [next]),
      );
      await fixture.success(
        repository.loadMatches(
          fixture.queryWithSignals,
          userId: fixture.customerId,
          before: cursor,
        ),
      );
      backend.intercept = (_) => fixture.Reply.json(
        fixture.resultsJson(query: fixture.queryWithSignals, items: [first]),
      );
      await fixture.failure(
        repository.loadMatches(
          fixture.queryWithSignals,
          userId: fixture.customerId,
          before: cursor,
        ),
        'matching.errors.invalid',
      );
      backend.intercept = (_) => fixture.Reply.json(
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          rules: const MatchingRules(revision: 2),
          items: [next],
        ),
      );
      await fixture.failure(
        repository.loadMatches(
          fixture.queryWithSignals,
          userId: fixture.customerId,
          before: cursor,
        ),
        'matching.errors.invalid',
      );
      backend.intercept = (_) =>
          fixture.Reply.sqlError('matching.errors.stale');
      await fixture.failure(
        repository.loadMatches(
          fixture.queryWithSignals,
          userId: fixture.customerId,
          before: cursor,
        ),
        'matching.errors.stale',
      );
      final calls = backend.calls.length;
      for (final changed in [
        fixture.queryWithSignals.copyWith(latitude: '30.05'),
        fixture.queryWithSignals.copyWith(weekday: 2),
        fixture.queryWithSignals.copyWith(time: '09:01'),
        fixture.queryWithSignals.copyWith(mode: MatchMode.allEligible),
      ]) {
        await fixture.failure(
          repository.loadMatches(
            changed,
            userId: fixture.customerId,
            before: cursor,
          ),
          'matching.errors.stale',
        );
      }
      expect(backend.calls, hasLength(calls));
    });

    test('SQL error allowlists and setup failures never expose raw backend details', () async {
      await actAs(fixture.provider);
      for (final suffix in [
        'access',
        'not_found',
        'invalid',
        'consent',
        'location',
        'experience',
        'ineligible',
        'conflict',
        'status',
        'unpublished',
        'stale',
      ]) {
        backend.intercept = (_) =>
            fixture.Reply.sqlError('matching.errors.$suffix');
        await fixture.failure(
          repository.loadProfile(userId: fixture.providerId),
          'matching.errors.$suffix',
        );
      }
      for (final code in ['PGRST202', 'PGRST205', '42883', '42P01']) {
        backend.intercept = (_) =>
            fixture.Reply.sqlError(fixture.privateError, code: code);
        await fixture.failure(
          repository.loadProfile(userId: fixture.providerId),
          'errors.database_setup',
        );
      }
      for (final message in [
        'matching.errors.access ${fixture.privateError}',
        'prefix matching.errors.access',
        'matching.errors.unknown',
        fixture.privateError,
      ]) {
        backend.intercept = (_) =>
            fixture.Reply.sqlError(message, code: 'XX000', status: 500);
        await fixture.failure(
          repository.loadProfile(userId: fixture.providerId),
          'matching.errors.load_failed',
        );
      }
      expect(auth.hasListeners, isFalse);
    });

    test(
      'definite first save rejection clears pending without reconciliation',
      () async {
        await actAs(fixture.provider);
        for (final (message, code, expected) in [
          ('matching.errors.conflict', 'P0001', 'matching.errors.conflict'),
          ('matching.errors.ineligible', 'P0001', 'matching.errors.ineligible'),
          (fixture.privateError, 'PGRST202', 'errors.database_setup'),
        ]) {
          backend.intercept = (_) =>
              fixture.Reply.sqlError(message, code: code);
          await fixture.failure(
            repository.saveProfile(fixture.draft(), userId: fixture.providerId),
            expected,
          );
          expect(
            repository.hasPendingSave(userId: fixture.providerId),
            isFalse,
          );
        }
        expect(backend.rpc('get_provider_matching_profile'), isEmpty);
      },
    );

    test('all entrypoints deny signed-out, recovery, foreign and failed mapped auth', () async {
      for (final session in const [
        AuthSession(),
        AuthSession(user: fixture.otherCustomer),
        AuthSession(user: fixture.customer, needsPasswordUpdate: true),
      ]) {
        auth.change(session);
        await _allDenied(repository);
      }
      auth.change(const AuthSession(user: fixture.customer));
      auth.checkOverride = () async =>
          left(const NetworkFailure('errors.network'));
      await _allDenied(repository);
      expect(backend.calls, isEmpty);
      expect(auth.hasListeners, isFalse);
    });

    test(
      'raw SDK identity and UUID validation run before mapped auth and RPCs',
      () async {
        await backend.setSession(userId: fixture.otherId);
        await _allDenied(repository);
        expect(auth.checkCalls, 0);
        await backend.setSession();
        for (final id in [
          '',
          'demo-customer',
          'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
        ]) {
          await _allDenied(repository, userId: id);
        }
        expect(auth.checkCalls, 0);
        await backend.client.auth.signOut();
        backend.calls.clear();
        await _allDenied(repository);
        expect(backend.calls, isEmpty);
      },
    );

    test('customer/provider role boundaries remain distinct for matching and owned preferences', () async {
      for (final task in <FutureEither<Object> Function()>[
        () => repository.loadProfile(userId: fixture.customerId),
        () => repository.loadEligibility(userId: fixture.customerId),
        () => repository.saveProfile(
          fixture.draft(provider: fixture.customerId),
          userId: fixture.customerId,
        ),
        () => repository.retryPendingSave(userId: fixture.customerId),
      ]) {
        await fixture.failure(task(), 'matching.errors.access');
      }
      await actAs(fixture.provider);
      await fixture.failure(
        repository.loadMatches(fixture.emptyQuery, userId: fixture.providerId),
        'matching.errors.access',
      );
      expect(backend.calls, isEmpty);
    });

    test('missing live client fails closed while explicit demo never uses injected SDK', () async {
      final missing = MatchingRepository(authRepository: auth);
      await _allDenied(missing, key: 'errors.database_setup');
      expect(auth.checkCalls, 0);
      final demoAuth = fixture.SessionAuth(demo: true);
      addTearDown(demoAuth.dispose);
      demoAuth.change(const AuthSession(user: _sample));
      final demo = MatchingRepository(
        authRepository: demoAuth,
        client: backend.client,
        catalogRepository: _MutableCatalog(),
      );
      expect(demo.isDemo, isTrue);
      await fixture.success(demo.loadProfile(userId: _sampleId));
      await fixture.success(demo.loadEligibility(userId: _sampleId));
      expect(backend.calls, isEmpty);
    });

    test('mapped auth is subscribed before its first await and logout/return cannot revive a save', () async {
      await actAs(fixture.provider);
      final gate = Completer<Either<Failure, AuthSession>>();
      auth.checkOverride = () {
        expect(auth.hasListeners, isTrue);
        return gate.future;
      };
      final pending = repository.saveProfile(
        fixture.draft(),
        userId: fixture.providerId,
      );
      auth.change(const AuthSession());
      auth.change(const AuthSession(user: fixture.provider));
      gate.complete(right(const AuthSession(user: fixture.provider)));
      await fixture.failure(pending, 'matching.errors.access');
      expect(backend.calls, isEmpty);
      expect(repository.hasPendingSave(userId: fixture.providerId), isFalse);
      expect(auth.hasListeners, isFalse);
    });

    test('raw SDK is subscribed before mapped auth can replace and restore its session', () async {
      auth.checkOverride = () async {
        expect(auth.hasListeners, isTrue);
        await backend.setSession(userId: fixture.otherId);
        await backend.setSession();
        return right(const AuthSession(user: fixture.customer));
      };
      await fixture.failure(
        repository.loadMatches(fixture.emptyQuery, userId: fixture.customerId),
        'matching.errors.access',
      );
      expect(backend.calls, isEmpty);
      expect(auth.hasListeners, isFalse);
    });

    test('replayed raw recovery is denied even while mapped profile is authenticated', () async {
      await backend.client.auth.verifyOTP(
        email: fixture.customer.email,
        token: '123456',
        type: OtpType.recovery,
      );
      backend.calls.clear();
      await _allDenied(repository);
      expect(backend.calls, isEmpty);
    });

    for (final change in [
      'mapped logout/return',
      'mapped role change',
      'mapped stream error',
      'mapped stream end',
      'raw account switch',
      'raw same-user replacement',
      'raw sign-in',
      'raw recovery',
    ]) {
      test(
        '$change discards late save results without reconciliation or clearing retained intent',
        () async {
          await actAs(fixture.provider);
          final gate = _RpcGate(backend, 'save_provider_matching_profile');
          final pending = repository.saveProfile(
            fixture.draft(),
            userId: fixture.providerId,
          );
          await gate.started.future;
          switch (change) {
            case 'mapped logout/return':
              auth.change(const AuthSession());
              auth.change(const AuthSession(user: fixture.provider));
            case 'mapped role change':
              auth.change(
                const AuthSession(
                  user: AppUser(
                    id: fixture.providerId,
                    email: 'role@example.test',
                    name: 'Changed Role',
                  ),
                ),
              );
            case 'mapped stream error':
              auth.streamError();
            case 'mapped stream end':
              await auth.closeEvents();
            case 'raw account switch':
              await backend.setSession(userId: fixture.otherId);
            case 'raw same-user replacement':
              await backend.setSession(userId: fixture.providerId);
            case 'raw sign-in':
              await backend.client.auth.verifyOTP(
                email: fixture.provider.email,
                token: '123456',
                type: OtpType.email,
              );
            case 'raw recovery':
              await backend.client.auth.verifyOTP(
                email: fixture.provider.email,
                token: '123456',
                type: OtpType.recovery,
              );
          }
          gate.response.complete(fixture.Reply.json(fixture.profileJson()));
          await fixture.failure(pending, 'matching.errors.access');
          expect(backend.rpc('save_provider_matching_profile'), hasLength(1));
          expect(backend.rpc('get_provider_matching_profile'), isEmpty);
          expect(repository.hasPendingSave(userId: fixture.providerId), isTrue);
          expect(auth.hasListeners, isFalse);
        },
      );
    }

    for (final privateProfile in [false, true]) {
      test(
        '${privateProfile ? 'private profile' : 'matching page'} late read is discarded after SDK replacement',
        () async {
          if (privateProfile) await actAs(fixture.provider);
          final gate = _RpcGate(
            backend,
            privateProfile
                ? 'get_provider_matching_profile'
                : 'get_provider_matches',
          );
          final pending = privateProfile
              ? repository.loadProfile(userId: fixture.providerId)
              : repository.loadMatches(
                  fixture.emptyQuery,
                  userId: fixture.customerId,
                );
          await gate.started.future;
          await backend.setSession(userId: fixture.otherId);
          gate.response.complete(
            fixture.Reply.json(
              privateProfile ? fixture.profileJson() : fixture.resultsJson(),
            ),
          );
          await fixture.failure(pending, 'matching.errors.access');
          expect(backend.rpcs, hasLength(1));
          expect(auth.hasListeners, isFalse);
        },
      );
    }

    test('ordinary token refresh allows exact canonical recovery with refreshed bearer', () async {
      await actAs(fixture.provider);
      final gate = _RpcGate(backend, 'save_provider_matching_profile');
      final pending = repository.saveProfile(
        fixture.draft(),
        userId: fixture.providerId,
      );
      await gate.started.future;
      backend.refreshedToken = 'refreshed-matching-token';
      await backend.client.auth.refreshSession();
      gate.response.complete(const fixture.Reply.disconnected());
      expect(
        await fixture.success(pending),
        ProviderMatchingProfile.fromJson(fixture.profileJson()),
      );
      expect(
        backend.rpc('save_provider_matching_profile').single.authorization,
        'Bearer test-token-${fixture.providerId}',
      );
      expect(
        backend.rpc('get_provider_matching_profile').single.authorization,
        'Bearer refreshed-matching-token',
      );
      expect(repository.hasPendingSave(userId: fixture.providerId), isFalse);
      expect(auth.checkCalls, 1);
    });

    test(
      'duplicate writes cannot overlap or release the original save lock',
      () async {
        await actAs(fixture.provider);
        final gate = _RpcGate(backend, 'save_provider_matching_profile');
        final pending = repository.saveProfile(
          fixture.draft(),
          userId: fixture.providerId,
        );
        await gate.started.future;
        for (final task in <FutureEither<Object> Function()>[
          () => repository.saveProfile(
            fixture.draft(),
            userId: fixture.providerId,
          ),
          () => repository.saveProfile(
            fixture.draft().copyWith(latitude: '30.05'),
            userId: fixture.providerId,
          ),
          () => repository.retryPendingSave(userId: fixture.providerId),
          () => repository.saveProfile(
            fixture.draft(),
            userId: fixture.providerId,
          ),
        ]) {
          await fixture.failure(task(), 'matching.errors.busy');
        }
        expect(backend.rpcs, hasLength(1));
        gate.response.complete(null);
        await fixture.success(pending);
        backend.intercept = null;
        backend.saveResponse = fixture.profileJson(revision: 2);
        await fixture.success(
          repository.saveProfile(
            fixture.draft(revision: 1),
            userId: fixture.providerId,
          ),
        );
        expect(backend.rpc('save_provider_matching_profile'), hasLength(2));
        expect(repository.hasPendingSave(userId: fixture.providerId), isFalse);
      },
    );

    for (final malformed in [false, true]) {
      test(
        '${malformed ? 'malformed' : 'dropped'} committed response recovers exact revision without another write',
        () async {
          await actAs(fixture.provider);
          backend.intercept = (call) =>
              call.isRpc('save_provider_matching_profile')
              ? malformed
                    ? const fixture.Reply.json({
                        'private': fixture.privateError,
                      })
                    : const fixture.Reply.disconnected()
              : fixture.Reply.json(fixture.profileJson());
          final result = await fixture.success(
            repository.saveProfile(fixture.draft(), userId: fixture.providerId),
          );
          expect(
            result,
            ProviderMatchingProfile.fromJson(fixture.profileJson()),
          );
          expect(backend.rpc('save_provider_matching_profile'), hasLength(1));
          expect(backend.rpc('get_provider_matching_profile'), hasLength(1));
          expect(
            repository.hasPendingSave(userId: fixture.providerId),
            isFalse,
          );
        },
      );
    }

    test('retained original save survives page recreation and same-account relogin, not process loss', () async {
      await actAs(fixture.provider);
      backend.profileResponse = fixture.emptyProfileJson();
      backend.intercept = (call) => call.isRpc('save_provider_matching_profile')
          ? const fixture.Reply.disconnected()
          : null;
      await fixture.failure(
        repository.saveProfile(fixture.draft(), userId: fixture.providerId),
        'matching.errors.uncertain',
      );
      expect(repository.hasPendingSave(userId: fixture.providerId), isTrue);
      expect(repository.hasPendingSave(userId: fixture.otherId), isFalse);
      final newPageProfile = await fixture.success(
        repository.loadProfile(userId: fixture.providerId),
      );
      final calls = backend.calls.length;
      await fixture.failure(
        repository.saveProfile(
          ProviderMatchingDraft.fromProfile(newPageProfile),
          userId: fixture.providerId,
        ),
        'matching.errors.uncertain',
      );
      expect(backend.calls, hasLength(calls));
      final restarted = MatchingRepository(
        authRepository: auth,
        client: backend.client,
      );
      expect(restarted.hasPendingSave(userId: fixture.providerId), isFalse);
      await fixture.success(
        restarted.retryPendingSave(userId: fixture.providerId),
      );
      auth.change(const AuthSession());
      await fixture.failure(
        repository.retryPendingSave(userId: fixture.providerId),
        'matching.errors.access',
      );
      await actAs(
        const AppUser(
          id: fixture.otherId,
          email: 'other-provider@example.test',
          name: 'Other Provider',
          role: UserRole.provider,
        ),
      );
      await fixture.failure(
        repository.retryPendingSave(userId: fixture.providerId),
        'matching.errors.access',
      );
      backend.profileResponse = fixture.emptyProfileJson(
        provider: fixture.otherId,
      );
      await fixture.success(
        repository.retryPendingSave(userId: fixture.otherId),
      );
      expect(backend.rpc('save_provider_matching_profile'), hasLength(1));
      await actAs(fixture.provider);
      await fixture.failure(
        repository.saveProfile(
          fixture.draft().copyWith(latitude: '30.05'),
          userId: fixture.providerId,
        ),
        'matching.errors.uncertain',
      );
      backend.profileResponse = fixture.profileJson();
      final result = await fixture.success(
        repository.retryPendingSave(userId: fixture.providerId),
      );
      expect(result, ProviderMatchingProfile.fromJson(fixture.profileJson()));
      expect(backend.rpc('save_provider_matching_profile'), hasLength(2));
      expect(
        backend.rpc('save_provider_matching_profile').last.json,
        _saveParams,
      );
      expect(repository.hasPendingSave(userId: fixture.providerId), isFalse);
      await fixture.success(
        repository.retryPendingSave(userId: fixture.providerId),
      );
      expect(backend.rpc('save_provider_matching_profile'), hasLength(2));
    });

    test('unavailable follow-up or later definite rejection cannot unfreeze an uncertain intent', () async {
      await actAs(fixture.provider);
      backend.profileResponse = fixture.emptyProfileJson();
      backend.intercept = (call) => call.isRpc('save_provider_matching_profile')
          ? const fixture.Reply.disconnected()
          : null;
      await fixture.failure(
        repository.saveProfile(fixture.draft(), userId: fixture.providerId),
        'matching.errors.uncertain',
      );
      backend.intercept = (call) => call.isRpc('save_provider_matching_profile')
          ? fixture.Reply.sqlError('matching.errors.conflict')
          : fixture.Reply.sqlError(
              fixture.privateError,
              code: 'XX000',
              status: 503,
            );
      await fixture.failure(
        repository.retryPendingSave(userId: fixture.providerId),
        'matching.errors.uncertain',
      );
      final calls = backend.calls.length;
      await fixture.failure(
        repository.saveProfile(
          fixture.draft().copyWith(
            experienceYears: const {fixture.categoryId: '5'},
          ),
          userId: fixture.providerId,
        ),
        'matching.errors.uncertain',
      );
      expect(backend.calls, hasLength(calls));
      expect(repository.hasPendingSave(userId: fixture.providerId), isTrue);
      backend.intercept = null;
      await fixture.success(
        repository.retryPendingSave(userId: fixture.providerId),
      );
      expect(repository.hasPendingSave(userId: fixture.providerId), isFalse);
    });

    test('canonical later revision or changed payload is a conflict, never original-save success', () async {
      await actAs(fixture.provider);
      for (final canonical in [
        fixture.profileJson(revision: 3),
        fixture.profileJson(latitude: 30.05),
      ]) {
        backend.intercept = (call) =>
            call.isRpc('save_provider_matching_profile')
            ? const fixture.Reply.disconnected()
            : fixture.Reply.json(canonical);
        await fixture.failure(
          repository.saveProfile(fixture.draft(), userId: fixture.providerId),
          'matching.errors.conflict',
        );
        expect(repository.hasPendingSave(userId: fixture.providerId), isFalse);
      }
      expect(backend.rpc('save_provider_matching_profile'), hasLength(2));
    });

    test('wrong save identity, revision or payload remains uncertain until exact canonical proof', () async {
      await actAs(fixture.provider);
      for (final (key, value) in <(String, Object)>[
        ('provider_id', fixture.otherId),
        ('revision', 2),
        ('latitude', 30.05),
        ('longitude', 31.25),
        ('experience_years', {fixture.categoryId: 5}),
        ('discoverable', false),
      ]) {
        backend.intercept = (call) =>
            call.isRpc('save_provider_matching_profile')
            ? fixture.Reply.json({...fixture.profileJson(), key: value})
            : fixture.Reply.json(fixture.emptyProfileJson());
        await fixture.failure(
          repository.saveProfile(fixture.draft(), userId: fixture.providerId),
          'matching.errors.uncertain',
          reason: key,
        );
        expect(repository.hasPendingSave(userId: fixture.providerId), isTrue);
      }
      backend.intercept = null;
      await fixture.success(
        repository.retryPendingSave(userId: fixture.providerId),
      );
      expect(repository.hasPendingSave(userId: fixture.providerId), isFalse);
    });

    test('max revision is readable and max-minus-one mutation is the final valid increment', () async {
      await actAs(fixture.provider);
      backend.profileResponse = fixture.profileJson(
        revision: fixture.maxRevision,
      );
      expect(
        (await fixture.success(
          repository.loadProfile(userId: fixture.providerId),
        )).revision,
        fixture.maxRevision,
      );
      backend.saveResponse = fixture.profileJson(revision: fixture.maxRevision);
      await fixture.success(
        repository.saveProfile(
          fixture.draft(revision: fixture.maxRevision - 1),
          userId: fixture.providerId,
        ),
      );
      expect(
        backend
            .rpc('save_provider_matching_profile')
            .single
            .json['p_expected_revision'],
        fixture.maxRevision - 1,
      );
      await fixture.failure(
        repository.saveProfile(
          fixture.draft(revision: fixture.maxRevision),
          userId: fixture.providerId,
        ),
        'matching.errors.invalid',
      );
      expect(backend.rpc('save_provider_matching_profile'), hasLength(1));
    });

    test('actual SDK read timeout is sanitized as a network failure without retained raw error', () async {
      await actAs(fixture.provider);
      final timed = MatchingRepository(
        authRepository: auth,
        client: backend.client,
        timeout: const Duration(milliseconds: 150),
      );
      final gate = _RpcGate(backend, 'get_provider_matching_profile');
      final pending = timed.loadProfile(userId: fixture.providerId);
      await gate.started.future;
      final result = await fixture.failure(pending, 'errors.network');
      expect(result, isA<NetworkFailure>());
      expect(auth.hasListeners, isFalse);
      gate.response.complete(null);
    });
  });
}

ServiceRequestDraft _requestDraft({String id = fixture.requestId}) =>
    ServiceRequestDraft(
      id: id,
      categoryId: 'demo-plumbing',
      title: market.privateTitle,
      description: market.privateDescription,
      city: 'Private district',
      address: market.privateAddress,
      preferredAt: fixture.instant.add(const Duration(days: 3, hours: 1)),
      consent: true,
    );

DemoMarketplaceProvider _eligibleProvider({
  bool verified = true,
  UserRole role = UserRole.provider,
  List<String> skills = const ['demo-plumbing'],
  List<String> areas = const ['Cairo'],
}) => DemoMarketplaceProvider(
  skillIds: skills,
  serviceAreas: areas,
  verified: verified,
  role: role,
);

Future<List<ProviderMatch>> _allPages(
  MatchingRepository repository,
  MatchingQuery query,
  String userId,
) async {
  final items = <ProviderMatch>[];
  MatchingCursor? before;
  for (var pageNumber = 0; pageNumber < 10; pageNumber++) {
    final page = await fixture.success(
      repository.loadMatches(query, userId: userId, before: before, limit: 2),
    );
    expect(page.items.length, lessThanOrEqualTo(2));
    items.addAll(page.items);
    if (!page.hasMore) {
      expect(
        items.map((item) => item.providerId).toSet(),
        hasLength(items.length),
      );
      if (page.items.isNotEmpty) {
        expect(
          (await fixture.success(
            repository.loadMatches(
              query,
              userId: userId,
              before: page.items.last.cursor(
                page.rules,
                page.mode,
                query: query,
              ),
              limit: 2,
            ),
          )).items,
          isEmpty,
        );
      }
      return items;
    }
    expect(page.items, hasLength(2));
    before = page.items.last.cursor(page.rules, page.mode, query: query);
  }
  fail('Matching keyset did not advance.');
}

Future<void> _allDenied(
  MatchingRepository repository, {
  String userId = fixture.customerId,
  String key = 'matching.errors.access',
}) async {
  for (final task in <FutureEither<Object> Function()>[
    () => repository.loadMatches(fixture.emptyQuery, userId: userId),
    () => repository.loadProfile(userId: userId),
    () => repository.loadEligibility(userId: userId),
    () =>
        repository.saveProfile(fixture.draft(provider: userId), userId: userId),
    () => repository.retryPendingSave(userId: userId),
  ]) {
    await fixture.failure(task(), key);
  }
}

class _MutableCatalog extends CatalogRepository {
  bool plumbingActive = true;
  Failure? error;
  int calls = 0;

  @override
  FutureEither<List<ServiceCategory>> loadCategories() async {
    calls++;
    final failure = error;
    if (failure != null) return left(failure);
    return right([
      ServiceCategory(
        id: 'demo-plumbing',
        slug: 'plumbing',
        nameEn: 'Plumbing',
        nameAr: 'Plumbing AR',
        descriptionEn: '',
        descriptionAr: '',
        iconKey: 'plumbing',
        sortOrder: 1,
        isActive: plumbingActive,
      ),
      const ServiceCategory(
        id: 'demo-electrical',
        slug: 'electrical',
        nameEn: 'Electrical',
        nameAr: 'Electrical AR',
        descriptionEn: '',
        descriptionAr: '',
        iconKey: 'electrical',
        sortOrder: 2,
        isActive: true,
      ),
    ]);
  }
}

const _saveParams = <String, Object?>{
  'p_discoverable': true,
  'p_latitude': 30.04,
  'p_longitude': 31.24,
  'p_experience_years': {fixture.categoryId: 4},
  'p_expected_revision': 0,
  'p_consent': true,
};

class _RpcGate {
  _RpcGate(fixture.LoopbackBackend backend, String rpc) {
    backend.intercept = (call) {
      if (!call.isRpc(rpc)) return null;
      if (!started.isCompleted) started.complete();
      return response.future;
    };
    addTearDown(() {
      if (!response.isCompleted) response.complete(null);
    });
  }
  final started = Completer<void>();
  final response = Completer<fixture.Reply?>();
}
