import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/matching.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'marketplace_fixtures.dart' as market;

export 'marketplace_fixtures.dart'
    show
        categoryId,
        customer,
        customerId,
        id,
        otherCustomer,
        otherId,
        provider,
        providerId,
        requestId;

const maxRevision = 2147483647;
const privateError = 'private backend token/path, not a public error';
final instant = DateTime.utc(2026, 11, 11, 12);
const queryWithSignals = MatchingQuery(
  requestId: market.requestId,
  latitude: '30.04',
  longitude: '31.24',
  locationConsent: true,
  weekday: 1,
  time: '09:00',
);
const emptyQuery = MatchingQuery(requestId: market.requestId);
const hours = [
  ProviderAvailability(weekday: 1, startMinute: 540, endMinute: 1020),
];

ProviderMatchingDraft draft({
  String provider = market.providerId,
  int revision = 0,
  bool discoverable = true,
  Map<String, String> experience = const {market.categoryId: '4'},
}) => ProviderMatchingDraft(
  providerId: provider,
  discoverable: discoverable,
  latitude: '30.04',
  longitude: '31.24',
  experienceYears: experience,
  expectedRevision: revision,
  consent: true,
);

Map<String, dynamic> profileJson({
  String provider = market.providerId,
  String name = 'Provider',
  bool discoverable = true,
  int revision = 1,
  double? latitude = 30.04,
  double? longitude = 31.24,
  Map<String, int> experience = const {market.categoryId: 4},
}) => {
  'provider_id': provider,
  'provider_name': name,
  'discoverable': discoverable,
  'latitude': latitude,
  'longitude': longitude,
  'experience_years': {...experience},
  'revision': revision,
  'consented_at': revision == 0 ? null : instant.toIso8601String(),
  'updated_at': revision == 0 ? null : instant.toIso8601String(),
};

Map<String, dynamic> emptyProfileJson({String provider = market.providerId}) =>
    profileJson(
      provider: provider,
      revision: 0,
      discoverable: false,
      latitude: null,
      longitude: null,
      experience: const {},
    );

Map<String, dynamic> rulesJson([MatchingRules rules = const MatchingRules()]) =>
    {
      'revision': rules.revision,
      'distance_weight': rules.distanceWeight,
      'rating_weight': rules.ratingWeight,
      'availability_weight': rules.availabilityWeight,
      'experience_weight': rules.experienceWeight,
      'neutral_bps': rules.neutralBps,
      'distance_scale_km': rules.distanceScaleKm,
      'experience_cap_years': rules.experienceCapYears,
    };

ProviderMatch score({
  MatchingQuery query = queryWithSignals,
  MatchingRules rules = const MatchingRules(),
  ProviderMatchingProfile? profile,
  String category = market.categoryId,
  List<ProviderAvailability> availability = hours,
}) => scoreProviderMatch(
  query: query,
  rules: rules,
  profile: profile ?? ProviderMatchingProfile.fromJson(profileJson()),
  categoryId: category,
  availability: availability,
);

Map<String, dynamic> matchJson(ProviderMatch match) => {
  'provider_id': match.providerId,
  'provider_name': match.providerName,
  'score_bps': match.scoreBps,
  'evidence_bps': match.evidenceBps,
  'tie_key': match.tieKey,
  'distance_km': match.distanceKm,
  'available': match.available,
  'experience_years': match.experienceYears,
  'review_count': match.reviewCount,
  'average_rating': match.averageRating,
  'factors': [
    for (final factor in match.factors)
      {
        'key': factor.key.name,
        'score_bps': factor.scoreBps,
        'effective_bps': factor.effectiveBps,
        'weight': factor.weight,
        'reason': factor.reason,
      },
  ],
};

Map<String, dynamic> resultsJson({
  MatchingQuery query = emptyQuery,
  MatchingRules rules = const MatchingRules(),
  List<ProviderMatch>? items,
  bool hasMore = false,
  ServiceRequestStatus status = ServiceRequestStatus.open,
}) => {
  'listing': market.listing(request: query.requestId, status: status),
  'rules': rulesJson(rules),
  'mode': query.mode.wireName,
  'items': [
    for (final item in items ?? [score(query: query)]) matchJson(item),
  ],
  'has_more': hasMore,
};

