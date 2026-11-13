import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/failure.dart';
import '../../utils/task_runner.dart';
import '../../utils/typedefs.dart';
import '../models/auth_session.dart';
import '../models/marketplace.dart';
import '../models/service_request.dart';
import '../models/user_model.dart';
import 'auth_repository.dart';
import 'catalog_repository.dart';
import 'demo_marketplace_store.dart';

typedef _Check = void Function();

class MarketplaceRepository {
  MarketplaceRepository({
    required AuthRepository authRepository,
    this._client,
    DemoMarketplaceStore? demoStore,
    DateTime Function()? now,
    this._timeout = const Duration(seconds: 30),
  }) : _auth = authRepository,
       _demo = demoStore ?? DemoMarketplaceStore(),
       _now = now ?? DateTime.now;

  final AuthRepository _auth;
  final SupabaseClient? _client;
  final DemoMarketplaceStore _demo;
  final DateTime Function() _now;
  final Duration _timeout;
  final _writingUsers = <String>{};
  final _pending = <String, _PendingMutation>{};
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static const _sqlErrors = {
    'marketplace.errors.access',
    'marketplace.errors.not_found',
    'marketplace.errors.invalid',
    'marketplace.errors.consent',
    'marketplace.errors.summary',
    'marketplace.errors.city',
    'marketplace.errors.ineligible',
    'marketplace.errors.amount',
    'marketplace.errors.duration',
    'marketplace.errors.notes',
    'marketplace.errors.currency',
    'marketplace.errors.conflict',
    'marketplace.errors.status',
    'marketplace.errors.unpublished',
  };
  static const _setupErrors = {'PGRST202', 'PGRST205', '42883', '42P01'};

  bool get isDemo => _auth.isDemo;

  bool hasPendingOperation(String entityId, {required String userId}) =>
      _pending.containsKey('$userId/request/$entityId') ||
      _pending.containsKey('$userId/job/$entityId');

  /// Recover the original intent even if its page was closed or rebuilt.
  /// Never replace an ambiguous write with the newly displayed form values.
  FutureEither<void> retryPending(
    String entityId, {
    required String userId,
  }) => _withActor(userId, null, (user, check) async {
    _id(entityId);
    final requestKey = '$userId/request/$entityId';
    final key = _pending.containsKey(requestKey)
        ? requestKey
        : '$userId/job/$entityId';
    final operation = _pending[key];
    if (operation == null) return;
    final requiredRole = switch (operation.name) {
      'save_provider_quote' || 'withdraw_provider_quote' => UserRole.provider,
      'publish_request_listing' || 'accept_provider_quote' => UserRole.customer,
      _ => null,
    };
    if (requiredRole != null && user.role != requiredRole) {
      throw const ServerFailure('marketplace.errors.access');
    }
    await _mutate<Object>(
      key: key,
      name: operation.name,
      params: operation.params,
      check: check,
      decode: operation.decode,
      reconcile: operation.reconcile,
    );
  }, writes: true);

  FutureEither<MarketplacePage<MarketplaceListing>> loadFeed({
    required String userId,
    MarketplaceCursor? before,
    int limit = 20,
  }) => _withActor(userId, UserRole.provider, (user, check) async {
    final params = _pageParams(before, limit);
    if (isDemo) {
      final active = await _activeDemoCategories(check);
      final eligible = _demoEligible(userId, active);
      final page = _demoPage(
        _demo.listings.values.where(
          (listing) => _canQuote(userId, listing, active),
        ),
        (listing) => listing.cursor,
        before,
        limit,
      );
      return MarketplacePage(
        items: page.items,
        hasMore: page.hasMore,
        eligible: eligible,
      );
    }
    final json = await _rpc('get_marketplace_feed', params, check);
    final page = _page(json, limit, MarketplaceListing.fromJson);
    if (page.items.any(
      (item) => item.requestStatus != ServiceRequestStatus.open,
    )) {
      throw const ServerFailure('marketplace.errors.invalid');
    }
    return MarketplacePage(
      items: page.items,
      hasMore: page.hasMore,
      eligible: json['eligible'] as bool,
    );
  });

