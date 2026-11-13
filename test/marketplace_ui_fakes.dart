import 'dart:async';

import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/marketplace.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/marketplace_repository.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';

const uiCustomerId = 'demo-customer';
const uiProviderId = 'demo-marketplace-provider';
const uiRequestId = '123e4567-e89b-42d3-a456-426614174101';
const uiQuoteId = '123e4567-e89b-42d3-a456-426614174102';
const uiJobId = '123e4567-e89b-42d3-a456-426614174103';
final uiNow = DateTime.utc(2026, 11, 9, 12);

MarketplaceListing uiListing({String requestId = uiRequestId}) =>
    MarketplaceListing(
      requestId: requestId,
      categoryId: 'demo-plumbing',
      categoryNameEn: 'Plumbing',
      categoryNameAr: 'سباكة',
      categoryIconKey: 'plumbing',
      summary: 'A newly written public plumbing summary.',
      city: 'Cairo',
      publishedAt: uiNow,
      requestStatus: ServiceRequestStatus.open,
    );

ProviderQuote uiQuote({
  String id = uiQuoteId,
  String providerId = uiProviderId,
  int revision = 1,
  int amountMinor = 12550,
}) => ProviderQuote(
  id: id,
  requestId: uiRequestId,
  providerId: providerId,
  providerName: 'Sample Marketplace Provider',
  amountMinor: amountMinor,
  currency: 'EGP',
  durationMinutes: 90,
  notes: 'Sample labour terms only.',
  revision: revision,
  status: QuoteStatus.pending,
  createdAt: uiNow,
  updatedAt: uiNow,
);

ServiceJob uiJob({JobStatus status = JobStatus.selected}) {
  var job = ServiceJob(
    id: uiJobId,
    requestId: uiRequestId,
    quoteId: uiQuoteId,
    quoteRevision: 1,
    customerId: uiCustomerId,
    providerId: uiProviderId,
    providerName: 'Sample Marketplace Provider',
    amountMinor: 12550,
    currency: 'EGP',
    durationMinutes: 90,
    notes: 'Sample labour terms only.',
    status: JobStatus.selected,
    createdAt: uiNow,
    updatedAt: uiNow,
    requestTitle: 'Original private request title',
    requestDescription:
        'Original private details that were never copied into the listing.',
    city: 'Private city field',
    address: 'Private building 27, apartment 9',
    preferredAt: uiNow.add(const Duration(days: 2)),
    history: [
      JobHistoryEntry(
        id: '123e4567-e89b-42d3-a456-426614174104',
        status: JobStatus.selected,
        actorId: uiCustomerId,
        createdAt: uiNow,
      ),
    ],
  );
  final path = switch (status) {
    JobStatus.selected => <JobStatus>[],
    JobStatus.onTheWay => [JobStatus.onTheWay],
    JobStatus.inProgress => [JobStatus.inProgress],
    JobStatus.awaitingConfirmation => [
      JobStatus.inProgress,
      JobStatus.awaitingConfirmation,
    ],
    JobStatus.completed => [
      JobStatus.inProgress,
      JobStatus.awaitingConfirmation,
      JobStatus.completed,
    ],
    JobStatus.cancelled => [JobStatus.cancelled],
  };
  for (final (index, target) in path.indexed) {
    job = job.withTransition(
      JobHistoryEntry(
        id: '123e4567-e89b-42d3-a456-42661417410${index + 5}',
        fromStatus: job.status,
        status: target,
        actorId: target == JobStatus.completed || target == JobStatus.cancelled
            ? uiCustomerId
            : uiProviderId,
        createdAt: uiNow.add(Duration(minutes: index + 1)),
      ),
    );
  }
  return job;
}

