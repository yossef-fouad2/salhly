import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/marketplace.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';
import 'package:salahly/src/ui/marketplace/customer_quotes_cubit.dart';
import 'package:salahly/src/ui/marketplace/job_detail_cubit.dart';
import 'package:salahly/src/ui/marketplace/jobs_cubit.dart';
import 'package:salahly/src/ui/marketplace/provider_browse_cubit.dart';
import 'package:salahly/src/ui/marketplace/provider_quote_cubit.dart';
import 'package:salahly/src/utils/failure.dart';

import 'marketplace_ui_fakes.dart';

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

void main() {
  group('customer quotes', () {
    late MarketplaceUiRepository repository;
    late CustomerQuotesCubit cubit;
    late DemoAuthRepository auth;
    late SessionBloc session;
    setUp(() async {
      auth = DemoAuthRepository();
      session = await _session(auth);
      repository = MarketplaceUiRepository(auth);
      cubit = CustomerQuotesCubit(
        userId: uiCustomerId,
        requestId: uiRequestId,
        repository: repository,
        session: session,
      );
      addTearDown(cubit.close);
      await cubit.refresh();
    });

    test(
      'publication starts blank, validates length and requires fresh consent',
      () async {
        expect(cubit.state.summary, isEmpty);
        expect(cubit.state.city, isEmpty);
        await cubit.publish();
        expect(cubit.state.errorMessage, 'marketplace.errors.summary');
        cubit.updateSummary(
          'A new public summary without private identifiers.',
        );
        cubit.updateCity('C');
        await cubit.publish();
        expect(cubit.state.errorMessage, 'marketplace.errors.city');
        cubit.updateCity(' Cairo ');
        await cubit.publish();
        expect(cubit.state.errorMessage, 'marketplace.errors.consent');
        cubit.setConsent(true);
        cubit.updateSummary(
          'A second new public summary without private identifiers.',
        );
        expect(cubit.state.consent, isFalse);
        expect(repository.publications, isEmpty);
        cubit.setConsent(true);
        await cubit.publish();
        expect(repository.publications.single.city, 'Cairo');
        expect(repository.publications.single.consent, isTrue);
        expect(
          cubit.state.book!.listing!.summary,
          repository.publications.single.summary,
        );
        expect(cubit.state.hasUnsavedChanges, isFalse);
        expect(cubit.state.canPublish, isFalse);
      },
    );

    test(
      'uncertain publish keeps exact snapshot across another network error',
      () async {
        cubit.updateSummary('A separate public summary for quotes.');
        cubit.updateCity('Cairo');
        cubit.setConsent(true);
        repository.mutationFailure = const ServerFailure(
          'marketplace.errors.uncertain',
        );
        await cubit.publish();
        cubit.updateCity('Alexandria');
        cubit.setConsent(false);
        await cubit.publish();
        expect(repository.publications, hasLength(1));
        repository.mutationFailure = const NetworkFailure('errors.network');
        await cubit.retryPending();
        expect(cubit.state.uncertain, isTrue);
        expect(cubit.state.city, 'Cairo');
        expect(cubit.state.canPublish, isFalse);
        repository.mutationFailure = null;
        await cubit.retryPending();
        expect(repository.publications.toSet(), hasLength(1));
        expect(cubit.state.uncertain, isFalse);
      },
    );

    test(
      'acceptance serializes and never switches quotes during uncertainty',
      () async {
        final first = uiQuote();
        final other = uiQuote(
          id: '123e4567-e89b-42d3-a456-426614174202',
          providerId: 'another-provider',
        );
        repository.book = uiBook(quotes: [first, other]);
        await cubit.refresh();
        await cubit.accept(first, consent: false);
        expect(repository.acceptances, isEmpty);
        repository.pendingAccept = Completer();
        final accepting = cubit.accept(first, consent: true);
        await cubit.accept(other, consent: true);
        expect(repository.acceptances, hasLength(1));
        expect(cubit.state.book!.job, isNull);
        repository.pendingAccept!.complete(
          left(const ServerFailure('marketplace.errors.uncertain')),
        );
        await accepting;
        await cubit.accept(other, consent: true);
        await cubit.refresh();
        expect(repository.acceptances, hasLength(1));
        repository.pendingAccept = null;
        await cubit.retryPending();
        expect(repository.acceptances.last.quote, same(first));
        expect(repository.acceptances.last.consent, isTrue);
        expect(cubit.state.book!.job!.id, uiJobId);
        expect(cubit.state.book!.requestStatus, ServiceRequestStatus.assigned);
        expect(cubit.state.canAccept, isFalse);
      },
    );

    test('stale acceptance failure does not claim success or silently accept new terms', () async {
      final quote = uiQuote();
      repository.book = uiBook(quotes: [quote]);
      await cubit.refresh();
      repository.mutationFailure = const ServerFailure(
        'marketplace.errors.conflict',
      );
      await cubit.accept(quote, consent: true);
      expect(cubit.state.book!.job, isNull);
      expect(cubit.state.notice, isNull);
      expect(cubit.state.errorMessage, 'marketplace.errors.conflict');
      expect(repository.acceptances.single.quote.revision, 1);
      repository.book = uiBook(
        quotes: [uiQuote(revision: 2, amountMinor: 35000)],
      );
      await cubit.refresh();
      await cubit.accept(quote, consent: true);
      expect(repository.acceptances, hasLength(1));
    });

    test('read errors retain loaded quotes, but access errors erase them and drafts', () async {
      repository.book = uiBook(quotes: [uiQuote()]);
      await cubit.refresh();
      repository.readFailure = const NetworkFailure('errors.network');
      await cubit.refresh();
      expect(cubit.state.book!.quotes, hasLength(1));
      repository.readFailure = const ServerFailure('marketplace.errors.access');
      await cubit.refresh();
      expect(cubit.state.book, isNull);
      expect(cubit.state.revoked, isTrue);
      expect(cubit.state.summary, isEmpty);
    });

    test(
      'a rebuilt page recovers the repository-retained original acceptance',
      () async {
        repository.storedPending = true;
        await cubit.refresh();
        expect(cubit.state.uncertain, isTrue);
        expect(cubit.state.canPublish, isFalse);
        repository.book = uiBook(job: uiJob());
        await cubit.retryPending();
        expect(repository.storedRetries, 1);
        expect(cubit.state.book!.job!.id, uiJobId);
        expect(cubit.state.uncertain, isFalse);
      },
    );
  });

  group('provider quotes', () {
    late MarketplaceUiRepository repository;
    late ProviderQuoteCubit cubit;
    late SessionBloc session;
    late DemoAuthRepository auth;
    setUp(() async {
      auth = DemoAuthRepository();
      session = await _session(auth, provider: true);
      repository = MarketplaceUiRepository(auth);
      cubit = ProviderQuoteCubit(
        userId: uiProviderId,
        requestId: uiRequestId,
        repository: repository,
        session: session,
      );
      addTearDown(cubit.close);
      await cubit.load();
    });

    test('Arabic digits validate and pending-save locks the exact draft and revision', () async {
      cubit.updateAmount('١٢٥٫٥٠');
      cubit.updateDuration('٩٠');
      cubit.updateNotes('Sample terms');
      final original = cubit.state.draft;
      repository.pendingSave = Completer();
      final saving = cubit.save();
      cubit.updateAmount('999');
      await cubit.save();
      await cubit.load();
      expect(repository.drafts, hasLength(1));
      expect(repository.drafts.single, same(original));
      expect(original.amountMinor, 12550);
      repository.pendingSave!.complete(right(uiQuote()));
      await saving;
      expect(cubit.state.draft.expectedRevision, 1);
      expect(cubit.state.hasUnsavedChanges, isFalse);
    });

    test('invalid amount and duration never reach the repository', () async {
      cubit.updateAmount('1e3');
      cubit.updateDuration('90');
      await cubit.save();
      expect(cubit.state.errorMessage, 'marketplace.errors.amount');
      cubit.updateAmount('100');
      cubit.updateDuration('1.5');
      await cubit.save();
      expect(cubit.state.errorMessage, 'marketplace.errors.duration');
      cubit.updateDuration('90');
      cubit.updateNotes('x' * 1001);
      await cubit.save();
      expect(cubit.state.errorMessage, 'marketplace.errors.notes');
      expect(repository.drafts, isEmpty);
    });

    test('withdraw uncertainty blocks editing and reactivation until same quote resolves', () async {
      final quote = uiQuote(revision: 3);
      repository.quote = quote;
      await cubit.load();
      repository.mutationFailure = const ServerFailure(
        'marketplace.errors.uncertain',
      );
      await cubit.withdraw();
      cubit.updateNotes('Changed');
      await cubit.save();
      await cubit.withdraw();
      expect(repository.withdrawals, [quote]);
      expect(repository.drafts, isEmpty);
      repository.mutationFailure = const NetworkFailure('errors.network');
      await cubit.retryPending();
      expect(cubit.state.canEdit, isFalse);
      repository.mutationFailure = null;
      await cubit.retryPending();
      expect(
        repository.withdrawals.every((value) => identical(value, quote)),
        isTrue,
      );
      expect(cubit.state.opportunity!.quote!.status, QuoteStatus.withdrawn);
      expect(cubit.state.canEdit, isTrue);
      await cubit.save();
      expect(repository.drafts.single.expectedRevision, 3);
      expect(cubit.state.opportunity!.quote!.status, QuoteStatus.pending);
    });

    test('definite conflict resolves an uncertain attempt without optimistic success', () async {
      cubit.updateAmount('150');
      cubit.updateDuration('60');
      repository.mutationFailure = const ServerFailure(
        'marketplace.errors.uncertain',
      );
      await cubit.save();
      repository.mutationFailure = const ServerFailure(
        'marketplace.errors.conflict',
      );
      await cubit.retryPending();
      expect(cubit.state.uncertain, isFalse);
      expect(cubit.state.notice, isNull);
      expect(cubit.state.opportunity!.quote, isNull);
      expect(cubit.state.errorMessage, 'marketplace.errors.conflict');
    });

    test('accepted terms cannot be edited or withdrawn', () async {
      repository.quote = uiQuote().copyWith(status: QuoteStatus.accepted);
      repository.listing = repository.listing.withStatus(
        ServiceRequestStatus.assigned,
      );
      repository.eligible = false;
      await cubit.load();
      cubit.updateAmount('1000');
      await cubit.save();
      await cubit.withdraw();
      expect(cubit.state.canEdit, isFalse);
      expect(cubit.state.canWithdraw, isFalse);
      expect(repository.drafts, isEmpty);
      expect(repository.withdrawals, isEmpty);
    });

    test(
      'same-user logout and relogin permanently rejects a late save result',
      () async {
        cubit.updateAmount('100');
        cubit.updateDuration('60');
        repository.pendingSave = Completer();
        final saving = cubit.save();
        final loggedOut = session.stream.firstWhere(
          (s) => s.status == SessionStatus.unauthenticated,
        );
        await auth.logout();
        await loggedOut;
        final loggedIn = session.stream.firstWhere(
          (s) => s.status == SessionStatus.authenticated,
        );
        await auth.login(
          email: DemoAuthRepository.marketplaceProviderEmail,
          password: DemoAuthRepository.demoPassword,
        );
        await loggedIn;
        repository.pendingSave!.complete(right(uiQuote()));
        await saving;
        expect(cubit.state.revoked, isTrue);
        expect(cubit.state.opportunity, isNull);
        expect(cubit.state.draft.amount, isEmpty);
        await cubit.load();
        expect(repository.quoteLoads, 1);
      },
    );
  });

  test('feed appends by cursor, serializes loads and retains results on refresh failure', () async {
    final auth = DemoAuthRepository();
    final session = await _session(auth, provider: true);
    final first = uiListing();
    final second = uiListing(requestId: '123e4567-e89b-42d3-a456-426614174201');
    final repository = MarketplaceUiRepository(auth)
      ..feed = MarketplacePage(items: [first], hasMore: true);
    final cubit = ProviderBrowseCubit(
      userId: uiProviderId,
      myQuotes: false,
      repository: repository,
      session: session,
    );
    addTearDown(cubit.close);
    await cubit.refresh();
    repository.pendingFeed = Completer();
    final loading = cubit.loadMore();
    await cubit.refresh();
    await cubit.loadMore();
    expect(repository.feedLoads, 2);
    expect(repository.lastCursor, first.cursor);
    repository.pendingFeed!.complete(
      right(MarketplacePage(items: [first, second], hasMore: false)),
    );
    await loading;
    expect(cubit.state.items.map((item) => item.listing), [first, second]);
    repository.pendingFeed = null;
    repository.readFailure = const NetworkFailure('errors.network');
    await cubit.refresh();
    expect(cubit.state.items, hasLength(2));
    repository.readFailure = const ServerFailure('marketplace.errors.access');
    await cubit.refresh();
    expect(cubit.state.items, isEmpty);
  });

  test('job transition retries preserve the original job/status and no optimistic history', () async {
    final auth = DemoAuthRepository();
    final session = await _session(auth, provider: true);
    final repository = MarketplaceUiRepository(auth)
      ..pendingTransition = Completer();
    final cubit = JobDetailCubit(
      userId: uiProviderId,
      jobId: uiJobId,
      repository: repository,
      session: session,
    );
    addTearDown(cubit.close);
    await cubit.load();
    final original = cubit.state.job;
    final work = cubit.transition(JobStatus.inProgress);
    await cubit.transition(JobStatus.onTheWay);
    expect(repository.transitions, hasLength(1));
    expect(cubit.state.job!.status, JobStatus.selected);
    expect(cubit.state.job!.history, hasLength(1));
    repository.pendingTransition!.complete(
      left(const ServerFailure('marketplace.errors.uncertain')),
    );
    await work;
    await cubit.transition(JobStatus.cancelled);
    repository.pendingTransition = null;
    await cubit.retryPending();
    expect(repository.transitions.last.job, same(original));
    expect(repository.transitions.last.target, JobStatus.inProgress);
    expect(cubit.state.job!.status, JobStatus.inProgress);
    expect(cubit.state.actions, [JobStatus.awaitingConfirmation]);
  });

  test(
    'only the immutable customer participant can confirm job completion',
    () async {
      final auth = DemoAuthRepository();
      final session = await _session(auth, provider: true);
      final repository = MarketplaceUiRepository(auth)
        ..job = uiJob(status: JobStatus.awaitingConfirmation);
      final provider = JobDetailCubit(
        userId: uiProviderId,
        jobId: uiJobId,
        repository: repository,
        session: session,
      );
      addTearDown(provider.close);
      await provider.load();
      expect(provider.state.actions, isEmpty);
      await provider.transition(JobStatus.completed);
      expect(repository.transitions, isEmpty);

      final changed = session.stream.firstWhere(
        (state) => state.user?.id == uiCustomerId,
      );
      session.add(
        const SessionUserChanged(
          AuthSession(
            user: AppUser(
              id: uiCustomerId,
              email: 'customer@salahly.demo',
              name: 'Customer with changed profile role',
              role: UserRole.provider,
            ),
          ),
        ),
      );
      await changed;
      final customer = JobDetailCubit(
        userId: uiCustomerId,
        jobId: uiJobId,
        repository: repository,
        session: session,
      );
      addTearDown(customer.close);
      await customer.load();
      expect(customer.state.role, UserRole.customer);
      expect(customer.state.actions, [JobStatus.completed]);
      await customer.transition(JobStatus.completed);
      expect(customer.state.job!.status, JobStatus.completed);
      expect(customer.state.actions, isEmpty);
    },
  );

  test(
    'job addresses and late refresh are revoked on account replacement',
    () async {
      final auth = DemoAuthRepository();
      final session = await _session(auth);
      final repository = MarketplaceUiRepository(auth);
      final cubit = JobDetailCubit(
        userId: uiCustomerId,
        jobId: uiJobId,
        repository: repository,
        session: session,
      );
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.job!.address, contains('Private building'));
      repository.pendingJob = Completer();
      final refreshing = cubit.load();
      final replaced = session.stream.firstWhere(
        (s) => s.user?.id == 'demo-provider',
      );
      await auth.login(
        email: DemoAuthRepository.providerEmail,
        password: DemoAuthRepository.demoPassword,
      );
      await replaced;
      repository.pendingJob!.complete(right(uiJob()));
      await refreshing;
      expect(cubit.state.job, isNull);
      expect(cubit.state.revoked, isTrue);
    },
  );

  test(
    'job list rejects records for nonparticipants and recovers no private data',
    () async {
      final auth = DemoAuthRepository();
      final session = await _session(auth);
      final repository = MarketplaceUiRepository(auth);
      final cubit = JobsCubit(
        userId: uiCustomerId,
        repository: repository,
        session: session,
      );
      addTearDown(cubit.close);
      await cubit.refresh();
      expect(cubit.state.items, hasLength(1));
      repository.readFailure = const ServerFailure('marketplace.errors.access');
      await cubit.refresh();
      expect(cubit.state.items, isEmpty);
      expect(cubit.state.revoked, isTrue);
    },
  );
}