  FutureEither<QuoteOpportunity> loadProviderRequest(
    String requestId, {
    required String userId,
  }) => _withActor(userId, UserRole.provider, (user, check) async {
    _id(requestId);
    if (isDemo) {
      return _demoOpportunity(
        userId,
        requestId,
        await _activeDemoCategories(check),
      );
    }
    return _providerRequest(requestId, userId, check);
  });

  FutureEither<MarketplacePage<QuoteOpportunity>> loadMyQuotes({
    required String userId,
    MarketplaceCursor? before,
    int limit = 20,
  }) => _withActor(userId, UserRole.provider, (user, check) async {
    final params = _pageParams(before, limit);
    if (isDemo) {
      final active = await _activeDemoCategories(check);
      final rows = _demo.quotes.values
          .where((quote) => quote.providerId == userId)
          .map((quote) => _demoOpportunity(userId, quote.requestId, active));
      return _demoPage(rows, (row) => row.quote!.cursor, before, limit);
    }
    final page = _page(
      await _rpc('get_provider_quotes', params, check),
      limit,
      QuoteOpportunity.fromJson,
    );
    if (page.items.any((row) => row.quote?.providerId != userId)) {
      throw const ServerFailure('marketplace.errors.access');
    }
    return page;
  });

  FutureEither<CustomerQuoteBook> loadCustomerQuotes(
    String requestId, {
    required String userId,
    MarketplaceCursor? before,
    int limit = 20,
  }) => _withActor(userId, UserRole.customer, (user, check) async {
    _id(requestId);
    _pageParams(before, limit);
    if (isDemo) return _demoBook(requestId, userId, before, limit);
    return _customerBook(
      requestId,
      userId,
      check,
      before: before,
      limit: limit,
    );
  });

  FutureEither<MarketplaceListing> publishListing(
    String requestId, {
    required String userId,
    required String summary,
    required String city,
    required bool consent,
  }) => _withActor(userId, UserRole.customer, (user, check) async {
    _id(requestId);
    if (!consent) throw const ServerFailure('marketplace.errors.consent');
    final text = summary.trim();
    final area = city.trim();
    if (text.runes.length < 10 || text.runes.length > 1000) {
      throw const ServerFailure('marketplace.errors.summary');
    }
    if (area.runes.length < 2 || area.runes.length > 100) {
      throw const ServerFailure('marketplace.errors.city');
    }
    bool matches(MarketplaceListing value) =>
        value.requestId == requestId &&
        value.summary == text &&
        value.city == area;
    if (isDemo) {
      final request = _demoCustomerRequest(requestId, userId);
      final existing = _demo.listings[requestId];
      if (existing != null) {
        if (!matches(existing)) {
          throw const ServerFailure('marketplace.errors.conflict');
        }
        return existing;
      }
      if (request.status != ServiceRequestStatus.open) {
        throw const ServerFailure('marketplace.errors.status');
      }
      final listing = MarketplaceListing(
        requestId: requestId,
        categoryId: request.categoryId,
        categoryNameEn: request.categoryNameEn,
        categoryNameAr: request.categoryNameAr,
        categoryIconKey: request.categoryIconKey,
        summary: text,
        city: area,
        publishedAt: _now().toUtc(),
        requestStatus: ServiceRequestStatus.open,
      );
      _demo.listings[requestId] = listing;
      return listing;
    }
    return _mutate(
      key: '$userId/request/$requestId',
      name: 'publish_request_listing',
      params: {
        'p_request_id': requestId,
        'p_summary': text,
        'p_city': area,
        'p_consent': consent,
      },
      check: check,
      decode: (json) {
        final listing = MarketplaceListing.fromJson(json);
        if (!matches(listing)) {
          throw const ServerFailure('marketplace.errors.invalid');
        }
        return listing;
      },
      reconcile: (check) async {
        final book = await _customerBook(requestId, userId, check);
        if (book.listing != null) {
          if (!matches(book.listing!)) {
            throw const _ResolvedFailure('marketplace.errors.conflict');
          }
          return book.listing;
        }
        if (book.requestStatus != ServiceRequestStatus.open) {
          throw const _ResolvedFailure('marketplace.errors.status');
        }
        return null;
      },
    );
  }, writes: true);