CustomerQuoteBook uiBook({
  bool published = true,
  List<ProviderQuote> quotes = const [],
  ServiceJob? job,
}) => CustomerQuoteBook(
  requestId: uiRequestId,
  customerId: uiCustomerId,
  requestStatus: job == null
      ? ServiceRequestStatus.open
      : ServiceRequestStatus.assigned,
  listing: published
      ? uiListing().withStatus(
          job == null
              ? ServiceRequestStatus.open
              : ServiceRequestStatus.assigned,
        )
      : null,
  quotes: quotes,
  hasMore: false,
  job: job,
);

class MarketplaceUiRepository extends MarketplaceRepository {
  MarketplaceUiRepository(DemoAuthRepository auth)
    : super(authRepository: auth);

  MarketplaceListing listing = uiListing();
  ProviderQuote? quote;
  CustomerQuoteBook book = uiBook(published: false);
  ServiceJob job = uiJob();
  MarketplacePage<MarketplaceListing>? feed;
  MarketplacePage<QuoteOpportunity>? quotesPage;
  MarketplacePage<ServiceJob>? jobsPage;
  bool eligible = true;
  bool storedPending = false;
  Failure? readFailure;
  Failure? mutationFailure;
  Failure? storedRetryFailure;
  int feedLoads = 0;
  int quoteLoads = 0;
  int bookLoads = 0;
  int jobLoads = 0;
  int storedRetries = 0;
  MarketplaceCursor? lastCursor;
  final users = <String>[];
  final drafts = <QuoteDraft>[];
  final withdrawals = <ProviderQuote>[];
  final acceptances = <({ProviderQuote quote, bool consent})>[];
  final publications = <({String summary, String city, bool consent})>[];
  final transitions = <({ServiceJob job, JobStatus target})>[];
  Completer<Either<Failure, ProviderQuote>>? pendingSave;
  Completer<Either<Failure, ProviderQuote>>? pendingWithdraw;
  Completer<Either<Failure, ServiceJob>>? pendingAccept;
  Completer<Either<Failure, ServiceJob>>? pendingTransition;
  Completer<Either<Failure, ServiceJob>>? pendingJob;
  Completer<Either<Failure, MarketplacePage<MarketplaceListing>>>? pendingFeed;

  @override
  bool hasPendingOperation(String entityId, {required String userId}) =>
      storedPending;

  @override
  FutureEither<void> retryPending(
    String entityId, {
    required String userId,
  }) async {
    users.add(userId);
    storedRetries++;
    if (storedRetryFailure != null) return left(storedRetryFailure!);
    storedPending = false;
    return right(null);
  }

  @override
  FutureEither<MarketplacePage<MarketplaceListing>> loadFeed({
    required String userId,
    MarketplaceCursor? before,
    int limit = 20,
  }) async {
    users.add(userId);
    feedLoads++;
    lastCursor = before;
    return pendingFeed?.future ??
        (readFailure != null
            ? left(readFailure!)
            : right(
                feed ??
                    MarketplacePage(
                      items: eligible ? [listing] : [],
                      hasMore: false,
                      eligible: eligible,
                    ),
              ));
  }

  @override
  FutureEither<MarketplacePage<QuoteOpportunity>> loadMyQuotes({
    required String userId,
    MarketplaceCursor? before,
    int limit = 20,
  }) async {
    users.add(userId);
    lastCursor = before;
    return readFailure != null
        ? left(readFailure!)
        : right(
            quotesPage ??
                MarketplacePage(
                  items: quote == null
                      ? []
                      : [
                          QuoteOpportunity(
                            listing: listing,
                            quote: quote,
                            canQuote: eligible,
                          ),
                        ],
                  hasMore: false,
                ),
          );
  }

  @override
  FutureEither<QuoteOpportunity> loadProviderRequest(
    String requestId, {
    required String userId,
  }) async {
    users.add(userId);
    quoteLoads++;
    return readFailure != null
        ? left(readFailure!)
        : right(
            QuoteOpportunity(
              listing: listing,
              quote: quote,
              canQuote: eligible,
            ),
          );
  }

