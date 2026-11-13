import 'package:equatable/equatable.dart';

import 'service_request.dart';
import 'user_model.dart';

bool _text(String value, int min, int max) =>
    value.trim() == value &&
    value.runes.length >= min &&
    value.runes.length <= max;

DateTime _date(Map<String, dynamic> json, String key) =>
    DateTime.parse(json[key] as String).toUtc();

class MarketplaceCursor extends Equatable {
  const MarketplaceCursor({required this.createdAt, required this.id});
  final DateTime createdAt;
  final String id;

  @override
  List<Object> get props => [createdAt, id];
}

class MarketplacePage<T> {
  MarketplacePage({
    required List<T> items,
    required this.hasMore,
    this.eligible = true,
  }) : items = List.unmodifiable(items);

  final List<T> items;
  final bool hasMore;
  final bool eligible;
}

/// Only the explicitly published fields, never the private M6 request aggregate.
class MarketplaceListing extends Equatable {
  const MarketplaceListing({
    required this.requestId,
    required this.categoryId,
    required this.categoryNameEn,
    required this.categoryNameAr,
    required this.categoryIconKey,
    required this.summary,
    required this.city,
    required this.publishedAt,
    required this.requestStatus,
  });

  factory MarketplaceListing.fromJson(Map<String, dynamic> json) {
    final value = MarketplaceListing(
      requestId: json['request_id'] as String,
      categoryId: json['category_id'] as String,
      categoryNameEn: json['category_name_en'] as String,
      categoryNameAr: json['category_name_ar'] as String,
      categoryIconKey: json['category_icon_key'] as String,
      summary: json['summary'] as String,
      city: json['city'] as String,
      publishedAt: _date(json, 'published_at'),
      requestStatus: ServiceRequestStatus.values.byName(
        json['request_status'] as String,
      ),
    );
    if (!ServiceRequestDraft.validId(value.requestId) ||
        value.categoryId.isEmpty ||
        value.categoryNameEn.isEmpty ||
        value.categoryNameAr.isEmpty ||
        value.categoryIconKey.isEmpty ||
        !_text(value.summary, 10, 1000) ||
        !_text(value.city, 2, 100)) {
      throw const FormatException('Invalid marketplace listing.');
    }
    return value;
  }

  final String requestId;
  final String categoryId;
  final String categoryNameEn;
  final String categoryNameAr;
  final String categoryIconKey;
  final String summary;
  final String city;
  final DateTime publishedAt;
  final ServiceRequestStatus requestStatus;

  String categoryName(String languageCode) =>
      languageCode == 'ar' ? categoryNameAr : categoryNameEn;
  MarketplaceCursor get cursor =>
      MarketplaceCursor(createdAt: publishedAt, id: requestId);

  MarketplaceListing withStatus(ServiceRequestStatus status) =>
      MarketplaceListing(
        requestId: requestId,
        categoryId: categoryId,
        categoryNameEn: categoryNameEn,
        categoryNameAr: categoryNameAr,
        categoryIconKey: categoryIconKey,
        summary: summary,
        city: city,
        publishedAt: publishedAt,
        requestStatus: status,
      );

  @override
  bool get stringify => false;
  @override
  List<Object> get props => [
    requestId,
    categoryId,
    categoryNameEn,
    categoryNameAr,
    categoryIconKey,
    summary,
    city,
    publishedAt,
    requestStatus,
  ];
}

enum QuoteStatus {
  pending('pending'),
  withdrawn('withdrawn'),
  accepted('accepted'),
  notSelected('not_selected'),
  cancelled('cancelled');

  const QuoteStatus(this.wireName);
  final String wireName;
  static QuoteStatus parse(String value) =>
      values.singleWhere((status) => status.wireName == value);
}

class QuoteDraft extends Equatable {
  const QuoteDraft({
    required this.requestId,
    this.amount = '',
    this.duration = '',
    this.notes = '',
    this.expectedRevision = 0,
  });