  FutureEither<ProviderQuote> saveQuote(
    QuoteDraft draft, {
    required String userId,
  }) => _withActor(userId, UserRole.provider, (user, check) async {
    final validation = draft.validate();
    if (validation != null) throw ServerFailure(validation);
    if (isDemo) {
      final active = await _activeDemoCategories(check);
      final previous = _demoOwnQuote(userId, draft.requestId);
      if (previous != null &&
          previous.revision == draft.expectedRevision + 1 &&
          draft.matches(previous)) {
        return previous;
      }
      final opportunity = _demoOpportunity(userId, draft.requestId, active);
      if (!opportunity.canQuote) {
        throw const ServerFailure('marketplace.errors.ineligible');
      }
      if ((previous?.revision ?? 0) != draft.expectedRevision) {
        throw const ServerFailure('marketplace.errors.conflict');
      }
      if (previous != null &&
          previous.status != QuoteStatus.pending &&
          previous.status != QuoteStatus.withdrawn) {
        throw const ServerFailure('marketplace.errors.status');
      }
      final now = _now().toUtc();
      final quote = previous == null
          ? ProviderQuote(
              id: _newId(),
              requestId: draft.requestId,
              providerId: userId,
              providerName: user.name.trim(),
              amountMinor: draft.amountMinor!,
              currency: QuoteDraft.currency,
              durationMinutes: draft.durationMinutes!,
              notes: draft.notes.trim(),
              revision: 1,
              status: QuoteStatus.pending,
              createdAt: now,
              updatedAt: now,
            )
          : previous.copyWith(
              amountMinor: draft.amountMinor,
              durationMinutes: draft.durationMinutes,
              notes: draft.notes.trim(),
              revision: previous.revision + 1,
              status: QuoteStatus.pending,
              updatedAt: now,
            );
      _demo.quotes[quote.id] = quote;
      return quote;
    }
    return _mutate(
      key: '$userId/request/${draft.requestId}',
      name: 'save_provider_quote',
      params: {
        'p_request_id': draft.requestId,
        'p_amount_minor': draft.amountMinor,
        'p_currency': QuoteDraft.currency,
        'p_duration_minutes': draft.durationMinutes,
        'p_notes': draft.notes.trim(),
        'p_expected_revision': draft.expectedRevision,
      },
      check: check,
      decode: (json) {
        final quote = _ownQuote(json, userId, draft.requestId);
        if (quote.revision != draft.expectedRevision + 1 ||
            !draft.matches(quote)) {
          throw const ServerFailure('marketplace.errors.invalid');
        }
        return quote;
      },
      reconcile: (check) async {
        final opportunity = await _providerRequest(
          draft.requestId,
          userId,
          check,
        );
        final quote = opportunity.quote;
        if (quote != null &&
            quote.revision == draft.expectedRevision + 1 &&
            draft.matches(quote)) {
          return quote;
        }
        if ((quote != null && quote.revision > draft.expectedRevision) ||
            opportunity.listing.requestStatus != ServiceRequestStatus.open) {
          throw const _ResolvedFailure('marketplace.errors.conflict');
        }
        return null;
      },
    );
  }, writes: true);