  @override
  FutureEither<CustomerQuoteBook> loadCustomerQuotes(
    String requestId, {
    required String userId,
    MarketplaceCursor? before,
    int limit = 20,
  }) async {
    users.add(userId);
    bookLoads++;
    lastCursor = before;
    return readFailure != null ? left(readFailure!) : right(book);
  }

  @override
  FutureEither<MarketplaceListing> publishListing(
    String requestId, {
    required String userId,
    required String summary,
    required String city,
    required bool consent,
  }) async {
    users.add(userId);
    publications.add((summary: summary, city: city, consent: consent));
    if (mutationFailure != null) return left(mutationFailure!);
    listing = MarketplaceListing(
      requestId: requestId,
      categoryId: listing.categoryId,
      categoryNameEn: listing.categoryNameEn,
      categoryNameAr: listing.categoryNameAr,
      categoryIconKey: listing.categoryIconKey,
      summary: summary,
      city: city,
      publishedAt: uiNow,
      requestStatus: ServiceRequestStatus.open,
    );
    book = CustomerQuoteBook(
      requestId: requestId,
      customerId: userId,
      requestStatus: ServiceRequestStatus.open,
      listing: listing,
      quotes: const [],
      hasMore: false,
    );
    return right(listing);
  }

  @override
  FutureEither<ProviderQuote> saveQuote(
    QuoteDraft draft, {
    required String userId,
  }) async {
    users.add(userId);
    drafts.add(draft);
    if (pendingSave != null) return pendingSave!.future;
    if (mutationFailure != null) return left(mutationFailure!);
    quote =
        uiQuote(
          revision: draft.expectedRevision + 1,
          amountMinor: draft.amountMinor!,
        ).copyWith(
          durationMinutes: draft.durationMinutes,
          notes: draft.notes.trim(),
        );
    return right(quote!);
  }

  @override
  FutureEither<ProviderQuote> withdrawQuote(
    ProviderQuote value, {
    required String userId,
  }) async {
    users.add(userId);
    withdrawals.add(value);
    if (pendingWithdraw != null) return pendingWithdraw!.future;
    if (mutationFailure != null) return left(mutationFailure!);
    quote = value.copyWith(status: QuoteStatus.withdrawn);
    return right(quote!);
  }

  @override
  FutureEither<ServiceJob> acceptQuote(
    ProviderQuote value, {
    required String userId,
    required bool consent,
  }) async {
    users.add(userId);
    acceptances.add((quote: value, consent: consent));
    if (pendingAccept != null) return pendingAccept!.future;
    if (mutationFailure != null) return left(mutationFailure!);
    book = uiBook(job: job);
    return right(job);
  }

  @override
  FutureEither<MarketplacePage<ServiceJob>> loadJobs({
    required String userId,
    MarketplaceCursor? before,
    int limit = 20,
  }) async {
    users.add(userId);
    lastCursor = before;
    return readFailure != null
        ? left(readFailure!)
        : right(jobsPage ?? MarketplacePage(items: [job], hasMore: false));
  }

  @override
  FutureEither<ServiceJob> loadJob(
    String jobId, {
    required String userId,
  }) async {
    users.add(userId);
    jobLoads++;
    return pendingJob?.future ??
        (readFailure != null ? left(readFailure!) : right(job));
  }

  @override
  FutureEither<ServiceJob> transitionJob(
    ServiceJob value,
    JobStatus target, {
    required String userId,
  }) async {
    users.add(userId);
    transitions.add((job: value, target: target));
    if (pendingTransition != null) return pendingTransition!.future;
    if (mutationFailure != null) return left(mutationFailure!);
    job = value.withTransition(
      JobHistoryEntry(
        id: '123e4567-e89b-42d3-a456-42661417411${value.history.length}',
        fromStatus: value.status,
        status: target,
        actorId: userId,
        createdAt: value.updatedAt.add(const Duration(minutes: 1)),
      ),
    );
    return right(job);
  }
}