  factory QuoteDraft.fromQuote(ProviderQuote quote) => QuoteDraft(
    requestId: quote.requestId,
    amount: quote.amountText,
    duration: quote.durationMinutes.toString(),
    notes: quote.notes,
    expectedRevision: quote.revision,
  );

  static const currency = 'EGP';
  static const maxAmountMinor = 100000000;
  static const maxDurationMinutes = 43200;

  final String requestId;
  final String amount;
  final String duration;
  final String notes;
  final int expectedRevision;

  // Parse decimal input without floating-point rounding or ambiguous grouping.
  static String _digits(String input) => String.fromCharCodes(
    input.trim().runes.map((rune) {
      if (rune >= 0x660 && rune <= 0x669) return rune - 0x660 + 0x30;
      if (rune >= 0x6f0 && rune <= 0x6f9) return rune - 0x6f0 + 0x30;
      return rune == 0x66b ? 0x2e : rune;
    }),
  );

  int? get amountMinor {
    final value = _digits(amount);
    if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(value)) return null;
    final parts = value.split('.');
    final minor =
        int.parse(parts.first) * 100 +
        (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
    return minor > 0 && minor <= maxAmountMinor ? minor : null;
  }

  int? get durationMinutes {
    final value = _digits(duration);
    if (!RegExp(r'^\d{1,5}$').hasMatch(value)) return null;
    final minutes = int.parse(value);
    return minutes > 0 && minutes <= maxDurationMinutes ? minutes : null;
  }

  String? validate() {
    if (!ServiceRequestDraft.validId(requestId) ||
        expectedRevision < 0 ||
        expectedRevision >= 2147483647) {
      return 'marketplace.errors.invalid';
    }
    if (amountMinor == null) return 'marketplace.errors.amount';
    if (durationMinutes == null) return 'marketplace.errors.duration';
    if (notes.trim().runes.length > 1000) return 'marketplace.errors.notes';
    return null;
  }

  QuoteDraft copyWith({String? amount, String? duration, String? notes}) =>
      QuoteDraft(
        requestId: requestId,
        amount: amount ?? this.amount,
        duration: duration ?? this.duration,
        notes: notes ?? this.notes,
        expectedRevision: expectedRevision,
      );

  bool matches(ProviderQuote quote) =>
      quote.requestId == requestId &&
      quote.amountMinor == amountMinor &&
      quote.currency == currency &&
      quote.durationMinutes == durationMinutes &&
      quote.notes == notes.trim();

  @override
  bool get stringify => false;
  @override
  List<Object> get props => [
    requestId,
    amount,
    duration,
    notes,
    expectedRevision,
  ];
}