  FutureEither<ProviderQuote> withdrawQuote(
    ProviderQuote quote, {
    required String userId,
  }) => _withActor(userId, UserRole.provider, (user, check) async {
    _quoteIdentity(quote);
    if (quote.providerId != userId) {
      throw const ServerFailure('marketplace.errors.access');
    }
    bool unchanged(ProviderQuote current) =>
        current.id == quote.id &&
        current.providerId == quote.providerId &&
        current.providerName == quote.providerName &&
        current.revision == quote.revision &&
        current.createdAt.isAtSameMomentAs(quote.createdAt) &&
        QuoteDraft.fromQuote(quote).matches(current);
    if (isDemo) {
      final current = _demo.quotes[quote.id];
      if (current == null ||
          current.providerId != userId ||
          current.requestId != quote.requestId) {
        throw const ServerFailure('marketplace.errors.not_found');
      }
      if (current.revision != quote.revision) {
        throw const ServerFailure('marketplace.errors.conflict');
      }
      if (current.status == QuoteStatus.withdrawn) return current;
      if (current.status != QuoteStatus.pending ||
          _demo.requests[current.requestId]?.status !=
              ServiceRequestStatus.open) {
        throw const ServerFailure('marketplace.errors.status');
      }
      final withdrawn = current.copyWith(
        status: QuoteStatus.withdrawn,
        updatedAt: _now().toUtc(),
      );
      _demo.quotes[current.id] = withdrawn;
      return withdrawn;
    }
    return _mutate(
      key: '$userId/request/${quote.requestId}',
      name: 'withdraw_provider_quote',
      params: {'p_quote_id': quote.id, 'p_expected_revision': quote.revision},
      check: check,
      decode: (json) {
        final value = _ownQuote(json, userId, quote.requestId);
        if (!unchanged(value) || value.status != QuoteStatus.withdrawn) {
          throw const ServerFailure('marketplace.errors.invalid');
        }
        return value;
      },
      reconcile: (check) async {
        final value = (await _providerRequest(
          quote.requestId,
          userId,
          check,
        )).quote;
        if (value?.id == quote.id &&
            value?.revision == quote.revision &&
            value?.status == QuoteStatus.withdrawn) {
          if (!unchanged(value!)) {
            throw const ServerFailure('marketplace.errors.invalid');
          }
          return value;
        }
        if (value != null &&
            (value.revision != quote.revision ||
                value.status != QuoteStatus.pending)) {
          throw const _ResolvedFailure('marketplace.errors.conflict');
        }
        return null;
      },
    );
  }, writes: true);

  FutureEither<ServiceJob> acceptQuote(
    ProviderQuote quote, {
    required String userId,
    required bool consent,
  }) => _withActor(userId, UserRole.customer, (user, check) async {
    _quoteIdentity(quote);
    if (!consent) throw const ServerFailure('marketplace.errors.consent');
    bool matches(ServiceJob job) =>
        job.customerId == userId &&
        job.requestId == quote.requestId &&
        job.quoteId == quote.id &&
        job.quoteRevision == quote.revision &&
        job.providerId == quote.providerId &&
        job.providerName == quote.providerName &&
        job.amountMinor == quote.amountMinor &&
        job.currency == quote.currency &&
        job.durationMinutes == quote.durationMinutes &&
        job.notes == quote.notes;
    if (isDemo) {
      _demoCustomerRequest(quote.requestId, userId);
      final existing = _demoJobForRequest(quote.requestId);
      if (existing != null) {
        if (!matches(existing) ||
            _demo.quotes[quote.id]?.revision != quote.revision) {
          throw const ServerFailure('marketplace.errors.conflict');
        }
        return existing;
      }
      final active = await _activeDemoCategories(check);
      final request = _demoCustomerRequest(quote.requestId, userId);
      final current = _demo.quotes[quote.id];
      final listing = _demo.listings[request.id];
      if (current == null ||
          current.requestId != request.id ||
          current.providerId != quote.providerId) {
        throw const ServerFailure('marketplace.errors.not_found');
      }
      if (current.revision != quote.revision ||
          !QuoteDraft.fromQuote(quote).matches(current)) {
        throw const ServerFailure('marketplace.errors.conflict');
      }
      if (request.status != ServiceRequestStatus.open ||
          current.status != QuoteStatus.pending) {
        throw const ServerFailure('marketplace.errors.status');
      }
      if (listing == null || !_canQuote(current.providerId, listing, active)) {
        throw const ServerFailure('marketplace.errors.ineligible');
      }
      final now = _now().toUtc();
      final job = ServiceJob(
        id: _newId(),
        requestId: request.id,
        quoteId: current.id,
        quoteRevision: current.revision,
        customerId: userId,
        providerId: current.providerId,
        providerName: current.providerName,
        amountMinor: current.amountMinor,
        currency: current.currency,
        durationMinutes: current.durationMinutes,
        notes: current.notes,
        status: JobStatus.selected,
        createdAt: now,
        updatedAt: now,
        requestTitle: request.title,
        requestDescription: request.description,
        city: request.city,
        address: request.address,
        preferredAt: request.preferredAt,
        history: [
          JobHistoryEntry(
            id: _newId(),
            status: JobStatus.selected,
            actorId: userId,
            createdAt: now,
          ),
        ],
      );
      // No await within the commit: all demo observers see one coherent state.
      _demo.requests[request.id] = ServiceRequest.fromJson({
        ...request.toJson(),
        'status': 'assigned',
      });
      _demo.listings[request.id] = listing.withStatus(
        ServiceRequestStatus.assigned,
      );
      for (final other in _demo.quotes.values.toList()) {
        if (other.requestId == request.id &&
            other.status == QuoteStatus.pending) {
          _demo.quotes[other.id] = other.copyWith(
            status: other.id == current.id
                ? QuoteStatus.accepted
                : QuoteStatus.notSelected,
            updatedAt: now,
          );
        }
      }
      _demo.jobs[job.id] = job;
      return job;
    }
    return _mutate(
      key: '$userId/request/${quote.requestId}',
      name: 'accept_provider_quote',
      params: {
        'p_quote_id': quote.id,
        'p_expected_revision': quote.revision,
        'p_consent': consent,
      },
      check: check,
      decode: (json) {
        final job = _job(json, user);
        if (!matches(job)) {
          throw const ServerFailure('marketplace.errors.invalid');
        }
        return job;
      },
      reconcile: (check) async {
        final book = await _customerBook(quote.requestId, userId, check);
        if (book.job != null) {
          if (!matches(book.job!)) {
            throw const _ResolvedFailure('marketplace.errors.conflict');
          }
          return book.job;
        }
        if (book.requestStatus != ServiceRequestStatus.open ||
            book.quotes.any(
              (row) =>
                  row.id == quote.id &&
                  (row.revision != quote.revision ||
                      row.status != QuoteStatus.pending),
            )) {
          throw const _ResolvedFailure('marketplace.errors.conflict');
        }
        return null;
      },
    );
  }, writes: true);

