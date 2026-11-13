import 'package:flutter_test/flutter_test.dart';
import 'package:salahly/src/data/models/marketplace.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/models/user_model.dart';

import 'marketplace_fixtures.dart' as fixture;

void main() {
  group('QuoteDraft', () {
    test('parses ASCII, Arabic and Persian decimals into exact EGP cents', () {
      for (final (input, cents) in [
        ('0.01', 1),
        ('0.29', 29),
        ('1', 100),
        ('12.3', 1230),
        ('0001.05', 105),
        ('999999.99', 99999999),
        ('1000000.00', 100000000),
        (' \t123.45\n', 12345),
        ('\u0661\u0662\u0663\u066b\u0664\u0665', 12345),
        ('\u06f1\u06f2\u06f3\u066b\u06f4\u06f5', 12345),
        ('\u0661\u0662.\u0663', 1230),
        ('\u06f1\u06f2.\u06f3', 1230),
        ('1\u0662\u06f3\u066b45', 12345),
      ]) {
        final draft = fixture.draft().copyWith(amount: input);
        expect(draft.amountMinor, cents, reason: input);
        expect(draft.validate(), isNull, reason: input);
      }
      expect(QuoteDraft.currency, 'EGP');
      expect(QuoteDraft.maxAmountMinor, 100000000);
    });

    test(
      'rejects zero, grouping, signs, exponents and excessive fractions',
      () {
        for (final input in [
          '',
          ' ',
          '0',
          '0.00',
          '-1',
          '+1',
          '1e2',
          '1E2',
          '1,000',
          '1\u066c000',
          '1 000',
          '1\u00a0000',
          '1_000',
          '.50',
          '1.',
          '0.001',
          '1.999',
          '1000000.01',
          '1000000000',
          'NaN',
          'Infinity',
          '1..2',
          '1\u066b2.3',
        ]) {
          final draft = fixture.draft().copyWith(amount: input);
          expect(draft.amountMinor, isNull, reason: input);
          expect(draft.validate(), 'marketplace.errors.amount', reason: input);
        }
      },
    );

    test('duration accepts only integer minutes in 1..43200', () {
      for (final (input, minutes) in [
        ('1', 1),
        ('43200', 43200),
        (' 00090 ', 90),
        ('\u0669\u0660', 90),
        ('\u06f9\u06f0', 90),
      ]) {
        final draft = fixture.draft().copyWith(duration: input);
        expect(draft.durationMinutes, minutes);
        expect(draft.validate(), isNull);
      }
      for (final input in [
        '',
        '0',
        '-1',
        '+1',
        '43201',
        '100000',
        '1.0',
        '1\u066b0',
        '1e2',
        '1,000',
        '1 000',
      ]) {
        final draft = fixture.draft().copyWith(duration: input);
        expect(draft.durationMinutes, isNull, reason: input);
        expect(draft.validate(), 'marketplace.errors.duration', reason: input);
      }
    });

    test('notes use trimmed Unicode scalar limits, not UTF-16 length', () {
      final scalar = String.fromCharCode(0x20000);
      for (final text in ['', ' \t ', 'x' * 1000]) {
        expect(fixture.draft().copyWith(notes: text).validate(), isNull);
      }
      expect(
        fixture.draft().copyWith(notes: ' ${scalar * 1000}\n').validate(),
        isNull,
      );
      expect(
        fixture.draft().copyWith(notes: scalar * 1001).validate(),
        'marketplace.errors.notes',
      );
    });

    test(
      'requires canonical request UUIDv4 and bounded expected revisions',
      () {
        for (final id in [
          '',
          '../${fixture.requestId}',
          ' ${fixture.requestId}',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'.toUpperCase(),
          '55555555-5555-1555-8555-555555555555',
          '55555555-5555-4555-7555-555555555555',
        ]) {
          expect(
            fixture.draft(request: id).validate(),
            'marketplace.errors.invalid',
          );
        }
        for (final revision in [-1, 2147483647]) {
          expect(
            fixture.draft(revision: revision).validate(),
            'marketplace.errors.invalid',
          );
        }
        expect(fixture.draft(revision: 2147483646).validate(), isNull);
      },
    );

    test('copies retain identity/revision and match normalized terms only', () {
      final quote = ProviderQuote.fromJson(fixture.quote(revision: 3));
      final draft = QuoteDraft.fromQuote(quote);
      expect(draft.amount, '123.45');
      expect(draft.duration, '90');
      expect(draft.expectedRevision, 3);
      expect(draft.copyWith(), draft);
      expect(draft.copyWith(amount: '1').requestId, fixture.requestId);
      expect(draft.copyWith(amount: '1').expectedRevision, 3);
      expect(
        draft.copyWith(notes: ' ${fixture.notes} ').matches(quote),
        isTrue,
      );
      for (final changed in [
        quote.copyWith(amountMinor: 12346),
        quote.copyWith(durationMinutes: 91),
        quote.copyWith(notes: 'Changed terms'),
        ProviderQuote.fromJson(fixture.quote(request: fixture.id(1))),
      ]) {
        expect(draft.matches(changed), isFalse);
      }
      expect(draft.toString(), isNot(contains(fixture.notes)));
      expect(draft.toString(), isNot(contains(draft.amount)));
    });
  });

  group('Safe marketplace projections', () {
    test(
      'listing selects only published fields and uses a UTC keyset cursor',
      () {
        final json = {
          ...fixture.listing(),
          'published_at': '2026-11-09T14:00:00+02:00',
          'title': fixture.privateTitle,
          'description': fixture.privateDescription,
          'address': fixture.privateAddress,
          'customer_id': fixture.customerId,
          'photos': [
            {'storage_path': 'private/path.jpg'},
          ],
        };
        final listing = MarketplaceListing.fromJson(json);
        expect(listing, MarketplaceListing.fromJson(fixture.listing()));
        expect(listing.summary, fixture.summary);
        expect(listing.categoryName('ar'), 'Plumbing AR');
        expect(listing.categoryName('en'), 'Plumbing');
        expect(listing.categoryName('fr'), 'Plumbing');
        expect(listing.publishedAt.isUtc, isTrue);
        expect(
          listing.cursor,
          MarketplaceCursor(createdAt: fixture.instant, id: fixture.requestId),
        );
        json['summary'] = 'Changed after parsing';
        expect(listing.summary, fixture.summary);
        expect(listing.props, isNot(contains(fixture.privateAddress)));
        expect(listing.props, isNot(contains(fixture.customerId)));
        expect(listing.toString(), isNot(contains(fixture.summary)));
        final assigned = listing.withStatus(ServiceRequestStatus.assigned);
        expect(assigned.summary, listing.summary);
        expect(assigned.cursor, listing.cursor);
        expect(listing.requestStatus, ServiceRequestStatus.open);
      },
    );

    test(
      'listing rejects invalid identity, text bounds and unknown states',
      () {
        for (final (field, value) in <(String, Object?)>[
          ('request_id', 'not-a-uuid'),
          ('category_id', ''),
          ('category_name_en', ''),
          ('category_name_ar', ''),
          ('category_icon_key', ''),
          ('summary', 'too short'),
          ('summary', ' ${fixture.summary}'),
          ('summary', 'x' * 1001),
          ('city', 'x'),
          ('city', 'Cairo '),
          ('city', 'x' * 101),
          ('published_at', 'not-a-time'),
        ]) {
          expect(
            () => MarketplaceListing.fromJson({
              ...fixture.listing(),
              field: value,
            }),
            throwsFormatException,
            reason: field,
          );
        }
        expect(
          () => MarketplaceListing.fromJson({
            ...fixture.listing(),
            'request_status': 'booked',
          }),
          throwsArgumentError,
        );
        expect(
          () =>
              MarketplaceListing.fromJson(fixture.listing()..remove('summary')),
          throwsA(isA<TypeError>()),
        );
      },
    );

    test('quote wire states are strict and amount display preserves cents', () {
      for (final status in QuoteStatus.values) {
        final quote = ProviderQuote.fromJson(fixture.quote(status: status));
        expect(quote.status, status);
        expect(QuoteStatus.parse(status.wireName), status);
        expect(quote.cursor.id, quote.id);
        expect(quote.cursor.createdAt, fixture.instant);
        expect(quote.copyWith(), quote);
        expect(quote.toString(), isNot(contains(fixture.notes)));
      }
      for (final (amount, text) in [
        (1, '0.01'),
        (100, '1.00'),
        (100000000, '1000000.00'),
      ]) {
        final quote = ProviderQuote.fromJson(fixture.quote(amount: amount));
        expect(quote.amountText, text);
        expect(QuoteDraft.fromQuote(quote).amountMinor, amount);
      }
      for (final state in ['notSelected', 'PENDING', 'booked', ' pending']) {
        expect(() => QuoteStatus.parse(state), throwsStateError);
      }
    });

    test(
      'quote parsing rejects malformed UUIDs, prices, revisions and timestamps',
      () {
        for (final (field, value) in <(String, Object?)>[
          ('id', fixture.quoteId.toUpperCase().replaceFirst('6', 'G')),
          ('request_id', 'bad'),
          ('provider_id', ''),
          ('provider_name', 'x'),
          ('provider_name', ' Provider'),
          ('provider_name', 'x' * 81),
          ('amount_minor', 0),
          ('amount_minor', 100000001),
          ('currency', 'USD'),
          ('duration_minutes', 0),
          ('duration_minutes', 43201),
          ('revision', 0),
          ('revision', 2147483648),
          ('notes', 'x' * 1001),
          ('updated_at', '2026-11-08T12:00:00Z'),
        ]) {
          expect(
            () => ProviderQuote.fromJson({...fixture.quote(), field: value}),
            throwsFormatException,
            reason: field,
          );
        }
        for (final value in [123.45, '12345', null]) {
          expect(
            () => ProviderQuote.fromJson({
              ...fixture.quote(),
              'amount_minor': value,
            }),
            throwsA(isA<TypeError>()),
          );
        }
      },
    );

    test(
      'quote notes must be canonical, not silently whitespace-normalized',
      () {
        expect(
          () => ProviderQuote.fromJson(
            fixture.quote(text: ' ${fixture.notes}\n'),
          ),
          throwsFormatException,
        );
      },
    );

    test('maximum SQL revision remains readable even when no further edit is possible', () {
      final quote = ProviderQuote.fromJson(fixture.quote(revision: 2147483647));
      expect(quote.revision, 2147483647);
      expect(
        QuoteDraft.fromQuote(quote).validate(),
        'marketplace.errors.invalid',
      );
      final job = ServiceJob.fromJson(fixture.job(quoteRevision: 2147483647));
      expect(job.quoteRevision, quote.revision);
      expect(job.roleFor(fixture.customerId), UserRole.customer);
      expect(job.roleFor(fixture.providerId), UserRole.provider);
      expect(job.roleFor(fixture.otherId), isNull);
    });

    test(
      'opportunity refuses cross-request quotes and quoting a closed request',
      () {
        final safe = QuoteOpportunity.fromJson({
          ...fixture.opportunity(ownQuote: fixture.quote()),
          'request': const {
            'title': fixture.privateTitle,
            'address': fixture.privateAddress,
          },
        });
        expect(
          safe,
          QuoteOpportunity.fromJson(
            fixture.opportunity(ownQuote: fixture.quote()),
          ),
        );
        expect(safe.toString(), isNot(contains(fixture.privateAddress)));
        expect(
          () => QuoteOpportunity.fromJson(
            fixture.opportunity(
              ownQuote: fixture.quote(request: fixture.id(1)),
            ),
          ),
          throwsFormatException,
        );
        for (final status in [
          ServiceRequestStatus.assigned,
          ServiceRequestStatus.cancelled,
        ]) {
          expect(
            () =>
                QuoteOpportunity.fromJson(fixture.opportunity(status: status)),
            throwsFormatException,
          );
          expect(
            QuoteOpportunity.fromJson(
              fixture.opportunity(status: status, canQuote: false),
            ).canQuote,
            isFalse,
          );
        }
      },
    );

    test('pages and quote books defensively copy collections', () {
      final quote = ProviderQuote.fromJson(fixture.quote());
      final items = [quote];
      final page = MarketplacePage(
        items: items,
        hasMore: true,
        eligible: false,
      );
      final book = CustomerQuoteBook(
        requestId: fixture.requestId,
        customerId: fixture.customerId,
        requestStatus: ServiceRequestStatus.open,
        quotes: items,
        hasMore: false,
      );
      items.clear();
      expect(page.items, [quote]);
      expect(page.hasMore, isTrue);
      expect(page.eligible, isFalse);
      expect(book.quotes, [quote]);
      expect(() => page.items.clear(), throwsUnsupportedError);
      expect(() => book.quotes.clear(), throwsUnsupportedError);
      final json = fixture.book(quotes: [fixture.quote()]);
      final parsed = CustomerQuoteBook.fromJson(json);
      (json['quotes'] as List).clear();
      expect(parsed.quotes, [quote]);
      expect(() => parsed.quotes.clear(), throwsUnsupportedError);
    });

    test(
      'quote books validate owner, request, duplicate quotes and assigned job',
      () {
        for (final change in <Map<String, dynamic>>[
          {'request_id': 'bad'},
          {'customer_id': ''},
          {'listing': fixture.listing(request: fixture.id(1))},
          {'listing': fixture.listing(status: ServiceRequestStatus.cancelled)},
          {
            'quotes': [fixture.quote(request: fixture.id(1))],
          },
          {
            'quotes': [fixture.quote(), fixture.quote()],
          },
          {
            'quotes': [fixture.quote(), fixture.quote(id: fixture.id(1))],
          },
          {
            'listing': null,
            'quotes': [fixture.quote()],
          },
          {'request_status': 'assigned', 'listing': null},
          {'job': fixture.job()},
        ]) {
          expect(
            () => CustomerQuoteBook.fromJson({...fixture.book(), ...change}),
            throwsFormatException,
            reason: change.keys.join(','),
          );
        }
        for (final job in [
          fixture.job(customer: fixture.otherId),
          fixture.job(request: fixture.id(1)),
        ]) {
          expect(
            () => CustomerQuoteBook.fromJson(
              fixture.book(
                status: ServiceRequestStatus.assigned,
                serviceJob: job,
              ),
            ),
            throwsFormatException,
          );
        }
        final assigned = CustomerQuoteBook.fromJson(
          fixture.book(
            status: ServiceRequestStatus.assigned,
            quotes: [fixture.quote(status: QuoteStatus.accepted)],
            serviceJob: fixture.job(),
          ),
        );
        expect(assigned.job!.quoteId, assigned.quotes.single.id);
        expect(assigned.toString(), isNot(contains(fixture.privateAddress)));
      },
    );
  });

  group('ServiceJob participant history', () {
    test('role-specific transitions prohibit work cancellation and provider completion', () {
      expect(JobStatus.selected.actionsFor(UserRole.provider), [
        JobStatus.onTheWay,
        JobStatus.inProgress,
        JobStatus.cancelled,
      ]);
      expect(JobStatus.onTheWay.actionsFor(UserRole.provider), [
        JobStatus.inProgress,
        JobStatus.cancelled,
      ]);
      expect(JobStatus.inProgress.actionsFor(UserRole.provider), [
        JobStatus.awaitingConfirmation,
      ]);
      expect(JobStatus.awaitingConfirmation.actionsFor(UserRole.customer), [
        JobStatus.completed,
      ]);
      expect(JobStatus.selected.actionsFor(UserRole.customer), [
        JobStatus.cancelled,
      ]);
      expect(JobStatus.onTheWay.actionsFor(UserRole.customer), [
        JobStatus.cancelled,
      ]);
      for (final role in UserRole.values) {
        for (final status in [JobStatus.completed, JobStatus.cancelled]) {
          expect(status.actionsFor(role), isEmpty);
          expect(status.isTerminal, isTrue);
        }
      }
      expect(JobStatus.inProgress.actionsFor(UserRole.customer), isEmpty);
      expect(
        JobStatus.awaitingConfirmation.actionsFor(UserRole.provider),
        isEmpty,
      );
      expect(JobStatus.selected.isTerminal, isFalse);
      for (final state in [
        'onTheWay',
        'awaiting_customer_confirmation',
        'complete',
        'SELECTED',
      ]) {
        expect(() => JobStatus.parse(state), throwsStateError);
      }
    });

    test(
      'accepts full lifecycle, optional on-the-way and prework cancellation',
      () {
        for (final statuses in [
          [JobStatus.selected],
          [
            JobStatus.selected,
            JobStatus.onTheWay,
            JobStatus.inProgress,
            JobStatus.awaitingConfirmation,
            JobStatus.completed,
          ],
          [
            JobStatus.selected,
            JobStatus.inProgress,
            JobStatus.awaitingConfirmation,
            JobStatus.completed,
          ],
          [JobStatus.selected, JobStatus.cancelled],
          [JobStatus.selected, JobStatus.onTheWay, JobStatus.cancelled],
        ]) {
          final job = ServiceJob.fromJson(fixture.job(statuses: statuses));
          expect(job.status, statuses.last);
          expect(job.history.map((event) => event.status), statuses);
          expect(job.history.first.actorId, fixture.customerId);
          expect(job.history.last.createdAt, job.updatedAt);
          expect(job.cursor.createdAt, fixture.instant);
          expect(job.cursor.id, fixture.jobId);
          expect(job.toString(), isNot(contains(fixture.privateAddress)));
          expect(
            job.history.first.toString(),
            isNot(contains(fixture.customerId)),
          );
        }
      },
    );

    test(
      'history snapshots are immutable and transitions retain accepted terms',
      () {
        final json = fixture.job();
        final initial = ServiceJob.fromJson(json);
        (json['history'] as List).clear();
        expect(initial.history, hasLength(1));
        expect(() => initial.history.clear(), throwsUnsupportedError);
        final next = initial.withTransition(
          JobHistoryEntry(
            id: fixture.id(999),
            fromStatus: JobStatus.selected,
            status: JobStatus.inProgress,
            actorId: fixture.providerId,
            createdAt: fixture.instant.add(const Duration(minutes: 1)),
          ),
        );
        expect(initial.status, JobStatus.selected);
        expect(initial.history, hasLength(1));
        expect(next.history, hasLength(2));
        expect(() => next.history.clear(), throwsUnsupportedError);
        expect(next.id, initial.id);
        expect(next.quoteId, initial.quoteId);
        expect(next.quoteRevision, initial.quoteRevision);
        expect(next.amountMinor, initial.amountMinor);
        expect(next.currency, initial.currency);
        expect(next.durationMinutes, initial.durationMinutes);
        expect(next.notes, initial.notes);
        expect(next.address, initial.address);
        expect(next.createdAt, initial.createdAt);
      },
    );

    test('job rejects invalid identity, amounts, private field bounds and timestamps', () {
      for (final (field, value) in <(String, Object?)>[
        ('id', 'bad'),
        ('request_id', 'bad'),
        ('quote_id', 'bad'),
        ('customer_id', ''),
        ('provider_id', fixture.customerId),
        ('provider_name', 'x'),
        ('quote_revision', 0),
        ('quote_revision', 2147483648),
        ('amount_minor', 0),
        ('amount_minor', 100000001),
        ('currency', 'USD'),
        ('duration_minutes', 0),
        ('duration_minutes', 43201),
        ('notes', ' untrimmed '),
        ('notes', 'x' * 1001),
        ('request_title', 'x' * 121),
        ('request_description', 'short'),
        ('city', 'x'),
        ('address', 'x' * 501),
        ('updated_at', '2026-11-08T12:00:00Z'),
      ]) {
        expect(
          () => ServiceJob.fromJson({...fixture.job(), field: value}),
          throwsFormatException,
          reason: field,
        );
      }
      final job = ServiceJob.fromJson({
        ...fixture.job(),
        'preferred_at': '2026-11-10T14:00:00+02:00',
      });
      expect(job.preferredAt, DateTime.utc(2026, 11, 10, 12));
      expect(job.preferredAt!.isUtc, isTrue);
    });

    test('history rejects wrong actors, broken edges, duplicates and snapshot disagreement', () {
      final valid = fixture.job(
        statuses: [JobStatus.selected, JobStatus.inProgress],
      );
      final history = (valid['history'] as List).cast<Map<String, dynamic>>();
      for (final events in <List<Map<String, dynamic>>>[
        [],
        [history.first, history.first],
        [
          {...history.first, 'id': 'bad'},
          history.last,
        ],
        [
          {...history.first, 'actor_id': fixture.providerId},
          history.last,
        ],
        [
          {...history.first, 'from_status': 'selected'},
          history.last,
        ],
        [
          {...history.first, 'created_at': '2026-11-09T11:59:59Z'},
          history.last,
        ],
        [
          history.first,
          {...history.last, 'actor_id': fixture.otherId},
        ],
        [
          history.first,
          {...history.last, 'actor_id': fixture.customerId},
        ],
        [
          history.first,
          {...history.last, 'from_status': 'on_the_way'},
        ],
        [
          history.first,
          {...history.last, 'created_at': '2026-11-09T11:59:59Z'},
        ],
        [history.first],
        List.generate(
          6,
          (index) => {...history.first, 'id': fixture.id(index)},
        ),
      ]) {
        expect(
          () => ServiceJob.fromJson({...valid, 'history': events}),
          throwsFormatException,
        );
      }
      for (final statuses in [
        [JobStatus.selected, JobStatus.awaitingConfirmation],
        [JobStatus.selected, JobStatus.inProgress, JobStatus.cancelled],
        [JobStatus.selected, JobStatus.cancelled, JobStatus.inProgress],
      ]) {
        expect(
          () => ServiceJob.fromJson(fixture.job(statuses: statuses)),
          throwsFormatException,
        );
      }
      final completed = fixture.job(
        statuses: [
          JobStatus.selected,
          JobStatus.inProgress,
          JobStatus.awaitingConfirmation,
          JobStatus.completed,
        ],
      );
      (completed['history'] as List).last['actor_id'] = fixture.providerId;
      expect(() => ServiceJob.fromJson(completed), throwsFormatException);
    });
  });
}