Future<T> success<T>(FutureEither<T> task) async =>
    (await task).fold((failure) => fail(failure.message), (value) => value);

Future<Failure> failure<T>(
  FutureEither<T> task,
  String key, {
  String? reason,
}) async {
  final result = (await task).fold(
    (failure) => failure,
    (_) => fail('Expected $key${reason == null ? '' : ' ($reason)'}'),
  );
  expect(result.message, key, reason: reason);
  expect(result.error, isNull, reason: reason);
  expect(result.toString(), isNot(contains(privateError)), reason: reason);
  return result;
}

class SessionAuth extends DemoAuthRepository {
  SessionAuth({required this.demo});

  final bool demo;
  AuthSession session = const AuthSession(user: market.customer);
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

  void streamError() => _events.addError(StateError(privateError));
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

// Real SDK serialization and session events, with no table/Storage fallback.
class LoopbackBackend {
  LoopbackBackend(this.server) {
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    server.listen((request) => unawaited(_handle(request)));
  }

  final HttpServer server;
  late final SupabaseClient client;
  final calls = <Call>[];
  final unexpected = <String>[];
  FutureOr<Reply?> Function(Call)? intercept;
  String? refreshedToken;
  Map<String, dynamic> matchesResponse = resultsJson();
  Map<String, dynamic> profileResponse = profileJson();
  Map<String, dynamic> saveResponse = profileJson();
  Iterable<Call> get rpcs =>
      calls.where((call) => call.uri.path.startsWith('/rest/v1/rpc/'));
  Iterable<Call> rpc(String name) => calls.where((call) => call.isRpc(name));

  static Future<LoopbackBackend> start() async {
    final backend = LoopbackBackend(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    await backend.setSession();
    return backend;
  }

  Map<String, Object?> sessionJson({String userId = market.customerId}) => {
    'access_token': refreshedToken ?? 'test-token-$userId',
    'refresh_token': 'test-refresh-token',
    'token_type': 'bearer',
    'user': {
      'id': userId,
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
      'aud': 'authenticated',
      'created_at': '2026-11-11T00:00:00Z',
    },
  };

  Future<void> setSession({String userId = market.customerId}) =>
      client.auth.setInitialSession(jsonEncode(sessionJson(userId: userId)));

  Future<void> _handle(HttpRequest incoming) async {
    final body = await utf8.decoder.bind(incoming).join();
    final call = Call(
      incoming.method,
      incoming.uri,
      body.isEmpty ? {} : jsonDecode(body) as Map<String, dynamic>,
      incoming.headers.value(HttpHeaders.authorizationHeader),
    );
    calls.add(call);
    final reply = await intercept?.call(call) ?? _respond(call);
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

  Reply _respond(Call call) {
    if (call.uri.path == '/auth/v1/verify' ||
        call.uri.path == '/auth/v1/token') {
      return Reply.json(sessionJson(userId: client.auth.currentUser!.id));
    }
    if (call.uri.path == '/auth/v1/logout') return const Reply.json({});
    if (call.isRpc('get_provider_matches')) return Reply.json(matchesResponse);
    if (call.isRpc('get_provider_matching_profile')) {
      return Reply.json(profileResponse);
    }
    if (call.isRpc('save_provider_matching_profile')) {
      return Reply.json(saveResponse);
    }
    unexpected.add('${call.method} ${call.uri}');
    return Reply.sqlError('Unexpected test endpoint');
  }

  Future<void> close() async {
    await client.dispose();
    await server.close(force: true);
  }
}

class Call {
  const Call(this.method, this.uri, this.json, this.authorization);
  final String method;
  final Uri uri;
  final Map<String, dynamic> json;
  final String? authorization;
  bool isRpc(String name) => uri.path == '/rest/v1/rpc/$name';
}

class Reply {
  const Reply.json(this.body, {this.status = 200}) : disconnect = false;
  const Reply.disconnected() : body = null, status = 200, disconnect = true;
  factory Reply.sqlError(
    String message, {
    String code = 'P0001',
    int status = 400,
  }) => Reply.json({
    'code': code,
    'message': message,
    'details': privateError,
    'hint': privateError,
  }, status: status);
  final Object? body;
  final int status;
  final bool disconnect;
}