  FutureEither<MarketplacePage<ServiceJob>> loadJobs({
    required String userId,
    MarketplaceCursor? before,
    int limit = 20,
  }) => _withActor(userId, null, (user, check) async {
    final params = _pageParams(before, limit);
    if (isDemo) {
      return _demoPage(
        _demo.jobs.values.where((job) => _participates(job, user)),
        (job) => job.cursor,
        before,
        limit,
      );
    }
    return _page(
      await _rpc('get_service_jobs', params, check),
      limit,
      (json) => _job(json, user),
    );
  });

  FutureEither<ServiceJob> loadJob(String jobId, {required String userId}) =>
      _withActor(userId, null, (user, check) async {
        _id(jobId);
        if (isDemo) return _demoJob(jobId, user);
        return _getJob(jobId, user, check);
      });

  FutureEither<ServiceJob> transitionJob(
    ServiceJob job,
    JobStatus target, {
    required String userId,
  }) => _withActor(userId, null, (user, check) async {
    _id(job.id);
    if (!_participates(job, user)) {
      throw const ServerFailure('marketplace.errors.access');
    }
    if (!job.status.actionsFor(job.roleFor(userId)!).contains(target)) {
      throw const ServerFailure('marketplace.errors.status');
    }
    bool applied(ServiceJob current) => current.history.any(
      (event) =>
          event.actorId == userId &&
          event.fromStatus == job.status &&
          event.status == target,
    );
    bool unchanged(ServiceJob current) =>
        current.id == job.id &&
        current.requestId == job.requestId &&
        current.quoteId == job.quoteId &&
        current.quoteRevision == job.quoteRevision &&
        current.customerId == job.customerId &&
        current.providerId == job.providerId &&
        current.providerName == job.providerName &&
        current.amountMinor == job.amountMinor &&
        current.currency == job.currency &&
        current.durationMinutes == job.durationMinutes &&
        current.notes == job.notes &&
        current.createdAt.isAtSameMomentAs(job.createdAt) &&
        current.requestTitle == job.requestTitle &&
        current.requestDescription == job.requestDescription &&
        current.city == job.city &&
        current.address == job.address &&
        current.preferredAt == job.preferredAt &&
        current.history.length >= job.history.length &&
        Iterable<int>.generate(job.history.length)
            .every((index) => current.history[index] == job.history[index]);
    if (isDemo) {
      final current = _demoJob(job.id, user);
      if (applied(current)) return current;
      if (current.status != job.status) {
        throw const ServerFailure('marketplace.errors.conflict');
      }
      final next = current.withTransition(
        JobHistoryEntry(
          id: _newId(),
          fromStatus: current.status,
          status: target,
          actorId: userId,
          createdAt: _now().toUtc(),
        ),
      );
      _demo.jobs[job.id] = next;
      return next;
    }
    return _mutate(
      key: '$userId/job/${job.id}',
      name: 'transition_service_job',
      params: {
        'p_job_id': job.id,
        'p_expected_status': job.status.wireName,
        'p_status': target.wireName,
      },
      check: check,
      decode: (json) {
        final current = _job(json, user);
        if (!unchanged(current) || !applied(current)) {
          throw const ServerFailure('marketplace.errors.invalid');
        }
        return current;
      },
      reconcile: (check) async {
        final current = await _getJob(job.id, user, check);
        if (!unchanged(current)) {
          throw const ServerFailure('marketplace.errors.invalid');
        }
        if (applied(current)) return current;
        if (current.status != job.status) {
          throw const _ResolvedFailure('marketplace.errors.conflict');
        }
        return null;
      },
    );
  }, writes: true);

