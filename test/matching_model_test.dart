import 'package:flutter_test/flutter_test.dart';
import 'package:salahly/src/data/models/matching.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/service_request.dart';

import 'matching_fixtures.dart' as fixture;

void main() {
  group('Matching input models', () {
    test('new queries have no private location, date or inferred consent', () {
      const query = MatchingQuery(requestId: fixture.requestId);
      expect(query, fixture.emptyQuery);
      expect(query.validate(), isNull);
      expect(query.hasLocation, isFalse);
      expect(query.latitude, isEmpty);
      expect(query.longitude, isEmpty);
      expect(query.locationConsent, isFalse);
      expect(query.weekday, isNull);
      expect(query.time, isEmpty);
      expect(query.minute, isNull);
      final cleared = fixture.queryWithSignals.copyWith(
        weekday: null,
        time: '',
      );
      expect(cleared.weekday, isNull);
      expect(cleared.validate(), isNull);
      expect(cleared.requestId, fixture.requestId);
    });

    test(
      'paired signed two-decimal coordinates accept bounds and local digits',
      () {
        for (final (latitude, longitude, expectedLat, expectedLon) in [
          ('90', '180', 90.0, 180.0),
          ('-90.00', '-180.00', -90.0, -180.0),
          ('0', '-0.00', 0.0, 0.0),
          (' -30.04 ', ' 31.24\n', -30.04, 31.24),
          (
            '\u0663\u0660\u066b\u0660\u0664',
            '\u0663\u0661.\u0662\u0664',
            30.04,
            31.24,
          ),
          (
            '-\u06f9\u06f0',
            '\u06f1\u06f8\u06f0\u066b\u06f0\u06f0',
            -90.0,
            180.0,
          ),
        ]) {
          final query = fixture.emptyQuery.copyWith(
            latitude: latitude,
            longitude: longitude,
            locationConsent: true,
          );
          expect(query.validate(), isNull, reason: '$latitude/$longitude');
          expect(query.parsedLatitude, expectedLat);
          expect(query.parsedLongitude, expectedLon);
          final draft = fixture.draft().copyWith(
            latitude: latitude,
            longitude: longitude,
          );
          expect(draft.validate(), isNull);
          expect(draft.parsedLatitude, expectedLat);
          expect(draft.parsedLongitude, expectedLon);
        }
      },
    );

    test('partial pairs and imprecise or nonfinite coordinate formats are rejected', () {
      for (final (latitude, longitude) in [
        ('30', ''),
        ('', '31'),
        ('90.01', '31'),
        ('-90.01', '31'),
        ('30', '180.01'),
        ('30', '-180.01'),
        ('30.041', '31.24'),
        ('30.00', '31.240'),
        ('3e1', '31'),
        ('NaN', '31'),
        ('Infinity', '31'),
        ('30,04', '31'),
        ('1,000', '31'),
        ('\u0663\u0660\u066c\u0660\u0664', '31'),
        ('30.', '31'),
        ('.04', '31'),
      ]) {
        expect(
          fixture.emptyQuery
              .copyWith(
                latitude: latitude,
                longitude: longitude,
                locationConsent: true,
              )
              .validate(),
          'matching.errors.location',
          reason: '$latitude/$longitude',
        );
        expect(
          fixture
              .draft()
              .copyWith(latitude: latitude, longitude: longitude)
              .validate(),
          'matching.errors.location',
        );
      }
      expect(
        fixture.emptyQuery.copyWith(latitude: ' ', longitude: '\n').validate(),
        isNull,
      );
      expect(
        const MatchingQuery(requestId: 'bad').validate(),
        'matching.errors.not_found',
      );
    });

    test('an ephemeral query location needs its own explicit consent', () {
      final withoutConsent = fixture.queryWithSignals.copyWith(
        locationConsent: false,
      );
      expect(withoutConsent.hasLocation, isTrue);
      expect(withoutConsent.validate(), 'matching.errors.consent');
      expect(withoutConsent.copyWith(locationConsent: true).validate(), isNull);
      expect(
        fixture.emptyQuery.copyWith(locationConsent: true).hasLocation,
        isFalse,
      );
    });

    test('cursor identity canonically binds request, mode, paired point and explicit wall time', () {
      const query = fixture.queryWithSignals;
      expect(query.cursorKey, '928431c326789a3c2afd38e18c787358');
      final equivalent = query.copyWith(
        latitude: '030.04',
        longitude: '\u06f0\u06f3\u06f1\u066b\u06f2\u06f4',
        time: '9:00',
      );
      expect(equivalent.validate(), isNull);
      expect(equivalent.cursorKey, query.cursorKey);
      final zero = query.copyWith(latitude: '0', longitude: '0.00');
      expect(
        zero.copyWith(latitude: '-0.00', longitude: '-0').cursorKey,
        zero.cursorKey,
      );
      for (final changed in [
        query.copyWith(latitude: '30.05'),
        query.copyWith(longitude: '31.25'),
        query.copyWith(weekday: 2),
        query.copyWith(time: '09:01'),
        query.copyWith(mode: MatchMode.allEligible),
        MatchingQuery(
          requestId: fixture.id(99),
          latitude: query.latitude,
          longitude: query.longitude,
          locationConsent: true,
          weekday: query.weekday,
          time: query.time,
        ),
      ]) {
        expect(changed.cursorKey, isNot(query.cursorKey));
      }
      expect(
        fixture.emptyQuery.copyWith(locationConsent: true).cursorKey,
        fixture.emptyQuery.cursorKey,
      );
    });

    test('ISO weekday and wall time are explicit pairs with half-open day endpoints', () {
      for (final (day, time, minute) in [
        (1, '00:00', 0),
        (7, '23:59', 1439),
        (4, '9:00', 540),
        (1, ' \u0660\u0669:\u0663\u0660 ', 570),
        (7, '\u06f2\u06f3:\u06f5\u06f9', 1439),
      ]) {
        final query = fixture.emptyQuery.copyWith(weekday: day, time: time);
        expect(query.validate(), isNull);
        expect(query.minute, minute);
      }
      for (final (day, time) in <(int?, String)>[
        (1, ''),
        (null, '09:00'),
        (0, '09:00'),
        (8, '09:00'),
        (1, '24:00'),
        (1, '23:60'),
        (1, '-1:00'),
        (1, '09:0'),
        (1, '09:00:00'),
        (1, '09:00Z'),
        (1, '09.30'),
      ]) {
        expect(
          fixture.emptyQuery.copyWith(weekday: day, time: time).validate(),
          'matching.errors.time',
          reason: '$day/$time',
        );
      }
    });

    test(
      'experience is self-reported 0 through 60; blank means absent, not zero',
      () {
        final draft = fixture.draft(
          experience: {
            fixture.categoryId: ' \u0660 ',
            'demo-plumbing': '\u06f6\u06f0',
            'demo-electrical': ' \n',
          },
        );
        expect(draft.validate(), isNull);
        expect(draft.parsedExperienceYears, {
          fixture.categoryId: 0,
          'demo-plumbing': 60,
        });
        for (final input in [
          '-1',
          '61',
          '1.5',
          '1e1',
          '1,0',
          'NaN',
          '100',
          'years',
        ]) {
          expect(
            fixture.draft(experience: {fixture.categoryId: input}).validate(),
            'matching.errors.experience',
            reason: input,
          );
        }
        for (final skill in [
          '',
          'arbitrary',
          ' demo-plumbing',
          'demo-',
          'DEMO-plumbing',
          'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
        ]) {
          expect(
            fixture.draft(experience: {skill: '1'}).validate(),
            'matching.errors.experience',
          );
        }
        expect(
          fixture
              .draft(
                experience: {for (var i = 0; i < 21; i++) fixture.id(i): '1'},
              )
              .validate(),
          'matching.errors.experience',
        );
      },
    );

    test('category experience keys accept generic live UUIDs, not just request UUIDv4', () {
      for (final skill in [
        'aaaaaaaa-aaaa-1aaa-8aaa-aaaaaaaaaaaa',
        'aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa',
        'aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa',
      ]) {
        expect(
          fixture.draft(experience: {skill: '1'}).validate(),
          isNull,
          reason: skill,
        );
        final profile = ProviderMatchingProfile.fromJson(
          fixture.profileJson(experience: {skill: 1}),
        );
        expect(profile.experienceYears, {skill: 1});
      }
    });

    test(
      'drafts cannot increment the maximum readable PostgreSQL revision',
      () {
        for (final revision in [0, fixture.maxRevision - 1]) {
          expect(fixture.draft(revision: revision).validate(), isNull);
        }
        for (final revision in [
          -1,
          fixture.maxRevision,
          fixture.maxRevision + 1,
        ]) {
          expect(
            fixture.draft(revision: revision).validate(),
            'matching.errors.invalid',
          );
        }
        final profile = ProviderMatchingProfile.fromJson(
          fixture.profileJson(revision: fixture.maxRevision),
        );
        expect(profile.revision, fixture.maxRevision);
        expect(
          ProviderMatchingDraft.fromProfile(profile).validate(),
          'matching.errors.invalid',
        );
      },
    );

    test('owner-profile prefill does not grant fresh publication consent', () {
      final profile = ProviderMatchingProfile.fromJson(fixture.profileJson());
      final draft = ProviderMatchingDraft.fromProfile(profile);
      expect(draft.latitude, '30.04');
      expect(draft.longitude, '31.24');
      expect(draft.experienceYears, {fixture.categoryId: '4'});
      expect(draft.expectedRevision, 1);
      expect(draft.consent, isFalse);
      expect(draft.validate(), 'matching.errors.consent');
      expect(draft.copyWith(consent: true).validate(), isNull);
      expect(draft.copyWith(discoverable: false).validate(), isNull);
      expect(draft.matches(profile), isTrue);
      expect(draft.copyWith(latitude: '30.05').matches(profile), isFalse);
      expect(
        draft.copyWith(experienceYears: const {}).matches(profile),
        isFalse,
      );
      expect(profile.toString(), isNot(contains('30.04')));
      expect(draft.toString(), isNot(contains('31.24')));
      expect(fixture.queryWithSignals.toString(), isNot(contains('30.04')));
    });
  });

  group('Matching DTO integrity', () {
    test('profile JSON validates coordinates, consent, skills, names and chronology', () {
      for (final (key, value) in <(String, Object?)>[
        ('provider_id', ''),
        ('provider_name', ' Provider '),
        ('provider_name', 'x'),
        ('provider_name', 'x' * 81),
        ('latitude', double.nan),
        ('longitude', double.infinity),
        ('latitude', -90.01),
        ('longitude', 180.01),
        ('latitude', 30.041),
        ('longitude', 31.241),
        ('longitude', null),
        ('experience_years', {'demo-plumbing': -1}),
        ('experience_years', {'demo-plumbing': 61}),
        ('experience_years', {'bad': 1}),
        ('experience_years', {for (var i = 0; i < 21; i++) fixture.id(i): 1}),
        ('consented_at', null),
        ('updated_at', null),
        ('revision', -1),
        ('revision', fixture.maxRevision + 1),
        (
          'consented_at',
          fixture.instant.add(const Duration(seconds: 1)).toIso8601String(),
        ),
      ]) {
        expect(
          () => ProviderMatchingProfile.fromJson({
            ...fixture.profileJson(),
            key: value,
          }),
          throwsFormatException,
          reason: key,
        );
      }
      final profile = ProviderMatchingProfile.fromJson({
        ...fixture.profileJson(latitude: -90, longitude: 180),
        'consented_at': '2026-11-11T14:00:00+02:00',
        'updated_at': '2026-11-11T14:00:00+02:00',
      });
      expect(profile.consentedAt, fixture.instant);
      expect(profile.updatedAt!.isUtc, isTrue);
    });

    test(
      'revision zero is an empty private profile, not fabricated publication',
      () {
        final empty = fixture.emptyProfileJson();
        final profile = ProviderMatchingProfile.fromJson(empty);
        expect(profile.discoverable, isFalse);
        expect(profile.experienceYears, isEmpty);
        for (final (key, value) in <(String, Object?)>[
          ('discoverable', true),
          ('latitude', 30.04),
          ('experience_years', {'demo-plumbing': 0}),
          ('consented_at', fixture.instant.toIso8601String()),
          ('updated_at', fixture.instant.toIso8601String()),
        ]) {
          expect(
            () => ProviderMatchingProfile.fromJson({...empty, key: value}),
            throwsFormatException,
            reason: key,
          );
        }
      },
    );

    test('maps and lists are independent immutable snapshots including parsed maps', () {
      final years = <String, int>{fixture.categoryId: 4};
      final profile = ProviderMatchingProfile(
        providerId: fixture.providerId,
        providerName: 'Provider',
        experienceYears: years,
      );
      years.clear();
      expect(profile.experienceYears, {fixture.categoryId: 4});
      expect(() => profile.experienceYears.clear(), throwsUnsupportedError);
      final rawYears = <String, String>{fixture.categoryId: '4'};
      final draft = fixture.draft(experience: rawYears);
      final copy = draft.copyWith();
      rawYears.clear();
      expect(draft.experienceYears, {fixture.categoryId: '4'});
      expect(copy.experienceYears, draft.experienceYears);
      expect(() => copy.experienceYears.clear(), throwsUnsupportedError);
      expect(() => draft.parsedExperienceYears.clear(), throwsUnsupportedError);
      final match = fixture.score();
      final factors = match.factors.toList();
      final wire = fixture.matchJson(match);
      final parsed = ProviderMatch.fromJson(wire);
      (wire['factors'] as List).clear();
      expect(parsed.factors, factors);
      expect(() => parsed.factors.clear(), throwsUnsupportedError);
      final resultsWire = fixture.resultsJson(
        items: [match],
        query: fixture.queryWithSignals,
      );
      final results = MatchResults.fromJson(resultsWire);
      (resultsWire['items'] as List).clear();
      expect(results.items, [match]);
      expect(() => results.items.clear(), throwsUnsupportedError);
    });

    test('wire factors must agree on reasons, known values, weights and whole sums', () {
      final match = fixture.score();
      expect(match.scoreBps, 7550);
      expect(match.evidenceBps, 7500);
      expect(
        validProviderMatch(match, const MatchingRules(), fixture.requestId),
        isTrue,
      );
      for (final (key, value) in <(String, Object?)>[
        ('provider_id', ''),
        ('provider_name', ' Provider'),
        ('score_bps', -1),
        ('score_bps', 10001),
        ('score_bps', 7551),
        ('evidence_bps', 7501),
        ('tie_key', '0' * 32),
        ('review_count', 1),
        ('average_rating', 5.0),
        ('distance_km', -0.1),
        ('distance_km', double.nan),
        ('distance_km', 20016.1),
        ('experience_years', 61),
        ('experience_years', 5),
        ('available', false),
      ]) {
        expect(
          _validWire({...fixture.matchJson(match), key: value}),
          isFalse,
          reason: key,
        );
      }
      for (final (index, key, value) in <(int, String, Object?)>[
        (0, 'reason', 'driving_time'),
        (0, 'score_bps', 9000),
        (0, 'effective_bps', 9999),
        (1, 'score_bps', 0),
        (1, 'reason', 'verified_rating'),
        (1, 'weight', 26),
        (2, 'reason', 'booked_slot'),
        (3, 'reason', 'certified'),
        (3, 'score_bps', 4001),
      ]) {
        final wire = fixture.matchJson(match);
        (wire['factors'] as List)[index] = {
          ...((wire['factors'] as List)[index] as Map<String, dynamic>),
          key: value,
        };
        expect(_validWire(wire), isFalse, reason: '$index/$key');
      }
      final reordered = fixture.matchJson(match);
      reordered['factors'] = (reordered['factors'] as List).reversed.toList();
      expect(_validWire(reordered), isFalse);
      final missing = fixture.matchJson(match);
      (missing['factors'] as List).removeLast();
      expect(_validWire(missing), isFalse);
    });

    test('result DTO rejects duplicate identities, wrong order, closed listings and oversized pages', () {
      final matches = [
        fixture.score(),
        fixture.score(
          profile: ProviderMatchingProfile(
            providerId: fixture.otherId,
            providerName: 'New Provider',
          ),
        ),
      ]..sort((a, b) => compareProviderMatches(a, b, MatchMode.recommended));
      expect(
        MatchResults.fromJson(
          fixture.resultsJson(query: fixture.queryWithSignals, items: matches),
        ).items,
        matches,
      );
      for (final wire in [
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          items: [matches.first, matches.first],
        ),
        fixture.resultsJson(
          query: fixture.queryWithSignals,
          items: matches.reversed.toList(),
        ),
        fixture.resultsJson(items: const [], hasMore: true),
        fixture.resultsJson(status: ServiceRequestStatus.assigned),
        fixture.resultsJson(status: ServiceRequestStatus.cancelled),
        fixture.resultsJson(
          items: List.generate(
            51,
            (index) => fixture.score(
              query: fixture.emptyQuery,
              profile: ProviderMatchingProfile(
                providerId: fixture.id(index),
                providerName: 'Provider',
              ),
            ),
          ),
        ),
      ]) {
        expect(() => MatchResults.fromJson(wire), throwsFormatException);
      }
    });

    test('cursor basis points and configuration revisions are bounded and mode is retained', () {
      final match = fixture.score();
      final cursor = match.cursor(
        const MatchingRules(revision: fixture.maxRevision),
        MatchMode.allEligible,
        query: fixture.queryWithSignals.copyWith(mode: MatchMode.allEligible),
      );
      expect(cursor.valid, isTrue);
      expect(cursor.mode, MatchMode.allEligible);
      expect(cursor.rulesRevision, fixture.maxRevision);
      for (final (score, tie, revision) in [
        (-1, cursor.tieKey, 1),
        (10001, cursor.tieKey, 1),
        (0, 'A' * 32, 1),
        (0, '0' * 31, 1),
        (0, cursor.tieKey, 0),
        (0, cursor.tieKey, fixture.maxRevision + 1),
      ]) {
        expect(
          MatchingCursor(
            scoreBps: score,
            tieKey: tie,
            providerId: fixture.providerId,
            rulesRevision: revision,
            mode: MatchMode.recommended,
            queryKey: fixture.queryWithSignals.cursorKey,
          ).valid,
          isFalse,
        );
      }
      expect(
        MatchingCursor(
          scoreBps: 0,
          tieKey: cursor.tieKey,
          providerId: fixture.providerId,
          rulesRevision: 1,
          mode: MatchMode.recommended,
          queryKey: 'A' * 32,
        ).valid,
        isFalse,
      );
    });
  });

  group('Matching score regressions', () {
    test('all missing factors are neutral with a fixed denominator and no invented reviews', () {
      final match = fixture.score(
        query: fixture.emptyQuery,
        profile: ProviderMatchingProfile(
          providerId: fixture.providerId,
          providerName: 'New Provider',
        ),
        availability: const [],
      );
      expect(match.scoreBps, 5000);
      expect(match.evidenceBps, 0);
      expect(match.factors.map((factor) => factor.scoreBps), [
        null,
        null,
        null,
        null,
      ]);
      expect(match.factors.map((factor) => factor.effectiveBps), [
        5000,
        5000,
        5000,
        5000,
      ]);
      expect(match.factors.map((factor) => factor.reason), [
        'no_query_location',
        'no_reviews',
        'no_time_preference',
        'no_experience',
      ]);
      expect(match.reviewCount, 0);
      expect(match.averageRating, isNull);
      expect(match.distanceKm, isNull);
      expect(match.available, isNull);
      expect(
        validProviderMatch(match, const MatchingRules(), fixture.requestId),
        isTrue,
      );
    });

    test(
      'self-reported zero is known evidence and is not the unknown midpoint',
      () {
        final match = fixture.score(
          query: fixture.emptyQuery,
          profile: ProviderMatchingProfile(
            providerId: fixture.providerId,
            providerName: 'New Provider',
            experienceYears: const {fixture.categoryId: 0},
          ),
        );
        expect(match.experienceYears, 0);
        expect(match.factors.last.scoreBps, 0);
        expect(match.factors.last.reason, 'self_reported');
        expect(match.scoreBps, 4000);
        expect(match.evidenceBps, 2000);
        final otherSkill = fixture.score(
          query: fixture.emptyQuery,
          category: 'demo-electrical',
        );
        expect(otherSkill.experienceYears, isNull);
        expect(otherSkill.scoreBps, 5000);
      },
    );

    test('hours are wall-time half-open intervals, not an appointment or timezone conversion', () {
      for (final (day, time, expected) in [
        (1, '08:59', false),
        (1, '09:00', true),
        (1, '16:59', true),
        (1, '17:00', false),
        (2, '09:00', false),
      ]) {
        final match = fixture.score(
          query: fixture.queryWithSignals.copyWith(weekday: day, time: time),
        );
        expect(match.available, expected);
        expect(match.factors[2].scoreBps, expected ? 10000 : 0);
        expect(
          match.factors[2].reason,
          expected ? 'within_hours' : 'outside_hours',
        );
      }
      final noHours = fixture.score(availability: const []);
      expect(noHours.available, isNull);
      expect(noHours.factors[2].reason, 'no_declared_hours');
      expect(noHours.factors[2].effectiveBps, 5000);
      final noPreference = fixture.score(query: fixture.emptyQuery);
      expect(noPreference.available, isNull);
      expect(noPreference.factors[2].reason, 'no_time_preference');
      final midnight = fixture.score(
        query: fixture.emptyQuery.copyWith(weekday: 7, time: '23:59'),
        availability: const [
          ProviderAvailability(weekday: 7, startMinute: 0, endMinute: 1440),
        ],
      );
      expect(midnight.available, isTrue);
    });

    test('non-100 custom weights use one whole-sum rounding and include missing weight', () {
      const rules = MatchingRules(
        distanceWeight: 1,
        ratingWeight: 2,
        availabilityWeight: 4,
        experienceWeight: 6,
        experienceCapYears: 3,
      );
      final match = fixture.score(
        rules: rules,
        profile: ProviderMatchingProfile.fromJson(
          fixture.profileJson(experience: const {fixture.categoryId: 1}),
        ),
      );
      expect(rules.totalWeight, 13);
      expect(match.factors.map((factor) => factor.effectiveBps), [
        10000,
        5000,
        10000,
        3333,
      ]);
      expect(match.scoreBps, 6154);
      expect(match.evidenceBps, 8462);
      expect(validProviderMatch(match, rules, fixture.requestId), isTrue);
      const zeroWeights = MatchingRules(
        distanceWeight: 0,
        ratingWeight: 1,
        availabilityWeight: 0,
        experienceWeight: 0,
      );
      final ratingOnly = fixture.score(rules: zeroWeights);
      expect(ratingOnly.scoreBps, 5000);
      expect(ratingOnly.evidenceBps, 0);
      expect(
        validProviderMatch(ratingOnly, zeroWeights, fixture.requestId),
        isTrue,
      );
    });

    test(
      'distance and experience factors saturate at their configured caps',
      () {
        final far = fixture.score(
          profile: ProviderMatchingProfile.fromJson(
            fixture.profileJson(
              latitude: -30.04,
              longitude: -148.76,
              experience: const {fixture.categoryId: 60},
            ),
          ),
        );
        expect(far.factors.first.scoreBps, 0);
        expect(far.factors.last.scoreBps, 10000);
        expect(far.experienceYears, 60);
        expect(far.distanceKm, closeTo(20015.1, 0.01));
        expect(far.scoreBps, 5250);
        expect(
          validProviderMatch(far, const MatchingRules(), fixture.requestId),
          isTrue,
        );
        final noOrigin = fixture.score(
          profile: ProviderMatchingProfile(
            providerId: fixture.providerId,
            providerName: 'Provider',
          ),
        );
        expect(noOrigin.distanceKm, isNull);
        expect(noOrigin.factors.first.reason, 'no_provider_origin');
        expect(noOrigin.factors.first.effectiveBps, 5000);
      },
    );

    test('Haversine handles zero distance, antipodes and dateline with raw-score/display rounding', () {
      expect(fixture.score().distanceKm, 0);
      expect(fixture.score().factors.first.scoreBps, 10000);
      final dateline = fixture.score(
        query: fixture.queryWithSignals.copyWith(
          latitude: '0',
          longitude: '179.99',
        ),
        profile: ProviderMatchingProfile.fromJson(
          fixture.profileJson(latitude: 0, longitude: -179.99),
        ),
      );
      expect(dateline.distanceKm, 2.2);
      expect(dateline.factors.first.scoreBps, 9555);
      expect(
        validProviderMatch(dateline, const MatchingRules(), fixture.requestId),
        isTrue,
      );
      final sameMeridian = fixture.score(
        query: fixture.queryWithSignals.copyWith(
          latitude: '0',
          longitude: '180',
        ),
        profile: ProviderMatchingProfile.fromJson(
          fixture.profileJson(latitude: 0, longitude: -180),
        ),
      );
      expect(sameMeridian.distanceKm, 0);
      expect(sameMeridian.factors.first.scoreBps, 10000);
      final poles = fixture.score(
        query: fixture.queryWithSignals.copyWith(
          latitude: '90',
          longitude: '0',
        ),
        profile: ProviderMatchingProfile.fromJson(
          fixture.profileJson(latitude: -90, longitude: 0),
        ),
      );
      expect(poles.distanceKm, 20015.1);
      expect(poles.distanceKm!.isFinite, isTrue);
      expect(
        validProviderMatch(poles, const MatchingRules(), fixture.requestId),
        isTrue,
      );
    });

    test(
      'rules keep neutral 5000 and reject invalid revisions, weights and caps',
      () {
        expect(
          MatchingRules.fromJson(
            fixture.rulesJson(
              const MatchingRules(revision: fixture.maxRevision),
            ),
          ).revision,
          fixture.maxRevision,
        );
        for (final (key, value) in <(String, Object)>[
          ('revision', 0),
          ('revision', fixture.maxRevision + 1),
          ('distance_weight', -1),
          ('rating_weight', 1001),
          ('neutral_bps', 0),
          ('neutral_bps', 4999),
          ('distance_scale_km', double.nan),
          ('distance_scale_km', double.infinity),
          ('distance_scale_km', 0),
          ('distance_scale_km', 501),
          ('experience_cap_years', 0),
          ('experience_cap_years', 61),
        ]) {
          expect(
            () => MatchingRules.fromJson({...fixture.rulesJson(), key: value}),
            throwsFormatException,
            reason: key,
          );
        }
        const noWeights = MatchingRules(
          distanceWeight: 0,
          ratingWeight: 0,
          availabilityWeight: 0,
          experienceWeight: 0,
        );
        expect(noWeights.validate(), 'matching.errors.invalid');
        expect(() => fixture.score(rules: noWeights), throwsFormatException);
        expect(
          () => fixture.score(
            query: fixture.queryWithSignals.copyWith(locationConsent: false),
          ),
          throwsFormatException,
        );
      },
    );

    test('MD5 ties are deterministic, request-specific, rotating and not incumbent/ID order', () {
      expect(
        matchingTieKey(fixture.requestId, fixture.providerId),
        '77bc8c930bd7bc103d2cbae8c5cd73d5',
      );
      final providers = List.generate(12, (index) => fixture.id(100 + index));
      final winners = <String>{};
      List<String>? firstOrder;
      for (var request = 0; request < 12; request++) {
        final query = MatchingQuery(requestId: fixture.id(request));
        final matches = [
          for (final provider in providers)
            fixture.score(
              query: query,
              profile: ProviderMatchingProfile(
                providerId: provider,
                providerName: 'Unknown Provider',
              ),
            ),
        ];
        expect(matches.map((match) => match.scoreBps).toSet(), {5000});
        matches.sort(
          (a, b) => compareProviderMatches(a, b, MatchMode.recommended),
        );
        final order = matches.map((match) => match.providerId).toList();
        winners.add(order.first);
        firstOrder ??= order;
        final reversedInput = matches.reversed.toList()
          ..sort((a, b) => compareProviderMatches(a, b, MatchMode.allEligible));
        expect(reversedInput.map((match) => match.providerId), order);
        expect(
          matches.first.tieKey,
          matchingTieKey(query.requestId, order.first),
        );
      }
      expect(winners.length, greaterThan(1));
      expect(firstOrder, isNot(providers));
    });
  });
}

bool _validWire(Map<String, dynamic> wire) => validProviderMatch(
  ProviderMatch.fromJson(wire),
  const MatchingRules(),
  fixture.requestId,
);
