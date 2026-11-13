import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:equatable/equatable.dart';

import 'marketplace.dart';
import 'provider_profile.dart';
import 'service_request.dart';

enum MatchMode {
  recommended('recommended'),
  allEligible('all_eligible');

  const MatchMode(this.wireName);
  final String wireName;
  static MatchMode parse(String value) =>
      values.singleWhere((mode) => mode.wireName == value);
}

enum MatchFactorKey { distance, rating, availability, experience }

String _digits(String input) => String.fromCharCodes(
  input.trim().runes.map((rune) {
    if (rune >= 0x660 && rune <= 0x669) return rune - 0x660 + 0x30;
    if (rune >= 0x6f0 && rune <= 0x6f9) return rune - 0x6f0 + 0x30;
    return rune == 0x66b ? 0x2e : rune;
  }),
);

double? _coordinate(String input, double bound) {
  final value = _digits(input);
  if (!RegExp(r'^-?\d{1,3}(\.\d{1,2})?$').hasMatch(value)) return null;
  final parsed = double.tryParse(value);
  return parsed != null && parsed.isFinite && parsed.abs() <= bound
      ? parsed
      : null;
}

bool _validCoordinates(double? latitude, double? longitude) =>
    (latitude == null && longitude == null) ||
    (latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude.abs() <= 90 &&
        longitude.abs() <= 180 &&
        (latitude * 100 - (latitude * 100).round()).abs() < 0.0000001 &&
        (longitude * 100 - (longitude * 100).round()).abs() < 0.0000001);

bool _name(String name) =>
    name == name.trim() && name.runes.length >= 2 && name.runes.length <= 80;
bool _bps(int value) => value >= 0 && value <= 10000;
bool _revision(int value) => value >= 1 && value <= 2147483647;
bool _skillId(String value) =>
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value) ||
    RegExp(r'^demo-[a-z][a-z0-9-]{1,60}$').hasMatch(value);

class MatchingQuery extends Equatable {
  const MatchingQuery({
    required this.requestId,
    this.mode = MatchMode.recommended,
    this.latitude = '',
    this.longitude = '',
    this.locationConsent = false,
    this.weekday,
    this.time = '',
  });

  final String requestId;
  final MatchMode mode;
  final String latitude;
  final String longitude;
  final bool locationConsent;
  final int? weekday;
  final String time;

  bool get hasLocation =>
      latitude.trim().isNotEmpty || longitude.trim().isNotEmpty;
  double? get parsedLatitude => _coordinate(latitude, 90);
  double? get parsedLongitude => _coordinate(longitude, 180);
  String get cursorKey {
    String coordinate(double? value) =>
        value == null ? '' : (value == 0 ? 0.0 : value).toStringAsFixed(2);
    return md5
        .convert(
          utf8.encode(
            [
              requestId,
              mode.wireName,
              coordinate(parsedLatitude),
              coordinate(parsedLongitude),
              weekday?.toString() ?? '',
              minute?.toString() ?? '',
            ].join(':'),
          ),
        )
        .toString();
  }

  int? get minute {
    final value = _digits(time);
    if (!RegExp(r'^\d{1,2}:\d{2}$').hasMatch(value)) return null;
    final parts = value.split(':').map(int.parse).toList();
    return parts[0] <= 23 && parts[1] <= 59 ? parts[0] * 60 + parts[1] : null;
  }

  String? validate() {
    if (!ServiceRequestDraft.validId(requestId)) {
      return 'matching.errors.not_found';
    }
    if (hasLocation && (parsedLatitude == null || parsedLongitude == null)) {
      return 'matching.errors.location';
    }
    if (hasLocation && !locationConsent) return 'matching.errors.consent';
    if ((weekday != null || time.trim().isNotEmpty) &&
        (weekday == null || weekday! < 1 || weekday! > 7 || minute == null)) {
      return 'matching.errors.time';
    }
    return null;
  }