  Future<T> _mutate<T extends Object>({
    required String key,
    required String name,
    required Map<String, Object?> params,
    required _Check check,
    required T Function(Map<String, dynamic>) decode,
    required Future<T?> Function(_Check check) reconcile,
  }) async {
    final fingerprint = jsonEncode([name, params]);
    final previous = _pending[key];
    if (previous != null && previous.fingerprint != fingerprint) {
      throw const ServerFailure('marketplace.errors.uncertain');
    }
    check();
    _pending[key] = _PendingMutation(
      fingerprint: fingerprint,
      name: name,
      params: params,
      decode: decode,
      reconcile: reconcile,
    );
    try {
      final value = decode(await _rpc(name, params, check));
      check();
      _pending.remove(key);
      return value;
    } catch (error) {
      check();
      if (previous == null &&
          error is PostgrestException &&
          (_sqlErrors.contains(error.message) ||
              _setupErrors.contains(error.code))) {
        _pending.remove(key);
        throw _safeFailure(error);
      }
      try {
        final canonical = await reconcile(check);
        check();
        if (canonical != null) {
          _pending.remove(key);
          return canonical;
        }
      } on _ResolvedFailure catch (resolved) {
        _pending.remove(key);
        throw ServerFailure(resolved.message);
      } catch (_) {
        check();
      }
      // An absent read cannot prove a timed-out transaction will never commit.
      throw const ServerFailure('marketplace.errors.uncertain');
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
      throw const ServerFailure('marketplace.errors.invalid');
    }
    return data;
  }

  Future<QuoteOpportunity> _providerRequest(
    String requestId,
    String userId,
    _Check check,
  ) async {
    final value = QuoteOpportunity.fromJson(
      await _rpc('get_provider_request', {'p_request_id': requestId}, check),
    );
    if (value.listing.requestId != requestId ||
        (value.quote != null && value.quote!.providerId != userId)) {
      throw const ServerFailure('marketplace.errors.access');
    }
    return value;
  }

  Future<CustomerQuoteBook> _customerBook(
    String requestId,
    String userId,
    _Check check, {
    MarketplaceCursor? before,
    int limit = 20,
  }) async {
    final book = CustomerQuoteBook.fromJson(
      await _rpc('get_customer_quotes', {
        'p_request_id': requestId,
        ..._pageParams(before, limit),
      }, check),
    );
    if (book.requestId != requestId || book.customerId != userId) {
      throw const ServerFailure('marketplace.errors.access');
    }
    if (book.quotes.length > limit ||
        (book.hasMore && book.quotes.length != limit)) {
      throw const ServerFailure('marketplace.errors.invalid');
    }
    return book;
  }

  Future<ServiceJob> _getJob(String id, AppUser user, _Check check) async {
    final job = _job(
      await _rpc('get_service_job', {'p_job_id': id}, check),
      user,
    );
    if (job.id != id) throw const ServerFailure('marketplace.errors.access');
    return job;
  }

  ProviderQuote _ownQuote(
    Map<String, dynamic> json,
    String userId,
    String requestId,
  ) {
    final quote = ProviderQuote.fromJson(json);
    if (quote.providerId != userId || quote.requestId != requestId) {
      throw const ServerFailure('marketplace.errors.access');
    }
    return quote;
  }

