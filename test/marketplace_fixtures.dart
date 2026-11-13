import 'package:salahly/src/data/models/marketplace.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/models/user_model.dart';

const customerId = '11111111-1111-4111-8111-111111111111';
const providerId = '22222222-2222-4222-8222-222222222222';
const otherId = '33333333-3333-4333-8333-333333333333';
const categoryId = '44444444-4444-4444-8444-444444444444';
const requestId = '55555555-5555-4555-8555-555555555555';
const quoteId = '66666666-6666-4666-8666-666666666666';
const jobId = '77777777-7777-4777-8777-777777777777';
const summary = 'A kitchen tap needs a replacement washer.';
const notes = 'Includes the replacement washer.';
const privateTitle = 'Private kitchen problem';
const privateDescription = 'Private details that were not published.';
const privateAddress = '17 Private Street, apartment 42';
final instant = DateTime.utc(2026, 11, 9, 12);

const customer = AppUser(
  id: customerId,
  email: 'customer@example.test',
  name: 'Customer',
);
const provider = AppUser(
  id: providerId,
  email: 'provider@example.test',
  name: 'Provider',
  role: UserRole.provider,
);
const otherCustomer = AppUser(
  id: otherId,
  email: 'other@example.test',
  name: 'Other Customer',
);

String id(int number) =>
    '00000000-0000-4000-8000-${number.toRadixString(16).padLeft(12, '0')}';

QuoteDraft draft({String request = requestId, int revision = 0}) => QuoteDraft(
  requestId: request,
  amount: '123.45',
  duration: '90',
  notes: notes,
  expectedRevision: revision,
);

Map<String, dynamic> listing({
  String request = requestId,
  String category = categoryId,
  String text = summary,
  String city = 'Cairo',
  ServiceRequestStatus status = ServiceRequestStatus.open,
  DateTime? publishedAt,
}) => {
  'request_id': request,
  'category_id': category,
  'category_name_en': 'Plumbing',
  'category_name_ar': 'Plumbing AR',
  'category_icon_key': 'plumbing',
  'summary': text,
  'city': city,
  'published_at': (publishedAt ?? instant).toIso8601String(),
  'request_status': status.name,
};

Map<String, dynamic> quote({
  String id = quoteId,
  String request = requestId,
  String provider = providerId,
  int revision = 1,
  QuoteStatus status = QuoteStatus.pending,
  int amount = 12345,
  int duration = 90,
  String text = notes,
  DateTime? createdAt,
}) => {
  'id': id,
  'request_id': request,
  'provider_id': provider,
  'provider_name': 'Provider',
  'amount_minor': amount,
  'currency': 'EGP',
  'duration_minutes': duration,
  'notes': text,
  'revision': revision,
  'status': status.wireName,
  'created_at': (createdAt ?? instant).toIso8601String(),
  'updated_at': (createdAt ?? instant).toIso8601String(),
};

Map<String, dynamic> opportunity({
  String request = requestId,
  Map<String, dynamic>? ownQuote,
  bool canQuote = true,
  ServiceRequestStatus status = ServiceRequestStatus.open,
}) => {
  'listing': listing(request: request, status: status),
  'quote': ownQuote,
  'can_quote': canQuote,
};

// Build genuine lifecycle snapshots rather than mocking immutable model objects.
Map<String, dynamic> job({
  String id = jobId,
  String request = requestId,
  String quote = quoteId,
  String customer = customerId,
  String provider = providerId,
  int quoteRevision = 1,
  List<JobStatus> statuses = const [JobStatus.selected],
  DateTime? createdAt,
}) {
  final start = createdAt ?? instant;
  return {
    'id': id,
    'request_id': request,
    'quote_id': quote,
    'customer_id': customer,
    'provider_id': provider,
    'provider_name': 'Provider',
    'amount_minor': 12345,
    'currency': 'EGP',
    'duration_minutes': 90,
    'notes': notes,
    'quote_revision': quoteRevision,
    'status': statuses.last.wireName,
    'created_at': start.toIso8601String(),
    'updated_at': start
        .add(Duration(minutes: statuses.length - 1))
        .toIso8601String(),
    'request_title': privateTitle,
    'request_description': privateDescription,
    'city': 'Cairo',
    'address': privateAddress,
    'preferred_at': null,
    'history': [
      for (final (index, status) in statuses.indexed)
        {
          'id': _historyId(index),
          'from_status': index == 0 ? null : statuses[index - 1].wireName,
          'status': status.wireName,
          'actor_id': index == 0 || status == JobStatus.completed
              ? customer
              : provider,
          'created_at': start.add(Duration(minutes: index)).toIso8601String(),
        },
    ],
  };
}

String _historyId(int index) => id(100 + index);

Map<String, dynamic> book({
  String request = requestId,
  String customer = customerId,
  ServiceRequestStatus status = ServiceRequestStatus.open,
  bool published = true,
  List<Map<String, dynamic>> quotes = const [],
  bool hasMore = false,
  Map<String, dynamic>? serviceJob,
}) => {
  'request_id': request,
  'customer_id': customer,
  'request_status': status.name,
  'listing': published ? listing(request: request, status: status) : null,
  'quotes': quotes,
  'has_more': hasMore,
  'job': serviceJob,
};