  static const _unchanged = Object();
  MatchingQuery copyWith({
    MatchMode? mode,
    String? latitude,
    String? longitude,
    bool? locationConsent,
    Object? weekday = _unchanged,
    String? time,
  }) => MatchingQuery(
    requestId: requestId,
    mode: mode ?? this.mode,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    locationConsent: locationConsent ?? this.locationConsent,
    weekday: identical(weekday, _unchanged) ? this.weekday : weekday as int?,
    time: time ?? this.time,
  );

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    requestId,
    mode,
    latitude,
    longitude,
    locationConsent,
    weekday,
    time,
  ];
}

class MatchingRules extends Equatable {
  const MatchingRules({
    this.revision = 1,
    this.distanceWeight = 35,
    this.ratingWeight = 25,
    this.availabilityWeight = 20,
    this.experienceWeight = 20,
    this.neutralBps = 5000,
    this.distanceScaleKm = 50,
    this.experienceCapYears = 10,
  });

  factory MatchingRules.fromJson(Map<String, dynamic> json) {
    final value = MatchingRules(
      revision: json['revision'] as int,
      distanceWeight: json['distance_weight'] as int,
      ratingWeight: json['rating_weight'] as int,
      availabilityWeight: json['availability_weight'] as int,
      experienceWeight: json['experience_weight'] as int,
      neutralBps: json['neutral_bps'] as int,
      distanceScaleKm: (json['distance_scale_km'] as num).toDouble(),
      experienceCapYears: json['experience_cap_years'] as int,
    );
    if (value.validate() != null) {
      throw const FormatException('Invalid matching rules.');
    }
    return value;
  }

  final int revision;
  final int distanceWeight;
  final int ratingWeight;
  final int availabilityWeight;
  final int experienceWeight;
  final int neutralBps;
  final double distanceScaleKm;
  final int experienceCapYears;
  int get totalWeight =>
      distanceWeight + ratingWeight + availabilityWeight + experienceWeight;
  int weightFor(MatchFactorKey factor) => switch (factor) {
    MatchFactorKey.distance => distanceWeight,
    MatchFactorKey.rating => ratingWeight,
    MatchFactorKey.availability => availabilityWeight,
    MatchFactorKey.experience => experienceWeight,
  };
  String? validate() =>
      !_revision(revision) ||
          totalWeight <= 0 ||
          MatchFactorKey.values.any(
            (factor) => weightFor(factor) < 0 || weightFor(factor) > 1000,
          ) ||
          neutralBps != 5000 ||
          !distanceScaleKm.isFinite ||
          distanceScaleKm < 1 ||
          distanceScaleKm > 500 ||
          experienceCapYears < 1 ||
          experienceCapYears > 60
      ? 'matching.errors.invalid'
      : null;
  @override
  List<Object> get props => [
    revision,
    distanceWeight,
    ratingWeight,
    availabilityWeight,
    experienceWeight,
    neutralBps,
    distanceScaleKm,
    experienceCapYears,
  ];
}

class MatchFactor extends Equatable {
  const MatchFactor({
    required this.key,
    this.scoreBps,
    required this.effectiveBps,
    required this.weight,
    required this.reason,
  });
  factory MatchFactor.fromJson(Map<String, dynamic> json) => MatchFactor(
    key: MatchFactorKey.values.byName(json['key'] as String),
    scoreBps: json['score_bps'] as int?,
    effectiveBps: json['effective_bps'] as int,
    weight: json['weight'] as int,
    reason: json['reason'] as String,
  );
  final MatchFactorKey key;
  final int? scoreBps;
  final int effectiveBps;
  final int weight;
  final String reason;
  @override
  List<Object?> get props => [key, scoreBps, effectiveBps, weight, reason];
}

class MatchingCursor extends Equatable {
  const MatchingCursor({
    required this.scoreBps,
    required this.tieKey,
    required this.providerId,
    required this.rulesRevision,
    required this.mode,
    required this.queryKey,
  });
  final int scoreBps;
  final String tieKey;
  final String providerId;
  final int rulesRevision;
  final MatchMode mode;
  final String queryKey;
  bool get valid =>
      _bps(scoreBps) &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(tieKey) &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(queryKey) &&
      providerId.isNotEmpty &&
      _revision(rulesRevision);
  @override
  List<Object> get props => [
    scoreBps,
    tieKey,
    providerId,
    rulesRevision,
    mode,
    queryKey,
  ];
}