  ServiceJob _job(Map<String, dynamic> json, AppUser user) {
    final job = ServiceJob.fromJson(json);
    if (!_participates(job, user)) {
      throw const ServerFailure('marketplace.errors.access');
    }
    return job;
  }

  bool _participates(ServiceJob job, AppUser user) =>
      job.roleFor(user.id) != null;

  MarketplacePage<T> _page<T>(
    Map<String, dynamic> json,
    int limit,
    T Function(Map<String, dynamic>) decode,
  ) {
    final items = (json['items'] as List)
        .map((item) => decode(item as Map<String, dynamic>))
        .toList();
    final hasMore = json['has_more'] as bool;
    if (items.length > limit || (hasMore && items.length != limit)) {
      throw const ServerFailure('marketplace.errors.invalid');
    }
    return MarketplacePage(items: items, hasMore: hasMore);
  }

  Map<String, Object?> _pageParams(MarketplaceCursor? before, int limit) {
    if (limit < 1 ||
        limit > 50 ||
        (before != null && !ServiceRequestDraft.validId(before.id))) {
      throw const ServerFailure('marketplace.errors.invalid');
    }
    return {
      'p_before_created_at': before?.createdAt.toUtc().toIso8601String(),
      'p_before_id': before?.id,
      'p_limit': limit,
    };
  }

  MarketplacePage<T> _demoPage<T>(
    Iterable<T> source,
    MarketplaceCursor Function(T) cursor,
    MarketplaceCursor? before,
    int limit,
  ) {
    int compare(MarketplaceCursor a, MarketplaceCursor b) {
      final time = b.createdAt.compareTo(a.createdAt);
      return time == 0 ? b.id.compareTo(a.id) : time;
    }

    final rows =
        source
            .where((row) => before == null || compare(cursor(row), before) > 0)
            .toList()
          ..sort((a, b) => compare(cursor(a), cursor(b)));
    return MarketplacePage(
      items: rows.take(limit).toList(),
      hasMore: rows.length > limit,
    );
  }

  Future<Set<String>> _activeDemoCategories(_Check check) async {
    final categories = (await CatalogRepository().loadCategories()).fold(
      (failure) => throw failure,
      (value) => value,
    );
    check();
    return categories
        .where((category) => category.isActive)
        .map((category) => category.id)
        .toSet();
  }

  bool _demoEligible(String providerId, Set<String> active) {
    final provider = _demo.providers[providerId];
    return provider != null &&
        provider.verified &&
        provider.role == UserRole.provider &&
        provider.skillIds.any(active.contains) &&
        provider.serviceAreas.isNotEmpty;
  }

  bool _canQuote(
    String providerId,
    MarketplaceListing listing,
    Set<String> active,
  ) {
    final provider = _demo.providers[providerId];
    return _demoEligible(providerId, active) &&
        _demo.requests[listing.requestId]?.status ==
            ServiceRequestStatus.open &&
        active.contains(listing.categoryId) &&
        provider!.skillIds.contains(listing.categoryId) &&
        provider.serviceAreas.any(
          (area) => area.trim().toLowerCase() == listing.city.toLowerCase(),
        );
  }

  ProviderQuote? _demoOwnQuote(String providerId, String requestId) => _demo
      .quotes
      .values
      .where(
        (quote) =>
            quote.providerId == providerId && quote.requestId == requestId,
      )
      .firstOrNull;

  QuoteOpportunity _demoOpportunity(
    String providerId,
    String requestId,
    Set<String> active,
  ) {
    final listing = _demo.listings[requestId];
    final quote = _demoOwnQuote(providerId, requestId);
    if (listing == null ||
        (quote == null && !_canQuote(providerId, listing, active))) {
      throw const ServerFailure('marketplace.errors.not_found');
    }
    return QuoteOpportunity(
      listing: listing,
      quote: quote,
      canQuote:
          _canQuote(providerId, listing, active) &&
          (quote == null ||
              quote.status == QuoteStatus.pending ||
              quote.status == QuoteStatus.withdrawn),
    );
  }

