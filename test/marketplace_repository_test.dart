import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/marketplace.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/models/verification_document.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/demo_marketplace_store.dart';
import 'package:salahly/src/data/repositories/marketplace_repository.dart';
import 'package:salahly/src/data/repositories/provider_repository.dart';
import 'package:salahly/src/data/repositories/service_request_repository.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'marketplace_fixtures.dart' as fixture;

const _otherProvider = AppUser(
  id: fixture.otherId,
  email: 'another-provider@example.test',
  name: 'Other Provider',
  role: UserRole.provider,
);
const _privateServerDetail = 'private backend token/path, not a public error';

void main() {
  group('MarketplaceRepository demo', () {
    late _SessionAuth auth;
    late DemoMarketplaceStore store;
    late ServiceRequestRepository requests;
    late MarketplaceRepository repository;
    late DateTime clock;

    setUp(() {
      auth = _SessionAuth(demo: true);
      store = DemoMarketplaceStore();
      // Additional actors here are test-only fixtures, never ordinary demo users.
      store.providers[fixture.providerId] = _eligibleProvider();
      clock = fixture.instant;
      requests = ServiceRequestRepository(
        authRepository: auth,
        demoStore: store,
        now: () => clock,
      );
      repository = MarketplaceRepository(
        authRepository: auth,
        demoStore: requests.demoStore,
        now: () => clock,
      );
    });
    tearDown(() => auth.dispose());

    Future<MarketplaceListing> publish({
      String id = fixture.requestId,
      String category = 'demo-plumbing',
      String city = 'Cairo',
    }) async {
      auth.change(const AuthSession(user: fixture.customer));
      await _success(
        requests.submitRequest(
          _requestDraft(id: id, category: category),
          userId: fixture.customerId,
        ),
      );
      return _success(
        repository.publishListing(
          id,
          userId: fixture.customerId,
          summary: fixture.summary,
          city: city,
          consent: true,
        ),
      );
    }

    Future<ServiceJob> assign({String request = fixture.requestId}) async {
      await publish(id: request);
      auth.change(const AuthSession(user: fixture.provider));
      final quote = await _success(
        repository.saveQuote(
          fixture.draft(request: request),
          userId: fixture.providerId,
        ),
      );
      auth.change(const AuthSession(user: fixture.customer));
      return _success(
        repository.acceptQuote(
          quote,
          userId: fixture.customerId,
          consent: true,
        ),
      );
    }

    test('real demo accounts complete a private request through explicit publication and consent', () async {
      final demoAuth = DemoAuthRepository();
      addTearDown(demoAuth.dispose);
      final m6 = ServiceRequestRepository(
        authRepository: demoAuth,
        now: () => clock,
      );
      final market = MarketplaceRepository(
        authRepository: demoAuth,
        demoStore: m6.demoStore,
        now: () => clock,
      );
      Future<AppUser> login(String email) => _success(
        demoAuth.login(email: email, password: DemoAuthRepository.demoPassword),
      );
      final customer = await login(DemoAuthRepository.customerEmail);
      final draft = _requestDraft();
      final request = await _success(
        m6.submitRequest(draft, userId: customer.id),
      );
      final unpublished = await _success(
        market.loadCustomerQuotes(request.id, userId: customer.id),
      );
      expect(unpublished.listing, isNull);
      expect(unpublished.quotes, isEmpty);
      final provider = await login(DemoAuthRepository.marketplaceProviderEmail);
      expect(provider.id, DemoMarketplaceStore.sampleProviderId);
      expect(provider.role, UserRole.provider);
      expect(
        (await _success(market.loadFeed(userId: provider.id))).items,
        isEmpty,
      );
      await _failure(
        market.loadProviderRequest(request.id, userId: provider.id),
        'marketplace.errors.not_found',
      );
      await _failure(
        m6.loadRequest(request.id, userId: provider.id),
        'requests.errors.access',
      );

      await login(DemoAuthRepository.customerEmail);
      await _failure(
        market.publishListing(
          request.id,
          userId: customer.id,
          summary: fixture.summary,
          city: 'Cairo',
          consent: false,
        ),
        'marketplace.errors.consent',
      );
      final listing = await _success(
        market.publishListing(
          request.id,
          userId: customer.id,
          summary: ' ${fixture.summary}\n',
          city: ' Cairo ',
          consent: true,
        ),
      );
      expect(listing.summary, fixture.summary);
      expect(listing.summary, isNot(request.title));
      expect(listing.city, 'Cairo');
      expect(request.city, 'Private district');
      expect(
        await _success(m6.loadRequest(request.id, userId: customer.id)),
        request,
      );
      await login(DemoAuthRepository.marketplaceProviderEmail);
      final feed = await _success(market.loadFeed(userId: provider.id));
      expect(feed.eligible, isTrue);
      expect(feed.items, [listing]);
      expect(feed.items.single.props, isNot(contains(request.address)));
      expect(feed.items.single.props, isNot(contains(customer.id)));
      expect(
        (await _success(market.loadJobs(userId: provider.id))).items,
        isEmpty,
      );
      final quote = await _success(
        market.saveQuote(fixture.draft(), userId: provider.id),
      );
      expect(quote.revision, 1);
      expect(quote.amountMinor, 12345);
      expect(quote.providerId, provider.id);
      expect(quote.status, QuoteStatus.pending);

      await login(DemoAuthRepository.customerEmail);
      final book = await _success(
        market.loadCustomerQuotes(request.id, userId: customer.id),
      );
      expect(book.quotes, [quote]);
      expect(book.job, isNull);
      await _failure(
        market.acceptQuote(quote, userId: customer.id, consent: false),
        'marketplace.errors.consent',
      );
      expect(
        (await _success(market.loadJobs(userId: customer.id))).items,
        isEmpty,
      );
      final selected = await _success(
        market.acceptQuote(quote, userId: customer.id, consent: true),
      );
      expect(selected.requestTitle, request.title);
      expect(selected.requestDescription, request.description);
      expect(selected.city, request.city);
      expect(selected.address, request.address);
      expect(selected.quoteRevision, quote.revision);
      expect(selected.status, JobStatus.selected);
      expect(selected.history.single.actorId, customer.id);
      await _failure(
        m6.cancelRequest(request.id, userId: customer.id),
        'requests.errors.status',
      );
      expect(
        (await _success(m6.loadRequest(request.id, userId: customer.id)))
            .status,
        ServiceRequestStatus.assigned,
      );

      await login(DemoAuthRepository.marketplaceProviderEmail);
      expect(
        await _success(market.loadJob(selected.id, userId: provider.id)),
        selected,
      );
      expect((await _success(market.loadJobs(userId: provider.id))).items, [
        selected,
      ]);
      expect(
        (await _success(market.loadFeed(userId: provider.id))).items,
        isEmpty,
      );
      var job = selected;
      for (final target in [
        JobStatus.onTheWay,
        JobStatus.inProgress,
        JobStatus.awaitingConfirmation,
      ]) {
        clock = clock.add(const Duration(minutes: 1));
        job = await _success(
          market.transitionJob(job, target, userId: provider.id),
        );
        expect(job.status, target);
        expect(job.amountMinor, quote.amountMinor);
        expect(job.notes, quote.notes);
        expect(job.quoteRevision, quote.revision);
      }
      await _failure(
        market.transitionJob(job, JobStatus.completed, userId: provider.id),
        'marketplace.errors.status',
      );
      await login(DemoAuthRepository.customerEmail);
      clock = clock.add(const Duration(minutes: 1));
      final completed = await _success(
        market.transitionJob(job, JobStatus.completed, userId: customer.id),
      );
      expect(completed.status, JobStatus.completed);
      expect(completed.history, hasLength(5));
      expect(completed.history.map((event) => event.actorId), [
        customer.id,
        provider.id,
        provider.id,
        provider.id,
        customer.id,
      ]);
      expect(
        await _success(
          market.transitionJob(job, JobStatus.completed, userId: customer.id),
        ),
        completed,
      );
      expect(
        await _success(
          market.acceptQuote(quote, userId: customer.id, consent: true),
        ),
        completed,
      );
      expect(selected.history, hasLength(1));
      await _success(demoAuth.logout());
      await _failure(
        market.loadJob(completed.id, userId: customer.id),
        'marketplace.errors.access',
      );
    });

    test(
      'ordinary and pending demo providers cannot forge marketplace approval',
      () async {
        final demoAuth = DemoAuthRepository();
        addTearDown(demoAuth.dispose);
        final demoStore = DemoMarketplaceStore();
        final market = MarketplaceRepository(
          authRepository: demoAuth,
          demoStore: demoStore,
        );
        final onboarding = ProviderRepository(authRepository: demoAuth);
        final ordinary = await _success(
          demoAuth.login(
            email: DemoAuthRepository.providerEmail,
            password: DemoAuthRepository.demoPassword,
          ),
        );
        expect(ordinary.id, 'demo-provider');
        expect(demoStore.providers.keys, [
          DemoMarketplaceStore.sampleProviderId,
        ]);
        final forged = ProviderProfile(
          userId: ordinary.id,
          bio: 'An experienced synthetic plumbing provider.',
          skillIds: const ['demo-plumbing'],
          serviceAreas: const ['Cairo'],
          availability: const [
            ProviderAvailability(weekday: 1, startMinute: 540, endMinute: 1020),
          ],
          verification: ProviderVerification(
            id: 'forged-review',
            documentPath: 'private/document.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 3,
            status: ProviderVerificationStatus.verified,
            submittedAt: fixture.instant,
          ),
        );
        expect(
          (await _success(onboarding.saveProfile(forged))).verification,
          isNull,
        );
        expect(
          (await _success(market.loadFeed(userId: ordinary.id))).eligible,
          isFalse,
        );
        final pending = await _success(
          onboarding.submitVerification(
            userId: ordinary.id,
            document: VerificationDocument.fromBytes(
              Uint8List.fromList([0xff, 0xd8, 0xff]),
            ),
            consent: true,
          ),
        );
        expect(
          pending.verification!.status,
          ProviderVerificationStatus.pending,
        );
        final feed = await _success(market.loadFeed(userId: ordinary.id));
        expect(feed.eligible, isFalse);
        expect(feed.items, isEmpty);
        await _failure(
          market.saveQuote(fixture.draft(), userId: ordinary.id),
          'marketplace.errors.not_found',
        );
        expect(demoStore.providers.containsKey(ordinary.id), isFalse);
        expect(
          demoStore.providers[DemoMarketplaceStore.sampleProviderId]!.skillIds,
          ['demo-plumbing'],
        );
        expect(
          demoStore
              .providers[DemoMarketplaceStore.sampleProviderId]!
              .serviceAreas,
          ['Cairo'],
        );
      },
    );

    test(
      'publication is explicit, owner-scoped and exact-retry immutable',
      () async {
        final listing = await publish();
        expect(
          await _success(
            repository.publishListing(
              fixture.requestId,
              userId: fixture.customerId,
              summary: ' ${fixture.summary} ',
              city: ' Cairo ',
              consent: true,
            ),
          ),
          listing,
        );
        for (final (summary, city) in [
          ('A different safe public summary.', 'Cairo'),
          (fixture.summary, 'Giza'),
        ]) {
          await _failure(
            repository.publishListing(
              fixture.requestId,
              userId: fixture.customerId,
              summary: summary,
              city: city,
              consent: true,
            ),
            'marketplace.errors.conflict',
          );
        }
        auth.change(const AuthSession(user: fixture.otherCustomer));
        await _failure(
          repository.publishListing(
            fixture.requestId,
            userId: fixture.otherId,
            summary: fixture.summary,
            city: 'Cairo',
            consent: true,
          ),
          'marketplace.errors.not_found',
        );
        await _failure(
          repository.loadCustomerQuotes(
            fixture.requestId,
            userId: fixture.otherId,
          ),
          'marketplace.errors.not_found',
        );
        auth.change(const AuthSession(user: fixture.customer));
        await _success(
          requests.cancelRequest(fixture.requestId, userId: fixture.customerId),
        );
        final retry = await _success(
          repository.publishListing(
            fixture.requestId,
            userId: fixture.customerId,
            summary: fixture.summary,
            city: 'Cairo',
            consent: true,
          ),
        );
        expect(retry.requestStatus, ServiceRequestStatus.cancelled);
        expect(retry.publishedAt, listing.publishedAt);
        expect(retry.summary, listing.summary);
      },
    );

    test('quote editing, stale comparison, withdrawal and reactivation keep one identity', () async {
      await publish();
      auth.change(const AuthSession(user: fixture.provider));
      final originalDraft = fixture.draft();
      final original = await _success(
        repository.saveQuote(originalDraft, userId: fixture.providerId),
      );
      expect(
        await _success(
          repository.saveQuote(originalDraft, userId: fixture.providerId),
        ),
        original,
      );
      final revisedDraft = QuoteDraft.fromQuote(original)
          .copyWith(amount: '150.05', notes: ' Revised scope ');
      clock = clock.add(const Duration(minutes: 1));
      final revised = await _success(
        repository.saveQuote(revisedDraft, userId: fixture.providerId),
      );
      expect(revised.id, original.id);
      expect(revised.createdAt, original.createdAt);
      expect(revised.revision, 2);
      expect(revised.notes, 'Revised scope');
      expect(original.amountMinor, 12345);
      await _failure(
        repository.saveQuote(originalDraft, userId: fixture.providerId),
        'marketplace.errors.conflict',
      );
      await _failure(
        repository.withdrawQuote(original, userId: fixture.providerId),
        'marketplace.errors.conflict',
      );
      auth.change(const AuthSession(user: fixture.customer));
      await _failure(
        repository.acceptQuote(
          original,
          userId: fixture.customerId,
          consent: true,
        ),
        'marketplace.errors.conflict',
      );
      expect(
        (await _success(
          repository.loadCustomerQuotes(
            fixture.requestId,
            userId: fixture.customerId,
          ),
        )).quotes,
        [revised],
      );

      auth.change(const AuthSession(user: fixture.provider));
      final withdrawn = await _success(
        repository.withdrawQuote(revised, userId: fixture.providerId),
      );
      expect(withdrawn.status, QuoteStatus.withdrawn);
      expect(withdrawn.revision, revised.revision);
      expect(
        await _success(
          repository.withdrawQuote(revised, userId: fixture.providerId),
        ),
        withdrawn,
      );
      final active = await _success(
        repository.saveQuote(
          QuoteDraft.fromQuote(withdrawn),
          userId: fixture.providerId,
        ),
      );
      expect(active.id, original.id);
      expect(active.status, QuoteStatus.pending);
      expect(active.revision, 3);
      expect(store.quotes, hasLength(1));
      expect(
        (await _success(repository.loadMyQuotes(userId: fixture.providerId)))
            .items
            .single
            .quote,
        active,
      );
    });

    test('acceptance freezes terms, closes competitors and survives later eligibility changes', () async {
      await publish();
      auth.change(const AuthSession(user: fixture.provider));
      final draft = fixture.draft();
      final chosen = await _success(
        repository.saveQuote(draft, userId: fixture.providerId),
      );
      store.providers[fixture.otherId] = _eligibleProvider();
      auth.change(const AuthSession(user: _otherProvider));
      final competing = await _success(
        repository.saveQuote(
          draft.copyWith(amount: '200'),
          userId: fixture.otherId,
        ),
      );
      auth.change(const AuthSession(user: fixture.customer));
      final selected = await _success(
        repository.acceptQuote(
          chosen,
          userId: fixture.customerId,
          consent: true,
        ),
      );
      expect(selected.quoteId, chosen.id);
      expect(selected.quoteRevision, chosen.revision);
      expect(store.jobs, hasLength(1));
      expect(store.quotes[chosen.id]!.status, QuoteStatus.accepted);
      expect(store.quotes[competing.id]!.status, QuoteStatus.notSelected);
      await _failure(
        repository.acceptQuote(
          competing,
          userId: fixture.customerId,
          consent: true,
        ),
        'marketplace.errors.conflict',
      );
      await _failure(
        repository.acceptQuote(
          chosen.copyWith(amountMinor: chosen.amountMinor + 1),
          userId: fixture.customerId,
          consent: true,
        ),
        'marketplace.errors.conflict',
      );
      store.providers.remove(fixture.providerId);
      expect(
        await _success(
          repository.acceptQuote(
            chosen,
            userId: fixture.customerId,
            consent: true,
          ),
        ),
        selected,
      );
      auth.change(const AuthSession(user: fixture.provider));
      expect(
        await _success(repository.saveQuote(draft, userId: fixture.providerId)),
        store.quotes[chosen.id],
      );
      await _failure(
        repository.saveQuote(
          QuoteDraft.fromQuote(chosen).copyWith(amount: '999'),
          userId: fixture.providerId,
        ),
        'marketplace.errors.ineligible',
      );
      await _failure(
        repository.withdrawQuote(chosen, userId: fixture.providerId),
        'marketplace.errors.status',
      );
      expect(
        await _success(
          repository.loadJob(selected.id, userId: fixture.providerId),
        ),
        selected,
      );
      final working = await _success(
        repository.transitionJob(
          selected,
          JobStatus.inProgress,
          userId: fixture.providerId,
        ),
      );
      expect(working.amountMinor, chosen.amountMinor);
      expect(working.notes, chosen.notes);
      auth.change(const AuthSession(user: _otherProvider));
      expect(
        (await _success(repository.loadMyQuotes(userId: fixture.otherId)))
            .items
            .single
            .quote!
            .status,
        QuoteStatus.notSelected,
      );
      expect(
        (await _success(repository.loadJobs(userId: fixture.otherId))).items,
        isEmpty,
      );
      await _failure(
        repository.loadJob(selected.id, userId: fixture.otherId),
        'marketplace.errors.not_found',
      );
    });

    test(
      'M6 cancellation closes pending quotes without changing withdrawn quotes',
      () async {
        await publish();
        auth.change(const AuthSession(user: fixture.provider));
        final pending = await _success(
          repository.saveQuote(fixture.draft(), userId: fixture.providerId),
        );
        store.providers[fixture.otherId] = _eligibleProvider();
        auth.change(const AuthSession(user: _otherProvider));
        final other = await _success(
          repository.saveQuote(fixture.draft(), userId: fixture.otherId),
        );
        final withdrawn = await _success(
          repository.withdrawQuote(other, userId: fixture.otherId),
        );
        auth.change(const AuthSession(user: fixture.customer));
        clock = clock.add(const Duration(minutes: 1));
        final cancelled = await _success(
          requests.cancelRequest(fixture.requestId, userId: fixture.customerId),
        );
        expect(
          store.listings[fixture.requestId]!.requestStatus,
          ServiceRequestStatus.cancelled,
        );
        expect(store.quotes[pending.id]!.status, QuoteStatus.cancelled);
        expect(store.quotes[pending.id]!.updatedAt, cancelled.cancelledAt);
        expect(store.quotes[withdrawn.id], withdrawn);
        await _failure(
          repository.acceptQuote(
            pending,
            userId: fixture.customerId,
            consent: true,
          ),
          'marketplace.errors.status',
        );
        auth.change(const AuthSession(user: fixture.provider));
        expect(
          (await _success(repository.loadFeed(userId: fixture.providerId)))
              .items,
          isEmpty,
        );
        final history = await _success(
          repository.loadMyQuotes(userId: fixture.providerId),
        );
        expect(history.items.single.canQuote, isFalse);
        expect(history.items.single.quote!.status, QuoteStatus.cancelled);
      },
    );

    for (final actor in [fixture.customer, fixture.provider]) {
      test(
        '${actor.role.name} can cancel before work, but never after it starts',
        () async {
          final selected = await assign();
          auth.change(AuthSession(user: actor));
          final cancelled = await _success(
            repository.transitionJob(
              selected,
              JobStatus.cancelled,
              userId: actor.id,
            ),
          );
          expect(cancelled.status, JobStatus.cancelled);
          expect(cancelled.history.last.actorId, actor.id);
          expect(
            await _success(
              repository.transitionJob(
                selected,
                JobStatus.cancelled,
                userId: actor.id,
              ),
            ),
            cancelled,
          );
          await _failure(
            repository.transitionJob(
              cancelled,
              JobStatus.inProgress,
              userId: actor.id,
            ),
            'marketplace.errors.status',
          );
          final next = await assign(request: fixture.id(2));
          auth.change(const AuthSession(user: fixture.provider));
          final working = await _success(
            repository.transitionJob(
              next,
              JobStatus.inProgress,
              userId: fixture.providerId,
            ),
          );
          auth.change(AuthSession(user: actor));
          await _failure(
            repository.transitionJob(
              working,
              JobStatus.cancelled,
              userId: actor.id,
            ),
            'marketplace.errors.status',
          );
          await _failure(
            repository.transitionJob(
              next,
              JobStatus.cancelled,
              userId: actor.id,
            ),
            'marketplace.errors.conflict',
          );
          expect(store.jobs[working.id]!.status, JobStatus.inProgress);
        },
      );
    }

    test('feed eligibility requires verified current skill and matching public city', () async {
      await publish();
      await publish(id: fixture.id(2), city: 'Giza');
      await publish(id: fixture.id(3), category: 'demo-electrical');
      auth.change(const AuthSession(user: fixture.provider));
      expect(
        (await _success(repository.loadFeed(userId: fixture.providerId))).items
            .map((item) => item.requestId),
        [fixture.requestId],
      );
      for (final (provider, eligible) in [
        (_eligibleProvider(verified: false), false),
        (_eligibleProvider(skills: const []), false),
        (_eligibleProvider(skills: const ['inactive-category']), false),
        (_eligibleProvider(areas: const []), false),
        (_eligibleProvider(areas: const ['Alexandria']), true),
      ]) {
        store.providers[fixture.providerId] = provider;
        final feed = await _success(
          repository.loadFeed(userId: fixture.providerId),
        );
        expect(feed.eligible, eligible);
        expect(feed.items, isEmpty);
        await _failure(
          repository.loadProviderRequest(
            fixture.requestId,
            userId: fixture.providerId,
          ),
          'marketplace.errors.not_found',
        );
        await _failure(
          repository.saveQuote(fixture.draft(), userId: fixture.providerId),
          'marketplace.errors.not_found',
        );
      }
      store.providers[fixture.providerId] = _eligibleProvider(
        areas: const [' cairo '],
      );
      expect(
        (await _success(repository.loadFeed(userId: fixture.providerId))).items,
        hasLength(1),
      );
      final skills = ['demo-plumbing'];
      final areas = ['Cairo'];
      final provider = DemoMarketplaceProvider(
        skillIds: skills,
        serviceAreas: areas,
      );
      skills.clear();
      areas.clear();
      expect(provider.skillIds, ['demo-plumbing']);
      expect(provider.serviceAreas, ['Cairo']);
      expect(() => provider.skillIds.clear(), throwsUnsupportedError);
      expect(() => provider.serviceAreas.clear(), throwsUnsupportedError);
    });

    test('owner isolation, recovery and account switching cannot expose retained jobs', () async {
      final selected = await assign();
      auth.change(const AuthSession(user: fixture.otherCustomer));
      expect(
        (await _success(repository.loadJobs(userId: fixture.otherId))).items,
        isEmpty,
      );
      await _failure(
        repository.loadJob(selected.id, userId: fixture.otherId),
        'marketplace.errors.not_found',
      );
      await _failure(
        repository.transitionJob(
          selected,
          JobStatus.cancelled,
          userId: fixture.otherId,
        ),
        'marketplace.errors.access',
      );
      await _failure(
        repository.loadCustomerQuotes(
          fixture.requestId,
          userId: fixture.otherId,
        ),
        'marketplace.errors.not_found',
      );
      for (final session in const [
        AuthSession(),
        AuthSession(user: fixture.customer, needsPasswordUpdate: true),
      ]) {
        auth.change(session);
        await _failure(
          repository.loadJobs(userId: fixture.customerId),
          'marketplace.errors.access',
        );
        await _failure(
          repository.loadJob(selected.id, userId: fixture.customerId),
          'marketplace.errors.access',
        );
      }
      auth.change(const AuthSession(user: fixture.customer));
      expect(
        await _success(
          repository.loadJob(selected.id, userId: fixture.customerId),
        ),
        selected,
      );
      expect(auth.hasListeners, isFalse);
    });

    test(
      'a fresh demo store resets data without a process-global fixture history',
      () async {
        final selected = await assign();
        final freshRequests = ServiceRequestRepository(authRepository: auth);
        final fresh = MarketplaceRepository(
          authRepository: auth,
          demoStore: freshRequests.demoStore,
        );
        expect(
          (await _success(fresh.loadJobs(userId: fixture.customerId))).items,
          isEmpty,
        );
        expect(
          (await _success(
            freshRequests.loadRequests(userId: fixture.customerId),
          )).items,
          isEmpty,
        );
        await _failure(
          fresh.loadCustomerQuotes(
            fixture.requestId,
            userId: fixture.customerId,
          ),
          'marketplace.errors.not_found',
        );
        expect(freshRequests.demoStore.providers.keys, [
          DemoMarketplaceStore.sampleProviderId,
        ]);
        expect(
          await _success(
            repository.loadJob(selected.id, userId: fixture.customerId),
          ),
          selected,
        );
      },
    );

    test('all demo pages use descending timestamp plus ID keysets with bounded pages', () async {
      final numbers = [1, 4, 2, 3, 0];
      for (final number in numbers) {
        clock = number == 0
            ? fixture.instant.add(const Duration(seconds: 1))
            : fixture.instant;
        await publish(id: fixture.id(number));
      }
      auth.change(const AuthSession(user: fixture.provider));
      final feed = await _allPages<MarketplaceListing>(
        (before) => repository.loadFeed(
          userId: fixture.providerId,
          before: before,
          limit: 2,
        ),
        (item) => item.cursor,
      );
      expect(
        feed.map((item) => item.requestId),
        [0, 4, 3, 2, 1].map(fixture.id),
      );
      for (final number in numbers) {
        final created = number == 0 ? clock : fixture.instant;
        final quote = ProviderQuote.fromJson(
          fixture.quote(
            id: fixture.id(number),
            request: fixture.id(number),
            createdAt: created,
          ),
        );
        store.quotes[quote.id] = quote;
        final job = ServiceJob.fromJson(
          fixture.job(
            id: fixture.id(number),
            request: fixture.id(number),
            quote: quote.id,
            createdAt: created,
          ),
        );
        store.jobs[job.id] = job;
      }
      final quotes = await _allPages<QuoteOpportunity>(
        (before) => repository.loadMyQuotes(
          userId: fixture.providerId,
          before: before,
          limit: 2,
        ),
        (item) => item.quote!.cursor,
      );
      expect(
        quotes.map((item) => item.quote!.id),
        [0, 4, 3, 2, 1].map(fixture.id),
      );
      final jobs = await _allPages<ServiceJob>(
        (before) => repository.loadJobs(
          userId: fixture.providerId,
          before: before,
          limit: 2,
        ),
        (item) => item.cursor,
      );
      expect(jobs.map((item) => item.id), [0, 4, 3, 2, 1].map(fixture.id));
      await publish(id: fixture.requestId);
      store.quotes.clear();
      for (final number in numbers) {
        final quote = ProviderQuote.fromJson(
          fixture.quote(
            id: fixture.id(number),
            provider: fixture.id(number + 1000),
            createdAt: number == 0 ? clock : fixture.instant,
          ),
        );
        store.quotes[quote.id] = quote;
      }
      final customerQuotes = await _allPages<ProviderQuote>(
        (before) async =>
            (await repository.loadCustomerQuotes(
              fixture.requestId,
              userId: fixture.customerId,
              before: before,
              limit: 2,
            )).map(
              (book) =>
                  MarketplacePage(items: book.quotes, hasMore: book.hasMore),
            ),
        (item) => item.cursor,
      );
      expect(
        customerQuotes.map((item) => item.id),
        [0, 4, 3, 2, 1].map(fixture.id),
      );
      expect(
        (await _success(
          repository.loadCustomerQuotes(
            fixture.requestId,
            userId: fixture.customerId,
            limit: 5,
          ),
        )).hasMore,
        isFalse,
      );
    });
  });

  group('MarketplaceRepository live loopback SDK', () {
    late _Backend backend;
    late _SessionAuth auth;
    late MarketplaceRepository repository;

    setUp(() async {
      backend = await _Backend.start();
      auth = _SessionAuth(demo: false);
      repository = MarketplaceRepository(
        authRepository: auth,
        client: backend.client,
      );
    });
    tearDown(() async {
      expect(backend.unexpected, isEmpty);
      for (final call in backend.calls.where(
        (call) => !call.uri.path.startsWith('/auth/'),
      )) {
        expect(call.method, 'POST');
        expect(call.uri.path, startsWith('/rest/v1/rpc/'));
        expect(call.uri.query, isEmpty);
      }
      await backend.close();
      await auth.dispose();
    });

    Future<void> actAs(AppUser user) async {
      auth.change(AuthSession(user: user));
      await backend.setSession(userId: user.id);
    }

    for (final page in _PageRead.values) {
      test(
        '${page.name} uses exact RPC UTC/UUID keysets and default bounded limit',
        () async {
          await actAs(page.actor);
          final before = MarketplaceCursor(
            createdAt: DateTime.parse('2026-11-09T14:00:00+02:00').toLocal(),
            id: fixture.id(20),
          );
          await _success(page.run(repository, before: before, limit: 2));
          expect(backend.rpcs.single.uri.path, '/rest/v1/rpc/${page.rpc}');
          expect(backend.rpcs.single.json, {
            if (page == _PageRead.customerQuotes)
              'p_request_id': fixture.requestId,
            'p_before_created_at': '2026-11-09T12:00:00.000Z',
            'p_before_id': fixture.id(20),
            'p_limit': 2,
          });
          await _success(page.run(repository));
          expect(backend.rpcs.last.json['p_limit'], 20);
          expect(backend.rpcs.last.json['p_before_created_at'], isNull);
          expect(backend.rpcs.last.json['p_before_id'], isNull);
          await _success(page.run(repository, limit: 50));
          expect(backend.rpcs.last.json['p_limit'], 50);
          expect(auth.checkCalls, 3);
          expect(auth.hasListeners, isFalse);
        },
      );

      test(
        '${page.name} rejects invalid cursors, bounds and oversized server pages',
        () async {
          await actAs(page.actor);
          for (final limit in [-1, 0, 51]) {
            await _failure(
              page.run(repository, limit: limit),
              'marketplace.errors.invalid',
            );
          }
          for (final id in [
            'bad',
            '../${fixture.quoteId}',
            ' ${fixture.quoteId}',
            'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
          ]) {
            await _failure(
              page.run(
                repository,
                before: MarketplaceCursor(createdAt: fixture.instant, id: id),
              ),
              'marketplace.errors.invalid',
            );
          }
          expect(backend.calls, isEmpty);
          for (final (count, more) in [(3, false), (1, true), (0, true)]) {
            backend.intercept = (_) =>
                _Reply.json(page.response(count: count, hasMore: more));
            await _failure(
              page.run(repository, limit: 2),
              'marketplace.errors.invalid',
            );
          }
          backend.intercept = (_) =>
              _Reply.json(page.response(count: 2, hasMore: true));
          await _success(page.run(repository, limit: 2));
        },
      );
    }

    test('all public write inputs validate before HTTP and serialize normalized values', () async {
      final quote = ProviderQuote.fromJson(fixture.quote());
      for (final (task, key) in <(FutureEither<Object> Function(), String)>[
        (
          () => repository.publishListing(
            'bad',
            userId: fixture.customerId,
            summary: fixture.summary,
            city: 'Cairo',
            consent: true,
          ),
          'marketplace.errors.not_found',
        ),
        (
          () => repository.publishListing(
            fixture.requestId,
            userId: fixture.customerId,
            summary: fixture.summary,
            city: 'Cairo',
            consent: false,
          ),
          'marketplace.errors.consent',
        ),
        (
          () => repository.publishListing(
            fixture.requestId,
            userId: fixture.customerId,
            summary: 'short',
            city: 'Cairo',
            consent: true,
          ),
          'marketplace.errors.summary',
        ),
        (
          () => repository.publishListing(
            fixture.requestId,
            userId: fixture.customerId,
            summary: 'x' * 1001,
            city: 'Cairo',
            consent: true,
          ),
          'marketplace.errors.summary',
        ),
        (
          () => repository.publishListing(
            fixture.requestId,
            userId: fixture.customerId,
            summary: fixture.summary,
            city: 'x',
            consent: true,
          ),
          'marketplace.errors.city',
        ),
        (
          () => repository.acceptQuote(
            quote,
            userId: fixture.customerId,
            consent: false,
          ),
          'marketplace.errors.consent',
        ),
      ]) {
        await _failure(task(), key);
      }
      await actAs(fixture.provider);
      for (final (draft, key) in [
        (fixture.draft(request: 'bad'), 'marketplace.errors.invalid'),
        (fixture.draft().copyWith(amount: '1e2'), 'marketplace.errors.amount'),
        (
          fixture.draft().copyWith(duration: '1.5'),
          'marketplace.errors.duration',
        ),
        (
          fixture.draft().copyWith(notes: 'x' * 1001),
          'marketplace.errors.notes',
        ),
      ]) {
        await _failure(
          repository.saveQuote(draft, userId: fixture.providerId),
          key,
        );
      }
      expect(backend.calls, isEmpty);
      await _success(
        repository.saveQuote(
          fixture.draft().copyWith(
            amount: ' \u0661\u0662\u0663\u066b\u0664\u0665 ',
            duration: '\u06f9\u06f0',
            notes: ' ${fixture.notes}\n',
          ),
          userId: fixture.providerId,
        ),
      );
      expect(
        backend.rpc('save_provider_quote').single.json,
        _Mutation.save.params,
      );
      await actAs(fixture.customer);
      await _success(
        repository.publishListing(
          fixture.requestId,
          userId: fixture.customerId,
          summary: '\t${fixture.summary}\n',
          city: ' Cairo ',
          consent: true,
        ),
      );
      expect(
        backend.rpc('publish_request_listing').single.json,
        _Mutation.publish.params,
      );
    });

    test('live reads reject foreign owners, wrong identities and unsafe wire shapes', () async {
      for (final (json, key) in <(Object?, String)>[
        (fixture.book(customer: fixture.otherId), 'marketplace.errors.access'),
        (fixture.book(request: fixture.id(9)), 'marketplace.errors.access'),
        ({'request_id': fixture.requestId}, 'marketplace.errors.load_failed'),
        (null, 'marketplace.errors.invalid'),
        ([fixture.book()], 'marketplace.errors.invalid'),
      ]) {
        backend.intercept = (_) => _Reply.json(json);
        await _failure(
          repository.loadCustomerQuotes(
            fixture.requestId,
            userId: fixture.customerId,
          ),
          key,
        );
      }
      for (final json in [
        fixture.job(customer: fixture.otherId),
        fixture.job(id: fixture.id(9)),
      ]) {
        backend.intercept = (_) => _Reply.json(json);
        await _failure(
          repository.loadJob(fixture.jobId, userId: fixture.customerId),
          'marketplace.errors.access',
        );
      }
      await actAs(fixture.provider);
      for (final json in [
        fixture.opportunity(request: fixture.id(9)),
        fixture.opportunity(ownQuote: fixture.quote(provider: fixture.otherId)),
      ]) {
        backend.intercept = (_) => _Reply.json(json);
        await _failure(
          repository.loadProviderRequest(
            fixture.requestId,
            userId: fixture.providerId,
          ),
          'marketplace.errors.access',
        );
      }
      backend.intercept = (_) => _Reply.json({
        'items': [
          fixture.opportunity(
            ownQuote: fixture.quote(provider: fixture.otherId),
          ),
        ],
        'has_more': false,
      });
      await _failure(
        repository.loadMyQuotes(userId: fixture.providerId),
        'marketplace.errors.access',
      );
      backend.intercept = (_) => _Reply.json({
        'items': [fixture.job(provider: fixture.otherId)],
        'has_more': false,
      });
      await _failure(
        repository.loadJobs(userId: fixture.providerId),
        'marketplace.errors.access',
      );
      for (final status in [
        ServiceRequestStatus.assigned,
        ServiceRequestStatus.cancelled,
      ]) {
        backend.intercept = (_) => _Reply.json({
          'items': [fixture.listing(status: status)],
          'has_more': false,
          'eligible': true,
        });
        await _failure(
          repository.loadFeed(userId: fixture.providerId),
          'marketplace.errors.invalid',
        );
      }
      backend.intercept = (_) => const _Reply.json({
        'items': <Object?>[],
        'has_more': false,
        'eligible': false,
      });
      final ineligible = await _success(
        repository.loadFeed(userId: fixture.providerId),
      );
      expect(ineligible.eligible, isFalse);
      expect(ineligible.items, isEmpty);
    });

    test(
      'exact SQL/setup allowlists never expose raw unknown server errors',
      () async {
        for (final key in [
          'access',
          'not_found',
          'invalid',
          'consent',
          'summary',
          'city',
          'ineligible',
          'amount',
          'duration',
          'notes',
          'currency',
          'conflict',
          'status',
          'unpublished',
        ]) {
          backend.intercept = (_) => _Reply.sqlError('marketplace.errors.$key');
          await _failure(
            repository.loadJob(fixture.jobId, userId: fixture.customerId),
            'marketplace.errors.$key',
          );
        }
        for (final code in ['PGRST202', 'PGRST205', '42883', '42P01']) {
          backend.intercept = (_) =>
              _Reply.sqlError(_privateServerDetail, code: code);
          await _failure(
            repository.loadJob(fixture.jobId, userId: fixture.customerId),
            'errors.database_setup',
          );
        }
        for (final message in [
          'marketplace.errors.access $_privateServerDetail',
          'prefix marketplace.errors.access',
          'marketplace.errors.unknown',
          _privateServerDetail,
        ]) {
          backend.intercept = (_) =>
              _Reply.sqlError(message, code: 'XX000', status: 500);
          await _failure(
            repository.loadJob(fixture.jobId, userId: fixture.customerId),
            'marketplace.errors.load_failed',
          );
        }
        expect(auth.hasListeners, isFalse);
      },
    );

    test('every entry point rejects signed-out, foreign, recovery and failed mapped auth', () async {
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

    test('marketplace roles are guarded while job powers stay with immutable participants', () async {
      final quote = ProviderQuote.fromJson(fixture.quote());
      await _failure(
        repository.loadFeed(userId: fixture.customerId),
        'marketplace.errors.access',
      );
      await _failure(
        repository.loadProviderRequest(
          fixture.requestId,
          userId: fixture.customerId,
        ),
        'marketplace.errors.access',
      );
      await _failure(
        repository.loadMyQuotes(userId: fixture.customerId),
        'marketplace.errors.access',
      );
      await _failure(
        repository.saveQuote(fixture.draft(), userId: fixture.customerId),
        'marketplace.errors.access',
      );
      await _failure(
        repository.withdrawQuote(quote, userId: fixture.customerId),
        'marketplace.errors.access',
      );
      await actAs(fixture.provider);
      await _failure(
        repository.loadCustomerQuotes(
          fixture.requestId,
          userId: fixture.providerId,
        ),
        'marketplace.errors.access',
      );
      await _failure(
        repository.publishListing(
          fixture.requestId,
          userId: fixture.providerId,
          summary: fixture.summary,
          city: 'Cairo',
          consent: true,
        ),
        'marketplace.errors.access',
      );
      await _failure(
        repository.acceptQuote(
          quote,
          userId: fixture.providerId,
          consent: true,
        ),
        'marketplace.errors.access',
      );
      expect(backend.calls, isEmpty);
      await actAs(
        const AppUser(
          id: fixture.customerId,
          email: 'wrong-role@example.test',
          name: 'Wrong Role',
          role: UserRole.provider,
        ),
      );
      expect(
        await _success(
          repository.loadJob(fixture.jobId, userId: fixture.customerId),
        ),
        ServiceJob.fromJson(fixture.job()),
      );
      await _failure(
        repository.transitionJob(
          ServiceJob.fromJson(fixture.job()),
          JobStatus.inProgress,
          userId: fixture.customerId,
        ),
        'marketplace.errors.status',
      );
      expect(backend.rpcs, hasLength(1));
    });

    test('SDK identity must match before mapped auth or any RPC', () async {
      await backend.setSession(userId: fixture.otherId);
      await _allDenied(repository);
      expect(auth.checkCalls, 0);
      expect(backend.calls, isEmpty);
      await backend.setSession();
      await _allDenied(repository, userId: 'demo-customer');
      await _allDenied(repository, userId: '');
      expect(auth.checkCalls, 0);
      expect(backend.calls, isEmpty);
    });

    test('live missing client fails closed while explicit demo ignores an injected client', () async {
      final missing = MarketplaceRepository(authRepository: auth);
      expect(missing.isDemo, isFalse);
      await _allDenied(missing, key: 'errors.database_setup');
      expect(auth.checkCalls, 0);
      final demoAuth = _SessionAuth(demo: true);
      addTearDown(demoAuth.dispose);
      final m6 = ServiceRequestRepository(authRepository: demoAuth);
      final demo = MarketplaceRepository(
        authRepository: demoAuth,
        client: backend.client,
        demoStore: m6.demoStore,
      );
      await _success(
        m6.submitRequest(_requestDraft(), userId: fixture.customerId),
      );
      await _success(
        demo.publishListing(
          fixture.requestId,
          userId: fixture.customerId,
          summary: fixture.summary,
          city: 'Cairo',
          consent: true,
        ),
      );
      await _success(
        demo.loadCustomerQuotes(fixture.requestId, userId: fixture.customerId),
      );
      expect(demo.isDemo, isTrue);
      expect(backend.calls, isEmpty);
    });

    test('mapped stream is subscribed before the first auth await and logout cannot revive it', () async {
      final gate = Completer<Either<Failure, AuthSession>>();
      auth.checkOverride = () {
        expect(auth.hasListeners, isTrue);
        return gate.future;
      };
      final pending = repository.publishListing(
        fixture.requestId,
        userId: fixture.customerId,
        summary: fixture.summary,
        city: 'Cairo',
        consent: true,
      );
      auth.change(const AuthSession());
      auth.change(const AuthSession(user: fixture.customer));
      gate.complete(right(const AuthSession(user: fixture.customer)));
      await _failure(pending, 'marketplace.errors.access');
      expect(backend.calls, isEmpty);
      expect(auth.hasListeners, isFalse);
    });

    test(
      'raw SDK stream is subscribed before mapped auth can replace a session',
      () async {
        auth.checkOverride = () async {
          expect(auth.hasListeners, isTrue);
          await backend.setSession(userId: fixture.otherId);
          await backend.setSession();
          return right(const AuthSession(user: fixture.customer));
        };
        await _failure(
          repository.loadJobs(userId: fixture.customerId),
          'marketplace.errors.access',
        );
        expect(backend.calls, isEmpty);
        expect(auth.hasListeners, isFalse);
      },
    );

    test('replayed SDK recovery is denied even while mapped profile remains authenticated', () async {
      await backend.client.auth.verifyOTP(
        email: fixture.customer.email,
        token: '123456',
        type: OtpType.recovery,
      );
      backend.calls.clear();
      expect(auth.session, const AuthSession(user: fixture.customer));
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
        '$change invalidates in-flight acceptance without reconciliation or retry',
        () async {
          final started = Completer<void>();
          final response = Completer<_Reply?>();
          backend.intercept = (call) {
            if (!call.isRpc('accept_provider_quote')) return null;
            started.complete();
            return response.future;
          };
          final pending = _Mutation.accept.run(repository);
          await started.future;
          switch (change) {
            case 'mapped logout/return':
              auth.change(const AuthSession());
              auth.change(const AuthSession(user: fixture.customer));
            case 'mapped role change':
              auth.change(
                const AuthSession(
                  user: AppUser(
                    id: fixture.customerId,
                    email: 'role@example.test',
                    name: 'Role Changed',
                    role: UserRole.provider,
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
              await backend.setSession();
            case 'raw sign-in':
              await backend.client.auth.verifyOTP(
                email: fixture.customer.email,
                token: '123456',
                type: OtpType.email,
              );
            case 'raw recovery':
              await backend.client.auth.verifyOTP(
                email: fixture.customer.email,
                token: '123456',
                type: OtpType.recovery,
              );
          }
          response.complete(const _Reply.disconnected());
          await _failure(pending, 'marketplace.errors.access');
          expect(backend.rpcs, hasLength(1));
          expect(backend.rpc('get_customer_quotes'), isEmpty);
          expect(auth.hasListeners, isFalse);
        },
      );
    }

    test('ordinary token refresh permits canonical reconciliation with the refreshed bearer', () async {
      final started = Completer<void>();
      final response = Completer<_Reply?>();
      backend.intercept = (call) {
        if (call.isRpc('accept_provider_quote')) {
          started.complete();
          return response.future;
        }
        if (call.isRpc('get_customer_quotes')) {
          return _Reply.json(_Mutation.accept.reconciliation(committed: true));
        }
        return null;
      };
      final pending = _Mutation.accept.run(repository);
      await started.future;
      backend.refreshedToken = 'refreshed-test-token';
      await backend.client.auth.refreshSession();
      response.complete(const _Reply.disconnected());
      expect(await _success(pending), _Mutation.accept.decodedResult);
      expect(
        backend.rpc('accept_provider_quote').single.authorization,
        'Bearer test-token-${fixture.customerId}',
      );
      expect(
        backend.rpc('get_customer_quotes').single.authorization,
        'Bearer refreshed-test-token',
      );
      expect(auth.checkCalls, 1);
    });

    test(
      'duplicate writes cannot unlock or overlap another pending mutation',
      () async {
        await actAs(fixture.provider);
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (call) {
          if (!call.isRpc('save_provider_quote')) return null;
          started.complete();
          return response.future;
        };
        final pending = _Mutation.save.run(repository);
        await started.future;
        await _failure(
          _Mutation.save.run(repository),
          'marketplace.errors.busy',
        );
        await _failure(
          _Mutation.save.run(repository, changed: true),
          'marketplace.errors.busy',
        );
        await _failure(
          repository.saveQuote(
            fixture.draft(request: fixture.id(9)),
            userId: fixture.providerId,
          ),
          'marketplace.errors.busy',
        );
        await _failure(
          _Mutation.withdraw.run(repository),
          'marketplace.errors.busy',
        );
        await _failure(
          repository.retryPending(
            fixture.requestId,
            userId: fixture.providerId,
          ),
          'marketplace.errors.busy',
        );
        expect(backend.rpcs, hasLength(1));
        response.complete(null);
        await _success(pending);
        backend.intercept = null;
        await _success(_Mutation.withdraw.run(repository));
        expect(backend.rpc('withdraw_provider_quote'), hasLength(1));
        expect(auth.hasListeners, isFalse);
      },
    );

    test('accept reconciliation rejects a later revision even when price and notes match again', () async {
      backend.intercept = (call) {
        if (call.isRpc('accept_provider_quote')) {
          return const _Reply.disconnected();
        }
        return _Reply.json(
          fixture.book(
            status: ServiceRequestStatus.assigned,
            quotes: [fixture.quote(revision: 3, status: QuoteStatus.accepted)],
            serviceJob: fixture.job(quoteRevision: 3),
          ),
        );
      };
      await _failure(
        _Mutation.accept.run(repository),
        'marketplace.errors.conflict',
      );
      expect(
        repository.hasPendingOperation(
          fixture.requestId,
          userId: fixture.customerId,
        ),
        isFalse,
      );
      expect(backend.rpc('accept_provider_quote'), hasLength(1));
      expect(backend.rpc('get_customer_quotes'), hasLength(1));
    });

    test(
      'transition responses cannot silently replace frozen accepted terms',
      () async {
        await actAs(fixture.provider);
        final canonical = fixture.job(
          statuses: [JobStatus.selected, JobStatus.inProgress],
        );
        for (final (field, value) in <(String, Object?)>[
          ('request_id', fixture.id(800)),
          ('quote_id', fixture.id(801)),
          ('quote_revision', 2),
          ('provider_name', 'Changed Provider'),
          ('amount_minor', 99999),
          ('duration_minutes', 91),
          ('notes', 'Changed quote notes'),
          ('request_title', 'A different private title'),
          ('request_description', 'A different private description'),
          ('city', 'Giza'),
          ('address', 'Another private address'),
          ('preferred_at', '2026-11-10T12:00:00Z'),
          (
            'history',
            [
              {
                ...(canonical['history'] as List).first as Map<String, dynamic>,
                'id': fixture.id(802),
              },
              (canonical['history'] as List).last,
            ],
          ),
        ]) {
          backend.intercept = (_) => _Reply.json({...canonical, field: value});
          await _failure(
            _Mutation.transition.run(repository),
            'marketplace.errors.uncertain',
            reason: field,
          );
        }
        for (final changed in [
          fixture.job(
            customer: fixture.otherId,
            statuses: [JobStatus.selected, JobStatus.inProgress],
          ),
          fixture.job(
            createdAt: fixture.instant.subtract(const Duration(hours: 1)),
            statuses: [JobStatus.selected, JobStatus.inProgress],
          ),
        ]) {
          backend.intercept = (_) => _Reply.json(changed);
          await _failure(
            _Mutation.transition.run(repository),
            'marketplace.errors.uncertain',
          );
        }
        expect(
          repository.hasPendingOperation(
            fixture.jobId,
            userId: fixture.providerId,
          ),
          isTrue,
        );
        backend.intercept = null;
        expect(
          await _success(_Mutation.transition.run(repository)),
          _Mutation.transition.decodedResult,
        );
      },
    );

    test(
      'withdrawal cannot rewrite terms without changing the quote revision',
      () async {
        await actAs(fixture.provider);
        for (final (field, value) in <(String, Object?)>[
          ('amount_minor', 99999),
          ('duration_minutes', 91),
          ('notes', 'Changed notes'),
          ('provider_name', 'Changed Provider'),
          ('created_at', '2026-11-09T11:00:00Z'),
        ]) {
          final rewritten = {
            ...fixture.quote(status: QuoteStatus.withdrawn),
            field: value,
          };
          backend.intercept = (call) => call.isRpc('withdraw_provider_quote')
              ? _Reply.json(rewritten)
              : _Reply.json(fixture.opportunity(ownQuote: rewritten));
          await _failure(
            _Mutation.withdraw.run(repository),
            'marketplace.errors.uncertain',
            reason: field,
          );
        }
        expect(
          repository.hasPendingOperation(
            fixture.requestId,
            userId: fixture.providerId,
          ),
          isTrue,
        );
        backend.intercept = null;
        expect(
          await _success(_Mutation.withdraw.run(repository)),
          _Mutation.withdraw.decodedResult,
        );
      },
    );

    test('a private job response is discarded after SDK replacement even if mapping is stale', () async {
      final started = Completer<void>();
      final response = Completer<_Reply?>();
      backend.intercept = (call) {
        if (!call.isRpc('get_service_job')) return null;
        started.complete();
        return response.future;
      };
      final pending = repository.loadJob(
        fixture.jobId,
        userId: fixture.customerId,
      );
      await started.future;
      await backend.setSession(userId: fixture.otherId);
      expect(auth.session.user, fixture.customer);
      response.complete(_Reply.json(fixture.job()));
      await _failure(pending, 'marketplace.errors.access');
      expect(backend.rpcs, hasLength(1));
      expect(auth.hasListeners, isFalse);
    });

    test('retained job retry keeps its immutable participant role after profile-role changes', () async {
      await actAs(fixture.provider);
      backend.intercept = (call) => call.isRpc('transition_service_job')
          ? const _Reply.disconnected()
          : _Reply.json(fixture.job());
      await _failure(
        _Mutation.transition.run(repository),
        'marketplace.errors.uncertain',
      );
      await actAs(
        const AppUser(
          id: fixture.providerId,
          email: 'changed-role@example.test',
          name: 'Changed Role',
        ),
      );
      backend.intercept = (call) => call.isRpc('transition_service_job')
          ? const _Reply.disconnected()
          : _Reply.json(_Mutation.transition.result);
      await _success(
        repository.retryPending(fixture.jobId, userId: fixture.providerId),
      );
      expect(backend.rpc('transition_service_job'), hasLength(2));
      expect(
        backend.rpc('transition_service_job').last.json,
        _Mutation.transition.params,
      );
      expect(
        repository.hasPendingOperation(
          fixture.jobId,
          userId: fixture.providerId,
        ),
        isFalse,
      );
    });

    for (final operation in _Mutation.values) {
      test('${operation.name} serializes only exact RPC parameters', () async {
        await actAs(operation.actor);
        final result = await _success(operation.run(repository));
        expect(result, isNotNull);
        final call = backend.rpcs.single;
        expect(call.uri.path, '/rest/v1/rpc/${operation.rpc}');
        expect(call.json, operation.params);
        expect(call.authorization, 'Bearer test-token-${operation.actor.id}');
        expect(auth.checkCalls, 1);
        expect(auth.hasListeners, isFalse);
      });

      test(
        '${operation.name} conflicting canonical outcome is a failure, not successful reconciliation',
        () async {
          await actAs(operation.actor);
          final canonical = switch (operation) {
            _Mutation.publish => {
              ...fixture.book(),
              'listing': fixture.listing(
                text: 'A different published public summary.',
              ),
            },
            _Mutation.save => fixture.opportunity(
              ownQuote: fixture.quote(revision: 2, amount: 99999),
            ),
            _Mutation.withdraw => fixture.opportunity(
              ownQuote: fixture.quote(revision: 2),
            ),
            _Mutation.accept => fixture.book(
              status: ServiceRequestStatus.assigned,
              quotes: [
                fixture.quote(
                  id: fixture.id(999),
                  status: QuoteStatus.accepted,
                ),
              ],
              serviceJob: fixture.job(quote: fixture.id(999)),
            ),
            _Mutation.transition => fixture.job(
              statuses: [JobStatus.selected, JobStatus.cancelled],
            ),
          };
          backend.intercept = (call) => call.isRpc(operation.rpc)
              ? const _Reply.disconnected()
              : _Reply.json(canonical);
          await _failure(
            operation.run(repository),
            'marketplace.errors.conflict',
          );
          expect(
            repository.hasPendingOperation(
              operation.entityId,
              userId: operation.actor.id,
            ),
            isFalse,
          );
          expect(backend.rpc(operation.rpc), hasLength(1));
          expect(backend.rpc(operation.readRpc), hasLength(1));
        },
      );

      test(
        '${operation.name} definite first rejection clears pending without reconciliation',
        () async {
          await actAs(operation.actor);
          for (final (code, message, expected) in [
            (
              'P0001',
              'marketplace.errors.conflict',
              'marketplace.errors.conflict',
            ),
            ('PGRST202', _privateServerDetail, 'errors.database_setup'),
          ]) {
            backend.intercept = (_) => _Reply.sqlError(message, code: code);
            await _failure(operation.run(repository), expected);
            expect(
              repository.hasPendingOperation(
                operation.entityId,
                userId: operation.actor.id,
              ),
              isFalse,
            );
          }
          expect(backend.rpc(operation.readRpc), isEmpty);
          backend.intercept = (_) =>
              _Reply.sqlError('marketplace.errors.status');
          await _failure(
            operation.run(repository, changed: true),
            'marketplace.errors.status',
          );
        },
      );

      test(
        '${operation.name} retained original retry survives page loss and same-account relogin',
        () async {
          await actAs(operation.actor);
          backend.intercept = (call) => call.isRpc(operation.rpc)
              ? const _Reply.disconnected()
              : _Reply.json(operation.reconciliation(committed: false));
          await _failure(
            operation.run(repository),
            'marketplace.errors.uncertain',
          );
          expect(
            repository.hasPendingOperation(
              operation.entityId,
              userId: operation.actor.id,
            ),
            isTrue,
          );
          expect(
            repository.hasPendingOperation(
              operation.entityId,
              userId: fixture.otherId,
            ),
            isFalse,
          );
          final restarted = MarketplaceRepository(
            authRepository: auth,
            client: backend.client,
          );
          expect(
            restarted.hasPendingOperation(
              operation.entityId,
              userId: operation.actor.id,
            ),
            isFalse,
          );
          await _success(
            restarted.retryPending(
              operation.entityId,
              userId: operation.actor.id,
            ),
          );
          auth.change(const AuthSession());
          await _failure(
            repository.retryPending(
              operation.entityId,
              userId: operation.actor.id,
            ),
            'marketplace.errors.access',
          );
          await actAs(fixture.otherCustomer);
          await _failure(
            repository.retryPending(
              operation.entityId,
              userId: operation.actor.id,
            ),
            'marketplace.errors.access',
          );
          await _success(
            repository.retryPending(
              operation.entityId,
              userId: fixture.otherId,
            ),
          );
          expect(backend.rpc(operation.rpc), hasLength(1));
          await actAs(operation.actor);
          if (operation == _Mutation.save) {
            await _failure(
              _Mutation.withdraw.run(repository),
              'marketplace.errors.uncertain',
            );
          }
          if (operation == _Mutation.accept) {
            await _failure(
              _Mutation.publish.run(repository),
              'marketplace.errors.uncertain',
            );
          }
          await _failure(
            operation.run(repository, changed: true),
            'marketplace.errors.uncertain',
          );
          backend.intercept = (call) => call.isRpc(operation.rpc)
              ? const _Reply.disconnected()
              : _Reply.json(operation.reconciliation(committed: true));
          await _success(
            repository.retryPending(
              operation.entityId,
              userId: operation.actor.id,
            ),
          );
          expect(backend.rpc(operation.rpc), hasLength(2));
          expect(backend.rpc(operation.rpc).last.json, operation.params);
          expect(
            repository.hasPendingOperation(
              operation.entityId,
              userId: operation.actor.id,
            ),
            isFalse,
          );
        },
      );

      for (final malformed in [false, true]) {
        test(
          '${operation.name} reconciles ${malformed ? 'malformed' : 'lost'} committed response without rewriting',
          () async {
            await actAs(operation.actor);
            backend.intercept = (call) {
              if (call.isRpc(operation.rpc)) {
                return malformed
                    ? const _Reply.json({'unexpected': _privateServerDetail})
                    : const _Reply.disconnected();
              }
              if (call.isRpc(operation.readRpc)) {
                return _Reply.json(operation.reconciliation(committed: true));
              }
              return null;
            };
            final value = await _success(operation.run(repository));
            expect(value, operation.decodedResult);
            expect(backend.rpc(operation.rpc), hasLength(1));
            expect(backend.rpc(operation.readRpc), hasLength(1));
            expect(auth.checkCalls, 1);
            expect(auth.hasListeners, isFalse);
          },
        );
      }

      test(
        '${operation.name} uncertainty survives unavailable reads and blocks changed exact-entity retries',
        () async {
          await actAs(operation.actor);
          backend.intercept = (call) {
            if (call.isRpc(operation.rpc)) return const _Reply.disconnected();
            if (call.isRpc(operation.readRpc)) {
              return _Reply.json(operation.reconciliation(committed: false));
            }
            return null;
          };
          await _failure(
            operation.run(repository),
            'marketplace.errors.uncertain',
          );
          final initialCalls = backend.calls.length;
          await _failure(
            operation.run(repository, changed: true),
            'marketplace.errors.uncertain',
          );
          expect(backend.calls, hasLength(initialCalls));
          backend.intercept = (call) => call.isRpc(operation.rpc)
              ? const _Reply.disconnected()
              : _Reply.sqlError(_privateServerDetail, status: 503);
          await _failure(
            operation.run(repository),
            'marketplace.errors.uncertain',
          );
          final unavailableCalls = backend.calls.length;
          await _failure(
            operation.run(repository, changed: true),
            'marketplace.errors.uncertain',
          );
          expect(backend.calls, hasLength(unavailableCalls));
          backend.intercept = (call) => call.isRpc(operation.rpc)
              ? _Reply.sqlError('marketplace.errors.conflict')
              : _Reply.json(operation.reconciliation(committed: false));
          await _failure(
            operation.run(repository),
            'marketplace.errors.uncertain',
          );
          backend.intercept = null;
          expect(
            await _success(operation.run(repository)),
            operation.decodedResult,
          );
          expect(backend.rpc(operation.rpc), hasLength(4));
          backend.intercept = (_) =>
              _Reply.sqlError('marketplace.errors.status');
          await _failure(
            operation.run(repository, changed: true),
            'marketplace.errors.status',
          );
        },
      );
    }
  });
}

ServiceRequestDraft _requestDraft({
  String id = fixture.requestId,
  String category = 'demo-plumbing',
}) => ServiceRequestDraft(
  id: id,
  categoryId: category,
  title: fixture.privateTitle,
  description: fixture.privateDescription,
  city: 'Private district',
  address: fixture.privateAddress,
  consent: true,
);

DemoMarketplaceProvider _eligibleProvider({
  bool verified = true,
  List<String> skills = const ['demo-plumbing'],
  List<String> areas = const ['Cairo'],
}) => DemoMarketplaceProvider(
  skillIds: skills,
  serviceAreas: areas,
  verified: verified,
);

Future<T> _success<T>(FutureEither<T> task) async =>
    (await task).fold((failure) => fail(failure.message), (value) => value);

Future<Failure> _failure<T>(
  FutureEither<T> task,
  String key, {
  String? reason,
}) async {
  final failure = (await task).fold(
    (failure) => failure,
    (_) => fail('Expected $key${reason == null ? '' : ' ($reason)'}'),
  );
  expect(failure.message, key, reason: reason);
  expect(failure.error, isNull);
  expect(failure.toString(), isNot(contains(_privateServerDetail)));
  return failure;
}

Future<List<T>> _allPages<T>(
  FutureEither<MarketplacePage<T>> Function(MarketplaceCursor?) load,
  MarketplaceCursor Function(T) cursor,
) async {
  final items = <T>[];
  MarketplaceCursor? before;
  for (var pageNumber = 0; pageNumber < 10; pageNumber++) {
    final page = await _success(load(before));
    expect(page.items.length, lessThanOrEqualTo(2));
    items.addAll(page.items);
    if (!page.hasMore) {
      if (page.items.isNotEmpty) {
        expect((await _success(load(cursor(page.items.last)))).items, isEmpty);
      }
      expect(items.map(cursor).toSet(), hasLength(items.length));
      return items;
    }
    expect(page.items, hasLength(2));
    before = cursor(page.items.last);
  }
  fail('Keyset did not advance.');
}

enum _Mutation {
  publish,
  save,
  withdraw,
  accept,
  transition;

  String get entityId => this == transition ? fixture.jobId : fixture.requestId;

  AppUser get actor => switch (this) {
    publish || accept => fixture.customer,
    _ => fixture.provider,
  };
  String get rpc => switch (this) {
    publish => 'publish_request_listing',
    save => 'save_provider_quote',
    withdraw => 'withdraw_provider_quote',
    accept => 'accept_provider_quote',
    transition => 'transition_service_job',
  };
  String get readRpc => switch (this) {
    publish || accept => 'get_customer_quotes',
    save || withdraw => 'get_provider_request',
    transition => 'get_service_job',
  };
  Map<String, Object?> get params => switch (this) {
    publish => {
      'p_request_id': fixture.requestId,
      'p_summary': fixture.summary,
      'p_city': 'Cairo',
      'p_consent': true,
    },
    save => {
      'p_request_id': fixture.requestId,
      'p_amount_minor': 12345,
      'p_currency': 'EGP',
      'p_duration_minutes': 90,
      'p_notes': fixture.notes,
      'p_expected_revision': 0,
    },
    withdraw => {'p_quote_id': fixture.quoteId, 'p_expected_revision': 1},
    accept => {
      'p_quote_id': fixture.quoteId,
      'p_expected_revision': 1,
      'p_consent': true,
    },
    transition => {
      'p_job_id': fixture.jobId,
      'p_expected_status': 'selected',
      'p_status': 'in_progress',
    },
  };
  Map<String, dynamic> get result => switch (this) {
    publish => fixture.listing(),
    save => fixture.quote(),
    withdraw => fixture.quote(status: QuoteStatus.withdrawn),
    accept => fixture.job(),
    transition => fixture.job(
      statuses: [JobStatus.selected, JobStatus.inProgress],
    ),
  };
  Object get decodedResult => switch (this) {
    publish => MarketplaceListing.fromJson(result),
    save || withdraw => ProviderQuote.fromJson(result),
    accept || transition => ServiceJob.fromJson(result),
  };
  Map<String, dynamic> reconciliation({required bool committed}) =>
      switch (this) {
        publish => fixture.book(published: committed),
        save => fixture.opportunity(ownQuote: committed ? result : null),
        withdraw => fixture.opportunity(
          ownQuote: committed ? result : fixture.quote(),
        ),
        accept => fixture.book(
          status: committed
              ? ServiceRequestStatus.assigned
              : ServiceRequestStatus.open,
          quotes: [
            fixture.quote(
              status: committed ? QuoteStatus.accepted : QuoteStatus.pending,
            ),
          ],
          serviceJob: committed ? result : null,
        ),
        transition => committed ? result : fixture.job(),
      };
  FutureEither<Object> run(
    MarketplaceRepository repository, {
    bool changed = false,
  }) => switch (this) {
    publish => repository.publishListing(
      fixture.requestId,
      userId: actor.id,
      summary: changed
          ? 'Different public summary for this request.'
          : fixture.summary,
      city: 'Cairo',
      consent: true,
    ),
    save => repository.saveQuote(
      fixture.draft().copyWith(amount: changed ? '124.45' : '123.45'),
      userId: actor.id,
    ),
    withdraw => repository.withdrawQuote(
      ProviderQuote.fromJson(fixture.quote(revision: changed ? 2 : 1)),
      userId: actor.id,
    ),
    accept => repository.acceptQuote(
      ProviderQuote.fromJson(fixture.quote(revision: changed ? 2 : 1)),
      userId: actor.id,
      consent: true,
    ),
    transition => repository.transitionJob(
      ServiceJob.fromJson(fixture.job()),
      changed ? JobStatus.onTheWay : JobStatus.inProgress,
      userId: actor.id,
    ),
  };
}

enum _PageRead {
  feed,
  providerQuotes,
  customerQuotes,
  jobs;

  AppUser get actor => this == feed || this == providerQuotes
      ? fixture.provider
      : fixture.customer;
  String get rpc => switch (this) {
    feed => 'get_marketplace_feed',
    providerQuotes => 'get_provider_quotes',
    customerQuotes => 'get_customer_quotes',
    jobs => 'get_service_jobs',
  };
  FutureEither<Object> run(
    MarketplaceRepository repository, {
    MarketplaceCursor? before,
    int limit = 20,
  }) => switch (this) {
    feed => repository.loadFeed(userId: actor.id, before: before, limit: limit),
    providerQuotes => repository.loadMyQuotes(
      userId: actor.id,
      before: before,
      limit: limit,
    ),
    customerQuotes => repository.loadCustomerQuotes(
      fixture.requestId,
      userId: actor.id,
      before: before,
      limit: limit,
    ),
    jobs => repository.loadJobs(userId: actor.id, before: before, limit: limit),
  };
  Map<String, dynamic> response({required int count, required bool hasMore}) {
    final rows = List.generate(
      count,
      (index) => switch (this) {
        feed => fixture.listing(request: fixture.id(index)),
        providerQuotes => fixture.opportunity(
          request: fixture.id(index),
          ownQuote: fixture.quote(
            id: fixture.id(index),
            request: fixture.id(index),
          ),
        ),
        customerQuotes => fixture.quote(
          id: fixture.id(index),
          provider: fixture.id(1000 + index),
        ),
        jobs => fixture.job(id: fixture.id(index)),
      },
    );
    return this == customerQuotes
        ? fixture.book(quotes: rows, hasMore: hasMore)
        : {
            'items': rows,
            'has_more': hasMore,
            if (this == feed) 'eligible': true,
          };
  }
}

Future<void> _allDenied(
  MarketplaceRepository repository, {
  String userId = fixture.customerId,
  String key = 'marketplace.errors.access',
}) async {
  final quote = ProviderQuote.fromJson(fixture.quote());
  final job = ServiceJob.fromJson(fixture.job());
  for (final task in <FutureEither<Object?> Function()>[
    () => repository.loadFeed(userId: userId),
    () => repository.loadProviderRequest(fixture.requestId, userId: userId),
    () => repository.loadMyQuotes(userId: userId),
    () => repository.loadCustomerQuotes(fixture.requestId, userId: userId),
    () => repository.publishListing(
      fixture.requestId,
      userId: userId,
      summary: fixture.summary,
      city: 'Cairo',
      consent: true,
    ),
    () => repository.saveQuote(fixture.draft(), userId: userId),
    () => repository.withdrawQuote(quote, userId: userId),
    () => repository.acceptQuote(quote, userId: userId, consent: true),
    () => repository.loadJobs(userId: userId),
    () => repository.loadJob(fixture.jobId, userId: userId),
    () => repository.transitionJob(job, JobStatus.cancelled, userId: userId),
    () => repository.retryPending(fixture.requestId, userId: userId),
  ]) {
    await _failure(task(), key);
  }
}

class _SessionAuth extends DemoAuthRepository {
  _SessionAuth({required this.demo});
  final bool demo;
  AuthSession session = const AuthSession(user: fixture.customer);
  final _events = StreamController<AuthSession>.broadcast(sync: true);
  FutureEither<AuthSession> Function()? checkOverride;
  int checkCalls = 0;
  bool get hasListeners => _events.hasListener;
  @override
  bool get isDemo => demo;
  @override
  Stream<AuthSession> get onAuthStateChanged => _events.stream;
  void change(AuthSession next) {
    session = next;
    _events.add(next);
  }

  void streamError() => _events.addError(StateError(_privateServerDetail));
  Future<void> closeEvents() => _events.close();
  @override
  FutureEither<AuthSession> checkAuthState() async {
    checkCalls++;
    return checkOverride == null ? right(session) : await checkOverride!();
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await super.dispose();
  }
}

// Real Supabase serialization/auth over loopback; no table or Storage fallback.
class _Backend {
  _Backend(this.server) {
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    server.listen((request) => unawaited(_handle(request)));
  }
  final HttpServer server;
  late final SupabaseClient client;
  final calls = <_Call>[];
  final unexpected = <String>[];
  FutureOr<_Reply?> Function(_Call)? intercept;
  String? refreshedToken;
  Iterable<_Call> get rpcs =>
      calls.where((call) => call.uri.path.startsWith('/rest/v1/rpc/'));
  Iterable<_Call> rpc(String name) => calls.where((call) => call.isRpc(name));
  static Future<_Backend> start() async {
    final backend = _Backend(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    await backend.setSession();
    return backend;
  }

  Map<String, Object?> sessionJson({String userId = fixture.customerId}) => {
    'access_token': refreshedToken ?? 'test-token-$userId',
    'refresh_token': 'test-refresh-token',
    'token_type': 'bearer',
    'user': {
      'id': userId,
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
      'aud': 'authenticated',
      'created_at': '2026-11-09T00:00:00Z',
    },
  };
  Future<void> setSession({String userId = fixture.customerId}) =>
      client.auth.setInitialSession(jsonEncode(sessionJson(userId: userId)));
  Future<void> _handle(HttpRequest incoming) async {
    final body = await utf8.decoder.bind(incoming).join();
    final call = _Call(
      incoming.method,
      incoming.uri,
      body.isEmpty ? {} : jsonDecode(body) as Map<String, dynamic>,
      incoming.headers.value(HttpHeaders.authorizationHeader),
    );
    calls.add(call);
    final reply = await intercept?.call(call) ?? respond(call);
    if (reply.disconnect) {
      final socket = await incoming.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    incoming.response.statusCode = reply.status;
    incoming.response.headers.contentType = ContentType.json;
    incoming.response.add(utf8.encode(jsonEncode(reply.body)));
    await incoming.response.close();
  }

  _Reply respond(_Call call) {
    if (call.uri.path == '/auth/v1/verify' ||
        call.uri.path == '/auth/v1/token') {
      return _Reply.json(sessionJson(userId: client.auth.currentUser!.id));
    }
    if (call.uri.path == '/auth/v1/logout') return const _Reply.json({});
    for (final operation in _Mutation.values) {
      if (call.isRpc(operation.rpc)) return _Reply.json(operation.result);
    }
    if (call.isRpc('get_marketplace_feed')) {
      return _Reply.json({
        'items': [fixture.listing()],
        'has_more': false,
        'eligible': true,
      });
    }
    if (call.isRpc('get_provider_request')) {
      return _Reply.json(fixture.opportunity(ownQuote: fixture.quote()));
    }
    if (call.isRpc('get_provider_quotes')) {
      return _Reply.json({
        'items': [fixture.opportunity(ownQuote: fixture.quote())],
        'has_more': false,
      });
    }
    if (call.isRpc('get_customer_quotes')) {
      return _Reply.json(fixture.book(quotes: [fixture.quote()]));
    }
    if (call.isRpc('get_service_job')) return _Reply.json(fixture.job());
    if (call.isRpc('get_service_jobs')) {
      return _Reply.json({
        'items': [fixture.job()],
        'has_more': false,
      });
    }
    unexpected.add('${call.method} ${call.uri}');
    return _Reply.sqlError('Unexpected test endpoint');
  }

  Future<void> close() async {
    await client.dispose();
    await server.close(force: true);
  }
}

class _Call {
  const _Call(this.method, this.uri, this.json, this.authorization);
  final String method;
  final Uri uri;
  final Map<String, dynamic> json;
  final String? authorization;
  bool isRpc(String name) => uri.path == '/rest/v1/rpc/$name';
}

class _Reply {
  const _Reply.json(this.body, {this.status = 200}) : disconnect = false;
  const _Reply.disconnected() : body = null, status = 200, disconnect = true;
  factory _Reply.sqlError(
    String message, {
    String code = 'P0001',
    int status = 400,
  }) => _Reply.json({
    'code': code,
    'message': message,
    'details': _privateServerDetail,
    'hint': _privateServerDetail,
  }, status: status);
  final Object? body;
  final int status;
  final bool disconnect;
}