class ProviderMatchingProfile extends Equatable {
  ProviderMatchingProfile({
    required this.providerId,
    required this.providerName,
    this.discoverable = false,
    this.latitude,
    this.longitude,
    Map<String, int> experienceYears = const {},
    this.revision = 0,
    this.consentedAt,
    this.updatedAt,
  }) : experienceYears = Map.unmodifiable(experienceYears);

  factory ProviderMatchingProfile.fromJson(Map<String, dynamic> json) {
    final value = ProviderMatchingProfile(
      providerId: json['provider_id'] as String,
      providerName: json['provider_name'] as String,
      discoverable: json['discoverable'] as bool,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      experienceYears: (json['experience_years'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value as int),
      ),
      revision: json['revision'] as int,
      consentedAt: json['consented_at'] == null
          ? null
          : DateTime.parse(json['consented_at'] as String).toUtc(),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.parse(json['updated_at'] as String).toUtc(),
    );
    if (value.providerId.isEmpty ||
        !_name(value.providerName) ||
        !_validCoordinates(value.latitude, value.longitude) ||
        value.experienceYears.length > 20 ||
        value.experienceYears.entries.any(
          (entry) =>
              !_skillId(entry.key) || entry.value < 0 || entry.value > 60,
        ) ||
        value.revision < 0 ||
        value.revision > 2147483647 ||
        (value.discoverable && value.consentedAt == null) ||
        (value.revision > 0 && value.updatedAt == null) ||
        (value.consentedAt != null &&
            value.updatedAt != null &&
            value.consentedAt!.isAfter(value.updatedAt!)) ||
        (value.revision == 0 &&
            (value.discoverable ||
                value.latitude != null ||
                value.experienceYears.isNotEmpty ||
                value.consentedAt != null ||
                value.updatedAt != null))) {
      throw const FormatException('Invalid provider matching profile.');
    }
    return value;
  }
  final String providerId;
  final String providerName;
  final bool discoverable;
  final double? latitude;
  final double? longitude;
  final Map<String, int> experienceYears;
  final int revision;
  final DateTime? consentedAt;
  final DateTime? updatedAt;
  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    providerId,
    providerName,
    discoverable,
    latitude,
    longitude,
    experienceYears,
    revision,
    consentedAt,
    updatedAt,
  ];
}

/// Current owned setup metadata, separate from a published discovery snapshot.
class MatchingEligibility extends Equatable {
  MatchingEligibility({required List<String> skillIds, required this.eligible})
    : skillIds = List.unmodifiable(skillIds);
  final List<String> skillIds;
  final bool eligible;
  @override
  List<Object> get props => [skillIds, eligible];
}

class ProviderMatchingDraft extends Equatable {
  ProviderMatchingDraft({
    required this.providerId,
    this.discoverable = false,
    this.latitude = '',
    this.longitude = '',
    Map<String, String> experienceYears = const {},
    this.expectedRevision = 0,
    this.consent = false,
  }) : experienceYears = Map.unmodifiable(experienceYears);
  factory ProviderMatchingDraft.fromProfile(ProviderMatchingProfile profile) =>
      ProviderMatchingDraft(
        providerId: profile.providerId,
        discoverable: profile.discoverable,
        latitude: profile.latitude?.toStringAsFixed(2) ?? '',
        longitude: profile.longitude?.toStringAsFixed(2) ?? '',
        experienceYears: profile.experienceYears.map(
          (key, value) => MapEntry(key, value.toString()),
        ),
        expectedRevision: profile.revision,
      );
  final String providerId;
  final bool discoverable;
  final String latitude;
  final String longitude;
  final Map<String, String> experienceYears;
  final int expectedRevision;
  final bool consent;
  double? get parsedLatitude => _coordinate(latitude, 90);
  double? get parsedLongitude => _coordinate(longitude, 180);
  Map<String, int> get parsedExperienceYears => Map.unmodifiable({
    for (final entry in experienceYears.entries)
      if (entry.value.trim().isNotEmpty)
        entry.key: int.parse(_digits(entry.value)),
  });
  String? validate() {
    if (providerId.isEmpty ||
        expectedRevision < 0 ||
        expectedRevision >= 2147483647) {
      return 'matching.errors.invalid';
    }
    if (discoverable && !consent) return 'matching.errors.consent';
    if ((latitude.trim().isNotEmpty || longitude.trim().isNotEmpty) &&
        (parsedLatitude == null || parsedLongitude == null)) {
      return 'matching.errors.location';
    }
    if (experienceYears.length > 20 ||
        experienceYears.entries.any((entry) {
          final value = _digits(entry.value);
          return !_skillId(entry.key) ||
              (value.isNotEmpty &&
                  (!RegExp(r'^\d{1,2}$').hasMatch(value) ||
                      int.parse(value) > 60));
        })) {
      return 'matching.errors.experience';
    }
    return null;
  }