class ProviderQuote extends Equatable {
  const ProviderQuote({
    required this.id,
    required this.requestId,
    required this.providerId,
    required this.providerName,
    required this.amountMinor,
    required this.currency,
    required this.durationMinutes,
    required this.notes,
    required this.revision,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ProviderQuote.fromJson(Map<String, dynamic> json) {
    final quote = ProviderQuote(
      id: json['id'] as String,
      requestId: json['request_id'] as String,
      providerId: json['provider_id'] as String,
      providerName: json['provider_name'] as String,
      amountMinor: json['amount_minor'] as int,
      currency: json['currency'] as String,
      durationMinutes: json['duration_minutes'] as int,
      notes: json['notes'] as String,
      revision: json['revision'] as int,
      status: QuoteStatus.parse(json['status'] as String),
      createdAt: _date(json, 'created_at'),
      updatedAt: _date(json, 'updated_at'),
    );
    if (!ServiceRequestDraft.validId(quote.id) ||
        quote.providerId.isEmpty ||
        !_text(quote.providerName, 2, 80) ||
        quote.currency != QuoteDraft.currency ||
        !_text(quote.notes, 0, 1000) ||
        quote.revision < 1 ||
        quote.revision > 2147483647 ||
        !ServiceRequestDraft.validId(quote.requestId) ||
        quote.amountMinor < 1 ||
        quote.amountMinor > QuoteDraft.maxAmountMinor ||
        quote.durationMinutes < 1 ||
        quote.durationMinutes > QuoteDraft.maxDurationMinutes ||
        quote.updatedAt.isBefore(quote.createdAt)) {
      throw const FormatException('Invalid provider quote.');
    }
    return quote;
  }

  final String id;
  final String requestId;
  final String providerId;
  final String providerName;
  final int amountMinor;
  final String currency;
  final int durationMinutes;
  final String notes;
  final int revision;
  final QuoteStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get amountText =>
      '${amountMinor ~/ 100}.${(amountMinor % 100).toString().padLeft(2, '0')}';
  MarketplaceCursor get cursor =>
      MarketplaceCursor(createdAt: createdAt, id: id);

  ProviderQuote copyWith({
    int? amountMinor,
    int? durationMinutes,
    String? notes,
    int? revision,
    QuoteStatus? status,
    DateTime? updatedAt,
  }) => ProviderQuote(
    id: id,
    requestId: requestId,
    providerId: providerId,
    providerName: providerName,
    amountMinor: amountMinor ?? this.amountMinor,
    currency: currency,
    durationMinutes: durationMinutes ?? this.durationMinutes,
    notes: notes ?? this.notes,
    revision: revision ?? this.revision,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool get stringify => false;
  @override
  List<Object> get props => [
    id,
    requestId,
    providerId,
    providerName,
    amountMinor,
    currency,
    durationMinutes,
    notes,
    revision,
    status,
    createdAt,
    updatedAt,
  ];
}

class QuoteOpportunity extends Equatable {
  const QuoteOpportunity({
    required this.listing,
    this.quote,
    required this.canQuote,
  });

  factory QuoteOpportunity.fromJson(Map<String, dynamic> json) {
    final value = QuoteOpportunity(
      listing: MarketplaceListing.fromJson(
        json['listing'] as Map<String, dynamic>,
      ),
      quote: json['quote'] == null
          ? null
          : ProviderQuote.fromJson(json['quote'] as Map<String, dynamic>),
      canQuote: json['can_quote'] as bool,
    );
    if ((value.quote != null &&
            value.quote!.requestId != value.listing.requestId) ||
        (value.canQuote &&
            value.listing.requestStatus != ServiceRequestStatus.open)) {
      throw const FormatException('Invalid quote opportunity.');
    }
    return value;
  }

  final MarketplaceListing listing;
  final ProviderQuote? quote;
  final bool canQuote;

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [listing, quote, canQuote];
}

enum JobStatus {
  selected('selected'),
  onTheWay('on_the_way'),
  inProgress('in_progress'),
  awaitingConfirmation('awaiting_confirmation'),
  completed('completed'),
  cancelled('cancelled');

  const JobStatus(this.wireName);
  final String wireName;
  static JobStatus parse(String value) =>
      values.singleWhere((status) => status.wireName == value);

  bool get isTerminal => this == completed || this == cancelled;

  List<JobStatus> actionsFor(UserRole role) => switch ((role, this)) {
    (UserRole.provider, selected) => const [onTheWay, inProgress, cancelled],
    (UserRole.provider, onTheWay) => const [inProgress, cancelled],
    (UserRole.provider, inProgress) => const [awaitingConfirmation],
    (UserRole.customer, selected || onTheWay) => const [cancelled],
    (UserRole.customer, awaitingConfirmation) => const [completed],
    _ => const [],
  };
}

class JobHistoryEntry extends Equatable {
  const JobHistoryEntry({
    required this.id,
    this.fromStatus,
    required this.status,
    required this.actorId,
    required this.createdAt,
  });

  factory JobHistoryEntry.fromJson(Map<String, dynamic> json) =>
      JobHistoryEntry(
        id: json['id'] as String,
        fromStatus: json['from_status'] == null
            ? null
            : JobStatus.parse(json['from_status'] as String),
        status: JobStatus.parse(json['status'] as String),
        actorId: json['actor_id'] as String,
        createdAt: _date(json, 'created_at'),
      );

  final String id;
  final JobStatus? fromStatus;
  final JobStatus status;
  final String actorId;
  final DateTime createdAt;

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [id, fromStatus, status, actorId, createdAt];
}

class ServiceJob extends Equatable {
  ServiceJob({
    required this.id,
    required this.requestId,
    required this.quoteId,
    required this.quoteRevision,
    required this.customerId,
    required this.providerId,
    required this.providerName,
    required this.amountMinor,
    required this.currency,
    required this.durationMinutes,
    required this.notes,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.requestTitle,
    required this.requestDescription,
    required this.city,
    required this.address,
    this.preferredAt,
    required List<JobHistoryEntry> history,
  }) : history = List.unmodifiable(history);

  factory ServiceJob.fromJson(Map<String, dynamic> json) {
    final job = ServiceJob(
      id: json['id'] as String,
      requestId: json['request_id'] as String,
      quoteId: json['quote_id'] as String,
      quoteRevision: json['quote_revision'] as int,
      customerId: json['customer_id'] as String,
      providerId: json['provider_id'] as String,
      providerName: json['provider_name'] as String,
      amountMinor: json['amount_minor'] as int,
      currency: json['currency'] as String,
      durationMinutes: json['duration_minutes'] as int,
      notes: json['notes'] as String,
      status: JobStatus.parse(json['status'] as String),
      createdAt: _date(json, 'created_at'),
      updatedAt: _date(json, 'updated_at'),
      requestTitle: json['request_title'] as String,
      requestDescription: json['request_description'] as String,
      city: json['city'] as String,
      address: json['address'] as String,
      preferredAt: json['preferred_at'] == null
          ? null
          : _date(json, 'preferred_at'),
      history: (json['history'] as List)
          .map((item) => JobHistoryEntry.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
    if (![
          job.id,
          job.requestId,
          job.quoteId,
        ].every(ServiceRequestDraft.validId) ||
        job.customerId.isEmpty ||
        job.providerId.isEmpty ||
        job.customerId == job.providerId ||
        job.quoteRevision < 1 ||
        job.quoteRevision > 2147483647 ||
        !_text(job.providerName, 2, 80) ||
        job.amountMinor < 1 ||
        job.amountMinor > QuoteDraft.maxAmountMinor ||
        job.currency != QuoteDraft.currency ||
        job.durationMinutes < 1 ||
        job.durationMinutes > QuoteDraft.maxDurationMinutes ||
        !_text(job.notes, 0, 1000) ||
        !_text(job.requestTitle, 5, 120) ||
        !_text(job.requestDescription, 10, 2000) ||
        !_text(job.city, 2, 100) ||
        !_text(job.address, 5, 500) ||
        job.updatedAt.isBefore(job.createdAt) ||
        job.history.isEmpty ||
        job.history.length > 5 ||
        job.history.map((event) => event.id).toSet().length !=
            job.history.length ||
        job.history.last.status != job.status ||
        !job.history.last.createdAt.isAtSameMomentAs(job.updatedAt)) {
      throw const FormatException('Invalid service job.');
    }
    JobHistoryEntry? previous;
    for (final event in job.history) {
      final role = event.actorId == job.customerId
          ? UserRole.customer
          : UserRole.provider;
      if (!ServiceRequestDraft.validId(event.id) ||
          (event.actorId != job.customerId &&
              event.actorId != job.providerId) ||
          event.fromStatus != previous?.status ||
          (previous == null &&
              (event.status != JobStatus.selected ||
                  role != UserRole.customer ||
                  !event.createdAt.isAtSameMomentAs(job.createdAt))) ||
          (previous != null &&
              (!previous.status.actionsFor(role).contains(event.status) ||
                  event.createdAt.isBefore(previous.createdAt)))) {
        throw const FormatException('Invalid job history.');
      }
      previous = event;
    }
    return job;
  }

  final String id;
  final String requestId;
  final String quoteId;
  final int quoteRevision;
  final String customerId;
  final String providerId;
  final String providerName;
  final int amountMinor;
  final String currency;
  final int durationMinutes;
  final String notes;
  final JobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String requestTitle;
  final String requestDescription;
  final String city;
  final String address;
  final DateTime? preferredAt;
  final List<JobHistoryEntry> history;

  MarketplaceCursor get cursor =>
      MarketplaceCursor(createdAt: createdAt, id: id);

  UserRole? roleFor(String userId) {
    if (userId == customerId) return UserRole.customer;
    if (userId == providerId) return UserRole.provider;
    return null;
  }

  ServiceJob withTransition(JobHistoryEntry event) => ServiceJob(
    id: id,
    requestId: requestId,
    quoteId: quoteId,
    quoteRevision: quoteRevision,
    customerId: customerId,
    providerId: providerId,
    providerName: providerName,
    amountMinor: amountMinor,
    currency: currency,
    durationMinutes: durationMinutes,
    notes: notes,
    status: event.status,
    createdAt: createdAt,
    updatedAt: event.createdAt,
    requestTitle: requestTitle,
    requestDescription: requestDescription,
    city: city,
    address: address,
    preferredAt: preferredAt,
    history: [...history, event],
  );

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    id,
    requestId,
    quoteId,
    quoteRevision,
    customerId,
    providerId,
    providerName,
    amountMinor,
    currency,
    durationMinutes,
    notes,
    status,
    createdAt,
    updatedAt,
    requestTitle,
    requestDescription,
    city,
    address,
    preferredAt,
    history,
  ];
}

class CustomerQuoteBook extends Equatable {
  CustomerQuoteBook({
    required this.requestId,
    required this.customerId,
    required this.requestStatus,
    this.listing,
    required List<ProviderQuote> quotes,
    required this.hasMore,
    this.job,
  }) : quotes = List.unmodifiable(quotes);

  factory CustomerQuoteBook.fromJson(Map<String, dynamic> json) {
    final book = CustomerQuoteBook(
      requestId: json['request_id'] as String,
      customerId: json['customer_id'] as String,
      requestStatus: ServiceRequestStatus.values.byName(
        json['request_status'] as String,
      ),
      listing: json['listing'] == null
          ? null
          : MarketplaceListing.fromJson(
              json['listing'] as Map<String, dynamic>,
            ),
      quotes: (json['quotes'] as List)
          .map((item) => ProviderQuote.fromJson(item as Map<String, dynamic>))
          .toList(),
      hasMore: json['has_more'] as bool,
      job: json['job'] == null
          ? null
          : ServiceJob.fromJson(json['job'] as Map<String, dynamic>),
    );
    if (!ServiceRequestDraft.validId(book.requestId) ||
        book.customerId.isEmpty ||
        (book.listing != null &&
            (book.listing!.requestId != book.requestId ||
                book.listing!.requestStatus != book.requestStatus)) ||
        book.quotes.any((quote) => quote.requestId != book.requestId) ||
        (book.listing == null &&
            (book.quotes.isNotEmpty || book.job != null)) ||
        book.quotes.map((quote) => quote.id).toSet().length !=
            book.quotes.length ||
        book.quotes.map((quote) => quote.providerId).toSet().length !=
            book.quotes.length ||
        (book.job != null &&
            (book.job!.requestId != book.requestId ||
                book.job!.customerId != book.customerId ||
                book.requestStatus != ServiceRequestStatus.assigned)) ||
        (book.requestStatus == ServiceRequestStatus.assigned &&
            book.job == null)) {
      throw const FormatException('Invalid customer quotes.');
    }
    return book;
  }

  final String requestId;
  final String customerId;
  final ServiceRequestStatus requestStatus;
  final MarketplaceListing? listing;
  final List<ProviderQuote> quotes;
  final bool hasMore;
  final ServiceJob? job;

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    requestId,
    customerId,
    requestStatus,
    listing,
    quotes,
    hasMore,
    job,
  ];
}