  ServiceRequest _demoCustomerRequest(String requestId, String userId) {
    final request = _demo.requests[requestId];
    if (request == null || request.customerId != userId) {
      throw const ServerFailure('marketplace.errors.not_found');
    }
    return request;
  }

  ServiceJob? _demoJobForRequest(String requestId) =>
      _demo.jobs.values.where((job) => job.requestId == requestId).firstOrNull;

  CustomerQuoteBook _demoBook(
    String requestId,
    String userId,
    MarketplaceCursor? before,
    int limit,
  ) {
    final request = _demoCustomerRequest(requestId, userId);
    final page = _demoPage(
      _demo.quotes.values.where((quote) => quote.requestId == requestId),
      (quote) => quote.cursor,
      before,
      limit,
    );
    return CustomerQuoteBook(
      requestId: requestId,
      customerId: userId,
      requestStatus: request.status,
      listing: _demo.listings[requestId],
      quotes: page.items,
      hasMore: page.hasMore,
      job: _demoJobForRequest(requestId),
    );
  }

  ServiceJob _demoJob(String id, AppUser user) {
    final job = _demo.jobs[id];
    if (job == null || !_participates(job, user)) {
      throw const ServerFailure('marketplace.errors.not_found');
    }
    return job;
  }

  void _id(String id) {
    if (!ServiceRequestDraft.validId(id)) {
      throw const ServerFailure('marketplace.errors.not_found');
    }
  }

  void _quoteIdentity(ProviderQuote quote) {
    _id(quote.id);
    _id(quote.requestId);
    if (quote.revision < 1 ||
        quote.revision > 2147483647 ||
        quote.currency != QuoteDraft.currency ||
        quote.amountMinor < 1 ||
        quote.amountMinor > QuoteDraft.maxAmountMinor ||
        quote.durationMinutes < 1 ||
        quote.durationMinutes > QuoteDraft.maxDurationMinutes ||
        quote.notes != quote.notes.trim() ||
        quote.notes.runes.length > 1000) {
      throw const ServerFailure('marketplace.errors.invalid');
    }
  }

  String _newId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  FutureEither<T> _withActor<T>(
    String userId,
    UserRole? requiredRole,
    Future<T> Function(AppUser user, _Check check) action, {
    bool writes = false,
  }) => runTask(() async {
    StreamSubscription<AuthSession>? subscription;
    StreamSubscription<AuthState>? sdkSubscription;
    GoTrueClient? sdkAuth;
    var invalidated = false;
    var ownsLock = false;
    var role = requiredRole;
    bool matches(AuthSession session) =>
        userId.isNotEmpty &&
        session.user?.id == userId &&
        (role == null || session.user?.role == role) &&
        !session.needsPasswordUpdate;
    void check() {
      if (invalidated ||
          (sdkAuth != null && sdkAuth.currentSession?.user.id != userId)) {
        throw const ServerFailure('marketplace.errors.access');
      }
    }

    try {
      if (!isDemo && _client == null) {
        throw const ServerFailure('errors.database_setup');
      }
      if (!isDemo && !_uuid.hasMatch(userId)) {
        throw const ServerFailure('marketplace.errors.access');
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
        (_) => throw const ServerFailure('marketplace.errors.access'),
        (value) => value,
      );
      check();
      if (!matches(session)) {
        throw const ServerFailure('marketplace.errors.access');
      }
      role = session.user!.role;
      if (writes) {
        ownsLock = _writingUsers.add(userId);
        if (!ownsLock) throw const ServerFailure('marketplace.errors.busy');
      }
      final result = await action(session.user!, check);
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
    return const ServerFailure('marketplace.errors.load_failed');
  }
}

/// A canonical read proves that the original mutation can no longer commit.
class _ResolvedFailure {
  const _ResolvedFailure(this.message);
  final String message;
}

class _PendingMutation {
  _PendingMutation({
    required this.fingerprint,
    required this.name,
    required Map<String, Object?> params,
    required this.decode,
    required this.reconcile,
  }) : params = Map.unmodifiable(params);

  final String fingerprint;
  final String name;
  final Map<String, Object?> params;
  final Object Function(Map<String, dynamic>) decode;
  final Future<Object?> Function(_Check check) reconcile;
}