  ProviderMatchingDraft copyWith({
    bool? discoverable,
    String? latitude,
    String? longitude,
    Map<String, String>? experienceYears,
    bool? consent,
  }) => ProviderMatchingDraft(
    providerId: providerId,
    discoverable: discoverable ?? this.discoverable,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    experienceYears: experienceYears ?? this.experienceYears,
    expectedRevision: expectedRevision,
    consent: consent ?? this.consent,
  );
  bool matches(ProviderMatchingProfile profile) =>
      providerId == profile.providerId &&
      discoverable == profile.discoverable &&
      parsedLatitude == profile.latitude &&
      parsedLongitude == profile.longitude &&
      parsedExperienceYears.length == profile.experienceYears.length &&
      parsedExperienceYears.entries.every(
        (entry) => profile.experienceYears[entry.key] == entry.value,
      );
  @override
  bool get stringify => false;
  @override
  List<Object> get props => [
    providerId,
    discoverable,
    latitude,
    longitude,
    experienceYears,
    expectedRevision,
    consent,
  ];
}

class ProviderMatch extends Equatable {
  ProviderMatch({
    required this.providerId,
    required this.providerName,
    required this.scoreBps,
    required this.evidenceBps,
    required this.tieKey,
    this.distanceKm,
    this.available,
    this.experienceYears,
    this.reviewCount = 0,
    this.averageRating,
    required List<MatchFactor> factors,
  }) : factors = List.unmodifiable(factors);
  factory ProviderMatch.fromJson(Map<String, dynamic> json) => ProviderMatch(
    providerId: json['provider_id'] as String,
    providerName: json['provider_name'] as String,
    scoreBps: json['score_bps'] as int,
    evidenceBps: json['evidence_bps'] as int,
    tieKey: json['tie_key'] as String,
    distanceKm: (json['distance_km'] as num?)?.toDouble(),
    available: json['available'] as bool?,
    experienceYears: json['experience_years'] as int?,
    reviewCount: json['review_count'] as int,
    averageRating: (json['average_rating'] as num?)?.toDouble(),
    factors: (json['factors'] as List)
        .map((item) => MatchFactor.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
  final String providerId;
  final String providerName;
  final int scoreBps;
  final int evidenceBps;
  final String tieKey;
  final double? distanceKm;
  final bool? available;
  final int? experienceYears;
  final int reviewCount;
  final double? averageRating;
  final List<MatchFactor> factors;
  MatchingCursor cursor(
    MatchingRules rules,
    MatchMode mode, {
    required MatchingQuery query,
  }) => MatchingCursor(
    scoreBps: scoreBps,
    tieKey: tieKey,
    providerId: providerId,
    rulesRevision: rules.revision,
    mode: mode,
    queryKey: query.cursorKey,
  );
  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    providerId,
    providerName,
    scoreBps,
    evidenceBps,
    tieKey,
    distanceKm,
    available,
    experienceYears,
    reviewCount,
    averageRating,
    factors,
  ];
}

class MatchResults extends Equatable {
  MatchResults({
    required this.listing,
    required this.rules,
    required this.mode,
    required List<ProviderMatch> items,
    required this.hasMore,
  }) : items = List.unmodifiable(items);
  factory MatchResults.fromJson(Map<String, dynamic> json) {
    final value = MatchResults(
      listing: MarketplaceListing.fromJson(
        json['listing'] as Map<String, dynamic>,
      ),
      rules: MatchingRules.fromJson(json['rules'] as Map<String, dynamic>),
      mode: MatchMode.parse(json['mode'] as String),
      items: (json['items'] as List)
          .map((item) => ProviderMatch.fromJson(item as Map<String, dynamic>))
          .toList(),
      hasMore: json['has_more'] as bool,
    );
    if (value.listing.requestStatus != ServiceRequestStatus.open ||
        value.items.length > 50 ||
        (value.hasMore && value.items.isEmpty) ||
        value.items.map((item) => item.providerId).toSet().length !=
            value.items.length) {
      throw const FormatException('Invalid matching results.');
    }
    ProviderMatch? previous;
    for (final candidate in value.items) {
      if (!validProviderMatch(
            candidate,
            value.rules,
            value.listing.requestId,
          ) ||
          (previous != null &&
              compareProviderMatches(previous, candidate, value.mode) >= 0)) {
        throw const FormatException('Invalid matching scores.');
      }
      previous = candidate;
    }
    return value;
  }
  final MarketplaceListing listing;
  final MatchingRules rules;
  final MatchMode mode;
  final List<ProviderMatch> items;
  final bool hasMore;
  @override
  bool get stringify => false;
  @override
  List<Object> get props => [listing, rules, mode, items, hasMore];
}

String matchingTieKey(String requestId, String providerId) =>
    md5.convert(utf8.encode('$requestId:$providerId')).toString();

int compareProviderMatches(
  ProviderMatch left,
  ProviderMatch right,
  MatchMode mode,
) {
  if (mode == MatchMode.recommended && left.scoreBps != right.scoreBps) {
    return right.scoreBps.compareTo(left.scoreBps);
  }
  final tie = left.tieKey.compareTo(right.tieKey);
  return tie == 0 ? left.providerId.compareTo(right.providerId) : tie;
}

bool validProviderMatch(
  ProviderMatch value,
  MatchingRules rules,
  String requestId,
) {
  if (value.providerId.isEmpty ||
      !_name(value.providerName) ||
      !_bps(value.scoreBps) ||
      !_bps(value.evidenceBps) ||
      value.tieKey != matchingTieKey(requestId, value.providerId) ||
      value.reviewCount != 0 ||
      value.averageRating != null ||
      (value.distanceKm != null &&
          (!value.distanceKm!.isFinite ||
              value.distanceKm! < 0 ||
              value.distanceKm! > 20016)) ||
      (value.experienceYears != null &&
          (value.experienceYears! < 0 || value.experienceYears! > 60)) ||
      value.factors.length != 4) {
    return false;
  }
  var total = 0;
  var evidence = 0;
  for (final (index, factor) in value.factors.indexed) {
    if (factor.key != MatchFactorKey.values[index] ||
        factor.weight != rules.weightFor(factor.key) ||
        !_bps(factor.effectiveBps) ||
        (factor.scoreBps != null && !_bps(factor.scoreBps!)) ||
        factor.effectiveBps != (factor.scoreBps ?? rules.neutralBps)) {
      return false;
    }
    final valid = switch (factor.key) {
      MatchFactorKey.distance =>
        value.distanceKm == null
            ? factor.scoreBps == null &&
                  const [
                    'no_query_location',
                    'no_provider_origin',
                  ].contains(factor.reason)
            : factor.scoreBps != null &&
                  factor.reason == 'straight_line' &&
                  (factor.scoreBps! -
                              ((1 - value.distanceKm! / rules.distanceScaleKm)
                                          .clamp(0.0, 1.0) *
                                      10000)
                                  .round())
                          .abs() <=
                      (510 / rules.distanceScaleKm).ceil() + 1,
      MatchFactorKey.rating =>
        factor.scoreBps == null && factor.reason == 'no_reviews',
      MatchFactorKey.availability =>
        value.available == null
            ? factor.scoreBps == null &&
                  const [
                    'no_time_preference',
                    'no_declared_hours',
                  ].contains(factor.reason)
            : factor.scoreBps == (value.available! ? 10000 : 0) &&
                  factor.reason ==
                      (value.available! ? 'within_hours' : 'outside_hours'),
      MatchFactorKey.experience =>
        value.experienceYears == null
            ? factor.scoreBps == null && factor.reason == 'no_experience'
            : factor.reason == 'self_reported' &&
                  factor.scoreBps ==
                      (math.min(
                                value.experienceYears! /
                                    rules.experienceCapYears,
                                1,
                              ) *
                              10000)
                          .round(),
    };
    if (!valid) return false;
    total += factor.effectiveBps * factor.weight;
    if (factor.scoreBps != null) evidence += factor.weight;
  }
  return value.scoreBps == (total / rules.totalWeight).round() &&
      value.evidenceBps == (evidence * 10000 / rules.totalWeight).round();
}

/// Demo scorer mirrors the trusted SQL rules; eligibility is checked separately.
ProviderMatch scoreProviderMatch({
  required MatchingQuery query,
  required MatchingRules rules,
  required ProviderMatchingProfile profile,
  required String categoryId,
  required List<ProviderAvailability> availability,
}) {
  if (query.validate() != null || rules.validate() != null) {
    throw const FormatException('Invalid matching inputs.');
  }
  double? distance;
  if (query.hasLocation &&
      profile.latitude != null &&
      profile.longitude != null) {
    final lat1 = query.parsedLatitude! * math.pi / 180;
    final lat2 = profile.latitude! * math.pi / 180;
    final lat = lat2 - lat1;
    final lon = (profile.longitude! - query.parsedLongitude!) * math.pi / 180;
    final a =
        math.pow(math.sin(lat / 2), 2) +
        math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(lon / 2), 2);
    distance = 6371.0088 * 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
  }
  bool? available;
  if (query.weekday != null && availability.isNotEmpty) {
    available = availability.any(
      (hours) =>
          hours.weekday == query.weekday &&
          hours.startMinute <= query.minute! &&
          hours.endMinute > query.minute!,
    );
  }
  final experience = profile.experienceYears[categoryId];
  final scores = <int?>[
    if (distance == null)
      null
    else
      ((1 - distance / rules.distanceScaleKm).clamp(0.0, 1.0) * 10000).round(),
    null,
    if (available == null) null else if (available) 10000 else 0,
    if (experience == null)
      null
    else
      (math.min(experience / rules.experienceCapYears, 1) * 10000).round(),
  ];
  final reasons = [
    if (distance != null)
      'straight_line'
    else if (!query.hasLocation)
      'no_query_location'
    else
      'no_provider_origin',
    'no_reviews',
    if (available == true)
      'within_hours'
    else if (available == false)
      'outside_hours'
    else if (query.weekday == null)
      'no_time_preference'
    else
      'no_declared_hours',
    if (experience == null) 'no_experience' else 'self_reported',
  ];
  final factors = [
    for (final (index, key) in MatchFactorKey.values.indexed)
      MatchFactor(
        key: key,
        scoreBps: scores[index],
        effectiveBps: scores[index] ?? rules.neutralBps,
        weight: rules.weightFor(key),
        reason: reasons[index],
      ),
  ];
  return ProviderMatch(
    providerId: profile.providerId,
    providerName: profile.providerName,
    scoreBps:
        (factors.fold<int>(
                  0,
                  (sum, factor) => sum + factor.effectiveBps * factor.weight,
                ) /
                rules.totalWeight)
            .round(),
    evidenceBps:
        (factors
                    .where((factor) => factor.scoreBps != null)
                    .fold<int>(0, (sum, factor) => sum + factor.weight) *
                10000 /
                rules.totalWeight)
            .round(),
    tieKey: matchingTieKey(query.requestId, profile.providerId),
    distanceKm: distance == null ? null : (distance * 10).round() / 10,
    available: available,
    experienceYears: experience,
    factors: factors,
  );
}
