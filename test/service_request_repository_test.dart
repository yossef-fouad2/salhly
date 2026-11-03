import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/service_request_repository.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = '11111111-1111-4111-8111-111111111111';
const _otherId = '22222222-2222-4222-8222-222222222222';
const _categoryId = '33333333-3333-4333-8333-333333333333';
const _requestId = '44444444-4444-4444-8444-444444444444';
const _photoId = '55555555-5555-4555-8555-555555555555';
const _secondPhotoId = '66666666-6666-4666-8666-666666666666';
const _thirdPhotoId = '77777777-7777-4777-8777-777777777777';
const _jpeg = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x02, 0xff, 0xd9];
const _png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const _customer = AppUser(
  id: _userId,
  email: 'customer@example.test',
  name: 'Customer',
);
const _otherCustomer = AppUser(
  id: _otherId,
  email: 'other@example.test',
  name: 'Other Customer',
);
const _provider = AppUser(
  id: _userId,
  email: 'provider@example.test',
  name: 'Provider',
  role: UserRole.provider,
);
final _instant = DateTime.utc(2026, 10, 31, 12);

void main() {
  group('Service request models', () {
    test('new drafts have distinct UUIDv4 identities retained by copyWith', () {
      final empty = ServiceRequestDraft.create();
      final seeded = ServiceRequestDraft.create(
        categoryId: 'demo-plumbing',
        city: 'Cairo',
      );
      expect(ServiceRequestDraft.validId(empty.id), isTrue);
      expect(ServiceRequestDraft.validId(seeded.id), isTrue);
      expect(empty.id, isNot(seeded.id));
      expect(empty.title, isEmpty);
      expect(empty.photos, isEmpty);
      expect(empty.consent, isFalse);
      expect(empty.preferredAt, isNull);
      expect(empty.validate(now: _instant), 'requests.errors.category');
      expect(seeded.categoryId, 'demo-plumbing');
      expect(seeded.city, 'Cairo');
      expect(seeded.copyWith(title: 'A different title').id, seeded.id);
      expect(seeded.copyWith(), seeded);
      expect(seeded.toString(), isNot(contains('Cairo')));
    });

    for (final (field, minimum, maximum, replace)
        in <(String, int, int, ServiceRequestDraft Function(String))>[
          ('title', 5, 120, (value) => _draft().copyWith(title: value)),
          (
            'description',
            10,
            2000,
            (value) => _draft().copyWith(description: value),
          ),
          ('city', 2, 100, (value) => _draft().copyWith(city: value)),
          ('address', 5, 500, (value) => _draft().copyWith(address: value)),
        ]) {
      test('$field validates trimmed Unicode character boundaries', () {
        final scalar = String.fromCharCode(0x20000);
        for (final text in [
          'x' * minimum,
          ' \t${'x' * maximum}\n ',
          scalar * maximum,
        ]) {
          expect(replace(text).validate(now: _instant), isNull);
          expect(
            ServiceRequest.fromJson({..._snapshot(), field: text})
                .toJson()[field],
            text,
          );
        }
        for (final text in [
          '',
          ' \n ',
          'x' * (minimum - 1),
          scalar * (maximum + 1),
        ]) {
          expect(
            replace(text).validate(now: _instant),
            'requests.errors.$field',
          );
          expect(
            () => ServiceRequest.fromJson({..._snapshot(), field: text}),
            throwsFormatException,
          );
        }
      });
    }

    test(
      'requires canonical request identity, category, and explicit consent',
      () {
        for (final id in [
          '',
          ' $_requestId',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'.toUpperCase(),
          '44444444-4444-1444-8444-444444444444',
          '44444444-4444-4444-7444-444444444444',
          '../$_requestId',
        ]) {
          expect(
            _draft(id: id).validate(now: _instant),
            'requests.errors.invalid_request',
          );
          expect(
            () => ServiceRequest.fromJson({..._snapshot(), 'id': id}),
            throwsFormatException,
          );
        }
        expect(
          _draft().copyWith(clearCategory: true).validate(),
          'requests.errors.category',
        );
        expect(
          _draft().copyWith(categoryId: ' \t ').validate(),
          'requests.errors.category',
        );
        expect(
          _draft().copyWith(consent: false).validate(),
          'requests.errors.consent',
        );
      },
    );

    test('optional preferred time is strictly future and at most 180 days', () {
      final draft = _draft();
      final lastAllowed = _instant.add(const Duration(days: 180));
      expect(draft.validate(now: _instant), isNull);
      for (final time in [
        _instant.add(const Duration(microseconds: 1)),
        lastAllowed,
        DateTime.parse('2026-11-01T14:00:00+02:00'),
      ]) {
        expect(
          draft.copyWith(preferredAt: time).validate(now: _instant),
          isNull,
        );
      }
      for (final time in [
        _instant,
        _instant.subtract(const Duration(microseconds: 1)),
        lastAllowed.add(const Duration(microseconds: 1)),
      ]) {
        expect(
          draft.copyWith(preferredAt: time).validate(now: _instant),
          'requests.errors.preferred_time',
        );
      }
    });

    test('drafts cap attachments at three unique photo IDs', () {
      final photos = _threePhotos();
      expect(_draft().validate(now: _instant), isNull);
      expect(_draft(photos: photos).validate(now: _instant), isNull);
      expect(
        _draft(
          photos: [
            ...photos,
            _photo(id: _id(9)),
          ],
        ).validate(now: _instant),
        'requests.errors.photos',
      );
      expect(
        _draft(photos: [_photo(), _photo()]).validate(now: _instant),
        'requests.errors.photos',
      );
    });

    test('draft copies are immutable, preserve identity, and explicitly clear optionals', () {
      final photos = [_photo()];
      final preferred = _instant.add(const Duration(days: 1));
      final draft = _draft(photos: photos, preferredAt: preferred);
      photos.clear();
      expect(draft.photos, hasLength(1));
      expect(() => draft.photos.clear(), throwsUnsupportedError);
      final replacement = [_photo(id: _secondPhotoId)];
      final copied = draft.copyWith(photos: replacement);
      replacement.clear();
      expect(copied.photos.single.id, _secondPhotoId);
      expect(copied.id, draft.id);
      expect(copied.preferredAt, preferred);
      expect(copied.categoryId, draft.categoryId);
      expect(copied, isNot(draft));
      expect(draft.copyWith(), draft);
      final cleared = draft.copyWith(
        clearCategory: true,
        clearPreferredAt: true,
      );
      expect(cleared.categoryId, isNull);
      expect(cleared.preferredAt, isNull);
      expect(draft.preferredAt, preferred);
    });

    test(
      'snapshots sort photos, round-trip UTC times, and retain category labels',
      () {
        final json = {
          ..._snapshot(),
          'created_at': '2026-10-31T14:00:00+02:00',
          'consented_at': '2026-10-31T14:00:00+02:00',
          'preferred_at': '2026-11-01T14:00:00+02:00',
          'status': 'cancelled',
          'cancelled_at': '2026-10-31T15:00:00+02:00',
          'photos': [
            _photoJson(id: _secondPhotoId, position: 2, png: true),
            _photoJson(),
          ],
        };
        final request = ServiceRequest.fromJson(json);
        expect(request.photos.map((photo) => photo.id), [
          _photoId,
          _secondPhotoId,
        ]);
        expect(request.createdAt, _instant);
        expect(request.consentedAt, _instant);
        expect(request.preferredAt, _instant.add(const Duration(days: 1)));
        expect(request.cancelledAt, _instant.add(const Duration(hours: 1)));
        expect(request.createdAt.isUtc, isTrue);
        expect(request.consentedAt.isUtc, isTrue);
        expect(request.preferredAt!.isUtc, isTrue);
        expect(request.cancelledAt!.isUtc, isTrue);
        expect(request.categoryName('ar'), 'Plumbing AR');
        expect(request.categoryName('en'), 'Plumbing');
        expect(request.categoryName('fr'), 'Plumbing');
        final serialized = request.toJson();
        expect(serialized['created_at'], '2026-10-31T12:00:00.000Z');
        expect(serialized['preferred_at'], '2026-11-01T12:00:00.000Z');
        expect(serialized['cancelled_at'], '2026-10-31T13:00:00.000Z');
        expect(ServiceRequest.fromJson(serialized), request);
        expect(
          ServiceRequestPhoto.fromJson(request.photos.first.toJson()),
          request.photos.first,
        );
        expect(request.toString(), isNot(contains(request.address)));
        expect(request.photos.first.toString(), isNot(contains(_userId)));
      },
    );

    test(
      'request and page constructors defensively copy their collections',
      () {
        final photo = ServiceRequestPhoto.fromJson(_photoJson());
        final photos = [photo];
        final request = ServiceRequest(
          id: _requestId,
          customerId: _userId,
          categoryId: _categoryId,
          categoryNameEn: 'Plumbing',
          categoryNameAr: 'Plumbing AR',
          categoryIconKey: 'plumbing',
          title: 'Leaking kitchen tap',
          description: 'The kitchen tap leaks continuously.',
          city: 'Cairo',
          address: '12 Sample Street',
          status: ServiceRequestStatus.open,
          createdAt: _instant,
          consentedAt: _instant,
          photos: photos,
        );
        photos.clear();
        expect(request.photos, [photo]);
        expect(() => request.photos.add(photo), throwsUnsupportedError);
        final items = [request];
        final page = ServiceRequestPage(items: items, hasMore: true);
        items.clear();
        expect(page.items, [request]);
        expect(page.hasMore, isTrue);
        expect(() => page.items.clear(), throwsUnsupportedError);
        final json = _snapshot(photos: [_photoJson()]);
        final decoded = ServiceRequest.fromJson(json);
        (json['photos'] as List).clear();
        expect(decoded.photos, [photo]);
        expect(() => decoded.photos.clear(), throwsUnsupportedError);
      },
    );

    test('rejects missing or malformed snapshot shape and unknown states', () {
      for (final key in [
        'customer_id',
        'category_id',
        'category_name_en',
        'category_name_ar',
        'category_icon_key',
      ]) {
        expect(
          () => ServiceRequest.fromJson({..._snapshot(), key: ''}),
          throwsFormatException,
          reason: key,
        );
      }
      for (final key in ['id', 'title', 'created_at', 'photos']) {
        final missing = _snapshot()..remove(key);
        expect(
          () => ServiceRequest.fromJson(missing),
          throwsA(isA<TypeError>()),
        );
      }
      expect(
        () => ServiceRequest.fromJson({..._snapshot(), 'status': 'assigned'}),
        throwsArgumentError,
      );
      expect(
        () => ServiceRequest.fromJson({
          ..._snapshot(),
          'created_at': 'not-a-time',
        }),
        throwsFormatException,
      );
    });

    test('cancellation state and timestamp must agree, but history may be in the past', () {
      for (final change in [
        {'cancelled_at': _instant.toIso8601String()},
        {'status': 'cancelled'},
        {
          'status': 'cancelled',
          'cancelled_at': _instant
              .subtract(const Duration(seconds: 1))
              .toIso8601String(),
        },
      ]) {
        expect(
          () => ServiceRequest.fromJson({..._snapshot(), ...change}),
          throwsFormatException,
        );
      }
      final past = ServiceRequest.fromJson({
        ..._snapshot(),
        'status': 'cancelled',
        'cancelled_at': _instant.toIso8601String(),
        'preferred_at': _instant
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      });
      expect(past.status, ServiceRequestStatus.cancelled);
      expect(past.cancelledAt, past.createdAt);
      expect(ServiceRequest.fromJson(_snapshot()).cancelledAt, isNull);
    });

    test(
      'rejects invalid photo manifests, paths, types, sizes, and ordering',
      () {
        for (final change in <Map<String, Object?>>[
          {'id': 'not-a-uuid'},
          {'mime_type': 'application/pdf'},
          {'size_bytes': 0},
          {'size_bytes': RequestPhotoInput.maxBytes + 1},
          {'position': 0},
          {'position': 2},
          {'storage_path': '$_otherId/$_requestId/$_photoId.jpg'},
          {'storage_path': '$_userId/${_id(1)}/$_photoId.jpg'},
          {'storage_path': '$_userId/$_requestId/$_photoId.png'},
          {'storage_path': '$_userId/../$_photoId.jpg'},
          {'storage_path': 'https://example.test/private.jpg'},
        ]) {
          expect(
            () => ServiceRequest.fromJson(
              _snapshot(
                photos: [
                  {..._photoJson(), ...change},
                ],
              ),
            ),
            throwsFormatException,
            reason: change.toString(),
          );
        }
        for (final photos in [
          [_photoJson(), _photoJson(position: 2)],
          List.generate(4, (i) => _photoJson(id: _id(i), position: i + 1)),
          [_photoJson(), _photoJson(id: _secondPhotoId, position: 3)],
        ]) {
          expect(
            () => ServiceRequest.fromJson(_snapshot(photos: photos)),
            throwsFormatException,
          );
        }
        final maximum = ServiceRequest.fromJson(
          _snapshot(
            photos: [
              {..._photoJson(), 'size_bytes': RequestPhotoInput.maxBytes},
            ],
          ),
        );
        expect(maximum.photos.single.sizeBytes, RequestPhotoInput.maxBytes);
      },
    );
  });

  group('ServiceRequestRepository demo', () {
    late _SessionAuth auth;
    late ServiceRequestRepository repository;
    late DateTime clock;

    setUp(() {
      auth = _SessionAuth(demo: true);
      clock = _instant;
      repository = ServiceRequestRepository(
        authRepository: auth,
        now: () => clock,
      );
    });
    tearDown(() => auth.dispose());

    test('starts empty and does not manufacture example requests or persist globally', () async {
      expect(repository.isDemo, isTrue);
      final empty = await _success(repository.loadRequests(userId: _userId));
      expect(empty.items, isEmpty);
      expect(empty.hasMore, isFalse);
      await _expectFailure(
        repository.loadRequest(_requestId, userId: _userId),
        'requests.errors.not_found',
      );
      await _success(repository.submitRequest(_draft(), userId: _userId));
      final fresh = ServiceRequestRepository(authRepository: auth);
      expect(
        (await _success(fresh.loadRequests(userId: _userId))).items,
        isEmpty,
      );
      expect(auth.hasListeners, isFalse);
    });

    for (final count in [0, 3]) {
      test(
        'submits and retrieves actual history with $count photos and manual location',
        () async {
          final photos = count == 0 ? <RequestPhotoInput>[] : _threePhotos();
          final draft =
              _draft(
                photos: photos,
                preferredAt: DateTime.parse('2026-11-01T14:00:00+02:00'),
              ).copyWith(
                title: '  Leaking kitchen tap  ',
                description: '\nThe kitchen tap leaks continuously.\t',
                city: ' Cairo ',
                address: '  12 Sample Street  ',
              );
          final saved = await _success(
            repository.submitRequest(draft, userId: _userId),
          );
          expect(saved.id, draft.id);
          expect(saved.customerId, _userId);
          expect(saved.categoryId, 'demo-plumbing');
          expect(saved.categoryNameEn, 'Plumbing');
          expect(saved.categoryNameAr, isNotEmpty);
          expect(saved.categoryIconKey, 'plumbing');
          expect(saved.title, 'Leaking kitchen tap');
          expect(saved.description, 'The kitchen tap leaks continuously.');
          expect(saved.city, 'Cairo');
          expect(saved.address, '12 Sample Street');
          expect(saved.preferredAt, _instant.add(const Duration(days: 1)));
          expect(saved.createdAt, clock);
          expect(saved.consentedAt, clock);
          expect(saved.createdAt.isUtc, isTrue);
          expect(saved.preferredAt!.isUtc, isTrue);
          expect(saved.status, ServiceRequestStatus.open);
          expect(saved.cancelledAt, isNull);
          expect(saved.photos, hasLength(count));
          expect(
            await _success(repository.loadRequest(saved.id, userId: _userId)),
            saved,
          );
          final history = await _success(
            repository.loadRequests(userId: _userId),
          );
          expect(history.items, [saved]);
          expect(history.hasMore, isFalse);
          for (final (index, photo) in saved.photos.indexed) {
            expect(photo.id, photos[index].id);
            expect(photo.position, index + 1);
            expect(
              photo.storagePath,
              '$_userId/${saved.id}/${photo.id}.${photos[index].extension}',
            );
            final bytes = await _success(
              repository.loadPhoto(
                userId: _userId,
                requestId: saved.id,
                photoId: photo.id,
              ),
            );
            expect(bytes, orderedEquals(photos[index].bytes));
            expect(() => bytes[0] = 0, throwsUnsupportedError);
          }
          expect(auth.hasListeners, isFalse);
        },
      );
    }

    test('exact-ID retries remain idempotent after cancellation and past preferred time', () async {
      final draft = _draft(
        photos: [_photo()],
        preferredAt: clock.add(const Duration(hours: 1)),
      );
      final original = await _success(
        repository.submitRequest(draft, userId: _userId),
      );
      final retry = draft.copyWith(
        title: '  ${draft.title}  ',
        photos: [_photo()],
      );
      expect(
        await _success(repository.submitRequest(retry, userId: _userId)),
        original,
      );
      clock = clock.add(const Duration(days: 2));
      expect(draft.validate(now: clock), 'requests.errors.preferred_time');
      expect(
        await _success(repository.submitRequest(retry, userId: _userId)),
        original,
      );
      final cancelled = await _success(
        repository.cancelRequest(draft.id, userId: _userId),
      );
      expect(cancelled.status, ServiceRequestStatus.cancelled);
      expect(cancelled.cancelledAt, clock);
      expect(cancelled.createdAt, original.createdAt);
      expect(cancelled.consentedAt, original.consentedAt);
      expect(cancelled.photos, original.photos);
      expect(original.status, ServiceRequestStatus.open);
      clock = clock.add(const Duration(hours: 1));
      expect(
        await _success(repository.cancelRequest(draft.id, userId: _userId)),
        cancelled,
      );
      expect(
        await _success(repository.submitRequest(retry, userId: _userId)),
        cancelled,
      );
      expect((await _success(repository.loadRequests(userId: _userId))).items, [
        cancelled,
      ]);
      expect(
        await _success(
          repository.loadPhoto(
            userId: _userId,
            requestId: draft.id,
            photoId: _photoId,
          ),
        ),
        orderedEquals(_jpeg),
      );
      await _expectFailure(
        repository.submitRequest(
          draft.copyWith(consent: false),
          userId: _userId,
        ),
        'requests.errors.consent',
      );
    });

    test('changed duplicate fields or attachment manifests conflict without overwriting', () async {
      final draft = _draft(
        photos: _threePhotos(),
        preferredAt: clock.add(const Duration(days: 1)),
      );
      final saved = await _success(
        repository.submitRequest(draft, userId: _userId),
      );
      for (final changed in [
        draft.copyWith(categoryId: 'demo-electrical'),
        draft.copyWith(title: 'Another kitchen problem'),
        draft.copyWith(description: 'A different description for the request.'),
        draft.copyWith(city: 'Giza'),
        draft.copyWith(address: '34 Different Street'),
        draft.copyWith(clearPreferredAt: true),
        draft.copyWith(preferredAt: clock.add(const Duration(days: 2))),
        draft.copyWith(photos: []),
        draft.copyWith(photos: draft.photos.reversed.toList()),
        draft.copyWith(
          photos: [
            _photo(id: _id(9)),
            ...draft.photos.skip(1),
          ],
        ),
        draft.copyWith(
          photos: [
            _photo(bytes: [..._jpeg, 0]),
            ...draft.photos.skip(1),
          ],
        ),
        draft.copyWith(
          photos: [
            _photo(bytes: _png),
            ...draft.photos.skip(1),
          ],
        ),
      ]) {
        await _expectFailure(
          repository.submitRequest(changed, userId: _userId),
          'requests.errors.conflict',
        );
      }
      expect(
        await _success(repository.loadRequest(draft.id, userId: _userId)),
        saved,
      );
      expect((await _success(repository.loadRequests(userId: _userId))).items, [
        saved,
      ]);
    });

    test('captured owner, provider, signed-out, recovery, and failed auth are denied', () async {
      for (final session in const [
        AuthSession(),
        AuthSession(user: _provider),
        AuthSession(user: _otherCustomer),
        AuthSession(user: _customer, needsPasswordUpdate: true),
      ]) {
        auth.change(session);
        await _expectAllDenied(repository);
        expect(auth.hasListeners, isFalse);
      }
      auth.change(const AuthSession(user: _customer));
      await _expectAllDenied(repository, userId: '');
      auth.checkOverride = () async =>
          left(const NetworkFailure('errors.network'));
      await _expectAllDenied(repository);
    });

    test('another customer cannot reuse a chosen request ID or read/cancel its data', () async {
      final draft = _draft(photos: [_photo()]);
      final alice = await _success(
        repository.submitRequest(draft, userId: _userId),
      );
      auth.change(const AuthSession(user: _otherCustomer));
      await _expectAllDenied(repository);
      expect(
        (await _success(repository.loadRequests(userId: _otherId))).items,
        isEmpty,
      );
      await _expectFailure(
        repository.loadRequest(draft.id, userId: _otherId),
        'requests.errors.not_found',
      );
      await _expectFailure(
        repository.cancelRequest(draft.id, userId: _otherId),
        'requests.errors.not_found',
      );
      await _expectFailure(
        repository.loadPhoto(
          userId: _otherId,
          requestId: draft.id,
          photoId: _photoId,
        ),
        'requests.errors.photo_unavailable',
      );
      await _expectFailure(
        repository.submitRequest(draft, userId: _otherId),
        'requests.errors.conflict',
      );
      await _expectFailure(
        repository.loadRequests(userId: _otherId, before: alice),
        'requests.errors.invalid_request',
      );
      final bob = await _success(
        repository.submitRequest(_draft(id: _id(1)), userId: _otherId),
      );
      expect(bob.customerId, _otherId);
      expect(
        (await _success(repository.loadRequests(userId: _otherId))).items,
        [bob],
      );
      auth.change(const AuthSession(user: _customer));
      expect((await _success(repository.loadRequests(userId: _userId))).items, [
        alice,
      ]);
      expect(
        await _success(repository.loadRequest(draft.id, userId: _userId)),
        alice,
      );
      expect(
        await _success(
          repository.loadPhoto(
            userId: _userId,
            requestId: draft.id,
            photoId: _photoId,
          ),
        ),
        orderedEquals(_jpeg),
      );
    });

    test(
      'logout and same-user return cannot revive stale pending authorization',
      () async {
        final gate = Completer<Either<Failure, AuthSession>>();
        auth.checkOverride = () => gate.future;
        final pending = repository.submitRequest(_draft(), userId: _userId);
        auth.change(const AuthSession());
        auth.change(const AuthSession(user: _customer));
        gate.complete(right(const AuthSession(user: _customer)));
        await _expectFailure(pending, 'requests.errors.access');
        auth.checkOverride = null;
        expect(
          (await _success(repository.loadRequests(userId: _userId))).items,
          isEmpty,
        );
        await _success(repository.submitRequest(_draft(), userId: _userId));
        expect(auth.hasListeners, isFalse);
      },
    );

    test(
      'invalid submissions and pagination arguments cannot change history',
      () async {
        for (final (draft, key) in [
          (_draft(id: '../id'), 'requests.errors.not_found'),
          (_draft(categoryId: 'unknown'), 'requests.errors.category'),
          (_draft().copyWith(title: 'x'), 'requests.errors.title'),
          (_draft().copyWith(consent: false), 'requests.errors.consent'),
          (
            _draft(
              photos: [
                ..._threePhotos(),
                _photo(id: _id(9)),
              ],
            ),
            'requests.errors.photos',
          ),
        ]) {
          await _expectFailure(
            repository.submitRequest(draft, userId: _userId),
            key,
          );
        }
        for (final limit in [0, -1, 51]) {
          await _expectFailure(
            repository.loadRequests(userId: _userId, limit: limit),
            'requests.errors.invalid_request',
          );
        }
        expect(
          (await _success(repository.loadRequests(userId: _userId, limit: 50)))
              .items,
          isEmpty,
        );
        await _expectFailure(
          repository.loadPhoto(
            userId: _userId,
            requestId: _requestId,
            photoId: 'bad',
          ),
          'requests.errors.not_found',
        );
      },
    );

    test(
      'keyset pagination orders descending timestamps and IDs without repeats',
      () async {
        for (final number in [1, 4, 2, 3]) {
          await _success(
            repository.submitRequest(_draft(id: _id(number)), userId: _userId),
          );
        }
        clock = clock.add(const Duration(seconds: 1));
        await _success(
          repository.submitRequest(_draft(id: _id(0)), userId: _userId),
        );
        final first = await _success(
          repository.loadRequests(userId: _userId, limit: 2),
        );
        expect(first.items.map((request) => request.id), [_id(0), _id(4)]);
        expect(first.hasMore, isTrue);
        final second = await _success(
          repository.loadRequests(
            userId: _userId,
            before: first.items.last,
            limit: 2,
          ),
        );
        expect(second.items.map((request) => request.id), [_id(3), _id(2)]);
        expect(second.hasMore, isTrue);
        final third = await _success(
          repository.loadRequests(
            userId: _userId,
            before: second.items.last,
            limit: 2,
          ),
        );
        expect(third.items.map((request) => request.id), [_id(1)]);
        expect(third.hasMore, isFalse);
        expect(
          (await _success(
            repository.loadRequests(userId: _userId, before: third.items.last),
          )).items,
          isEmpty,
        );
        final exact = await _success(
          repository.loadRequests(userId: _userId, limit: 5),
        );
        expect(exact.items, hasLength(5));
        expect(exact.hasMore, isFalse);
      },
    );

    test(
      'works with real demo auth and its non-UUID customer identity',
      () async {
        final demoAuth = DemoAuthRepository();
        addTearDown(demoAuth.dispose);
        final user = await _success(
          demoAuth.login(
            email: DemoAuthRepository.customerEmail,
            password: DemoAuthRepository.demoPassword,
          ),
        );
        final demo = ServiceRequestRepository(
          authRepository: demoAuth,
          now: () => clock,
        );
        final saved = await _success(
          demo.submitRequest(_draft(photos: [_photo()]), userId: user.id),
        );
        expect(saved.customerId, 'demo-customer');
        expect(
          saved.photos.single.storagePath,
          'demo-customer/$_requestId/$_photoId.jpg',
        );
        await _success(demo.cancelRequest(saved.id, userId: user.id));
        await _success(demoAuth.logout());
        await _expectAllDenied(demo, userId: user.id);
      },
    );

    test(
      'live mode without a client fails every operation without demo fallback',
      () async {
        final liveAuth = _SessionAuth(demo: false);
        addTearDown(liveAuth.dispose);
        final live = ServiceRequestRepository(authRepository: liveAuth);
        expect(live.isDemo, isFalse);
        await _expectAllDenied(live, key: 'errors.database_setup');
        expect(liveAuth.checkCalls, 0);
        expect(liveAuth.hasListeners, isFalse);
      },
    );
  });

  group('ServiceRequestRepository live loopback SDK', () {
    late _Backend backend;
    late _SessionAuth auth;
    late ServiceRequestRepository repository;
    late DateTime clock;

    setUp(() async {
      backend = await _Backend.start();
      auth = _SessionAuth(demo: false);
      clock = _instant;
      repository = ServiceRequestRepository(
        authRepository: auth,
        client: backend.client,
        now: () => clock,
      );
    });
    tearDown(() async {
      await backend.close();
      await auth.dispose();
    });

    test('loads canonical details with authenticated exact-ID RPC and one auth check', () async {
      backend.snapshots[_requestId] = _snapshot();
      final request = await _success(
        repository.loadRequest(_requestId, userId: _userId),
      );
      expect(repository.isDemo, isFalse);
      expect(request, ServiceRequest.fromJson(_snapshot()));
      final call = backend.requests.single;
      expect(call.method, 'POST');
      expect(call.uri.path, '/rest/v1/rpc/get_service_request');
      expect(call.json, {'p_request_id': _requestId});
      expect(call.authorization, 'Bearer test-customer-token');
      expect(auth.checkCalls, 1);
      expect(auth.hasListeners, isFalse);
    });

    for (final count in [0, 3]) {
      test('serializes exact submit RPC and ordered manifest for $count photos', () async {
        final photos = count == 0 ? <RequestPhotoInput>[] : _threePhotos();
        final draft = _draft(categoryId: _categoryId, photos: photos).copyWith(
          title: '  Leaking kitchen tap  ',
          description: '\tThe kitchen tap leaks continuously.\n',
          city: ' Cairo ',
          address: ' 12 Sample Street ',
          preferredAt: DateTime.parse('2026-11-01T14:00:00+02:00'),
        );
        final saved = await _success(
          repository.submitRequest(draft, userId: _userId),
        );
        expect(saved.id, _requestId);
        expect(saved.customerId, _userId);
        expect(saved.photos, hasLength(count));
        expect(backend.uploads, hasLength(count));
        for (final (index, upload) in backend.uploads.indexed) {
          final photo = photos[index];
          expect(
            upload.uri.path,
            '/storage/v1/object/request-photos/$_userId/$_requestId/${photo.id}.${photo.extension}',
          );
          expect(upload.upsert, 'false');
          expect(upload.authorization, 'Bearer test-customer-token');
          expect(upload.photoBytes, orderedEquals(photo.bytes));
          final multipart = latin1.decode(upload.bytes);
          expect(
            multipart.toLowerCase(),
            contains('content-type: ${photo.mimeType}'),
          );
          expect(multipart, isNot(contains('name="metadata"')));
        }
        expect(backend.requests.last.json, {
          'p_request_id': _requestId,
          'p_category_id': _categoryId,
          'p_title': 'Leaking kitchen tap',
          'p_description': 'The kitchen tap leaks continuously.',
          'p_city': 'Cairo',
          'p_address': '12 Sample Street',
          'p_preferred_at': '2026-11-01T12:00:00.000Z',
          'p_photos': [
            for (final photo in photos)
              {
                'id': photo.id,
                'storage_path':
                    '$_userId/$_requestId/${photo.id}.${photo.extension}',
                'mime_type': photo.mimeType,
                'size_bytes': photo.sizeBytes,
              },
          ],
          'p_consent': true,
        });
        expect(backend.requests.last.isRpc('submit_service_request'), isTrue);
        expect(backend.requests, hasLength(count + 2));
        expect(backend.deletions, isEmpty);
        expect(auth.checkCalls, 1);
      });
    }
    test('history uses owner-scoped keyset query, stable ordering, and one lookahead', () async {
      var rows = [
        _snapshot(id: _id(3)),
        _snapshot(id: _id(2)),
        _snapshot(id: _id(1)),
      ];
      backend.intercept = (request) =>
          request.uri.path == '/rest/v1/service_requests'
          ? _Reply.json(rows)
          : null;
      final first = await _success(
        repository.loadRequests(userId: _userId, limit: 2),
      );
      expect(first.items.map((item) => item.id), [_id(3), _id(2)]);
      expect(first.hasMore, isTrue);
      final query = backend.requests.single;
      expect(query.method, 'GET');
      expect(query.authorization, 'Bearer test-customer-token');
      expect(query.uri.queryParameters, {
        'select': '*,photos:service_request_photos(*)',
        'customer_id': 'eq.$_userId',
        'order': 'created_at.desc.nullslast,id.desc.nullslast',
        'limit': '3',
      });
      rows = [_snapshot(id: _id(1))];
      final second = await _success(
        repository.loadRequests(
          userId: _userId,
          before: first.items.last,
          limit: 2,
        ),
      );
      expect(second.items.map((item) => item.id), [_id(1)]);
      expect(second.hasMore, isFalse);
      final stamp = _instant.toIso8601String();
      expect(
        backend.requests.last.uri.queryParameters['or'],
        '(created_at.lt.$stamp,and(created_at.eq.$stamp,id.lt.${_id(2)}))',
      );
      await _success(repository.loadRequests(userId: _userId));
      expect(backend.requests.last.uri.queryParameters['limit'], '21');
    });

    test('absent, foreign, wrong-ID, and malformed records never become local data', () async {
      for (final (response, key) in <(Object?, String)>[
        (null, 'requests.errors.not_found'),
        (_snapshot(userId: _otherId), 'requests.errors.access'),
        (_snapshot(id: _id(1)), 'requests.errors.access'),
        ({'id': _requestId}, 'requests.errors.invalid_request'),
        (
          {..._snapshot(), 'status': 'assigned'},
          'requests.errors.invalid_request',
        ),
        ([_snapshot()], 'requests.errors.invalid_request'),
      ]) {
        backend.intercept = (_) => _Reply.json(response);
        await _expectFailure(
          repository.loadRequest(_requestId, userId: _userId),
          key,
        );
      }
      backend.intercept = (_) => _Reply.json([_snapshot(userId: _otherId)]);
      await _expectFailure(
        repository.loadRequests(userId: _userId),
        'requests.errors.access',
      );
      expect(backend.uploads, isEmpty);
      expect(backend.deletions, isEmpty);
    });

    test(
      'forbidden mapped sessions never send RPC or Storage requests',
      () async {
        for (final session in const [
          AuthSession(),
          AuthSession(user: _provider),
          AuthSession(user: _otherCustomer),
          AuthSession(user: _customer, needsPasswordUpdate: true),
        ]) {
          auth.change(session);
          await _expectAllDenied(repository);
        }
        auth.change(const AuthSession(user: _customer));
        await _expectAllDenied(repository, userId: 'demo-customer');
        auth.checkOverride = () async =>
            left(const NetworkFailure('errors.network'));
        await _expectAllDenied(repository);
        expect(backend.requests, isEmpty);
        expect(auth.hasListeners, isFalse);
      },
    );

    test('explicit demo mode ignores an injected live client', () async {
      final demoAuth = _SessionAuth(demo: true);
      addTearDown(demoAuth.dispose);
      final demo = ServiceRequestRepository(
        authRepository: demoAuth,
        client: backend.client,
        now: () => clock,
      );
      final saved = await _success(
        demo.submitRequest(_draft(photos: [_photo()]), userId: _userId),
      );
      await _success(demo.loadRequests(userId: _userId));
      await _success(
        demo.loadPhoto(userId: _userId, requestId: saved.id, photoId: _photoId),
      );
      await _success(demo.cancelRequest(saved.id, userId: _userId));
      expect(demo.isDemo, isTrue);
      expect(backend.requests, isEmpty);
    });

    test('invalid IDs, consent, pagination, and drafts cannot reach uploads or submit', () async {
      await _expectFailure(
        repository.loadRequest('../private', userId: _userId),
        'requests.errors.not_found',
      );
      await _expectFailure(
        repository.submitRequest(_draft(id: 'bad'), userId: _userId),
        'requests.errors.not_found',
      );
      await _expectFailure(
        repository.submitRequest(
          _draft().copyWith(consent: false),
          userId: _userId,
        ),
        'requests.errors.consent',
      );
      for (final limit in [0, 51]) {
        await _expectFailure(
          repository.loadRequests(userId: _userId, limit: limit),
          'requests.errors.invalid_request',
        );
      }
      await _expectFailure(
        repository.loadRequests(
          userId: _userId,
          before: ServiceRequest.fromJson(_snapshot(userId: _otherId)),
        ),
        'requests.errors.invalid_request',
      );
      expect(backend.requests, isEmpty);
      await _expectFailure(
        repository.submitRequest(_draft(), userId: _userId),
        'requests.errors.category',
      );
      await _expectFailure(
        repository.submitRequest(
          _draft(
            categoryId: _categoryId,
            photos: [
              ..._threePhotos(),
              _photo(id: _id(9)),
            ],
          ),
          userId: _userId,
        ),
        'requests.errors.photos',
      );
      expect(backend.rpc('get_service_request'), hasLength(2));
      expect(backend.uploads, isEmpty);
      expect(backend.rpc('submit_service_request'), isEmpty);
    });

    test(
      'only exact SQL error keys are exposed and missing schema is explicit',
      () async {
        for (final key in [
          'access',
          'not_found',
          'conflict',
          'category',
          'title',
          'description',
          'city',
          'address',
          'preferred_time',
          'photos',
          'photo_type',
          'photo_size',
          'consent',
          'status',
          'invalid_request',
        ]) {
          backend.intercept = (_) => _Reply.sqlError('requests.errors.$key');
          await _expectFailure(
            repository.loadRequest(_requestId, userId: _userId),
            'requests.errors.$key',
          );
        }
        backend.intercept = (_) =>
            _Reply.sqlError('requests.errors.access private token/path');
        await _expectFailure(
          repository.loadRequest(_requestId, userId: _userId),
          'requests.errors.load_failed',
        );
        for (final code in ['PGRST202', '42883', '42P01']) {
          backend.intercept = (_) =>
              _Reply.sqlError('missing schema', code: code);
          await _expectFailure(
            repository.loadRequest(_requestId, userId: _userId),
            'errors.database_setup',
          );
        }
      },
    );

    test('exact-ID retries and cancellation are idempotent even after preferred time passes', () async {
      final draft = _draft(
        categoryId: _categoryId,
        photos: [_photo()],
        preferredAt: clock.add(const Duration(hours: 1)),
      );
      final original = await _success(
        repository.submitRequest(draft, userId: _userId),
      );
      final cancelled = await _success(
        repository.cancelRequest(draft.id, userId: _userId),
      );
      expect(cancelled.status, ServiceRequestStatus.cancelled);
      expect(cancelled.photos, original.photos);
      expect(backend.rpc('cancel_service_request').single.json, {
        'p_request_id': _requestId,
      });
      clock = clock.add(const Duration(days: 2));
      final retry = draft.copyWith(
        title: ' ${draft.title} ',
        photos: [_photo()],
      );
      expect(
        await _success(repository.submitRequest(retry, userId: _userId)),
        cancelled,
      );
      expect(
        await _success(repository.cancelRequest(draft.id, userId: _userId)),
        cancelled,
      );
      await _expectFailure(
        repository.submitRequest(
          draft.copyWith(title: 'Different request'),
          userId: _userId,
        ),
        'requests.errors.conflict',
      );
      await _expectFailure(
        repository.submitRequest(draft.copyWith(photos: []), userId: _userId),
        'requests.errors.conflict',
      );
      expect(backend.rpc('submit_service_request'), hasLength(1));
      expect(backend.rpc('cancel_service_request'), hasLength(1));
      expect(backend.uploads, hasLength(1));
      expect(backend.deletions, isEmpty);
    });

    test('partial upload failure cleans only attempted new objects and releases the write lock', () async {
      const unrelated = '$_otherId/$_requestId/$_photoId.jpg';
      backend.objects[unrelated] = Uint8List.fromList(_jpeg);
      backend.intercept = (request) {
        if (request.isUpload && backend.uploads.length == 2) {
          backend.respond(request);
          return _Reply.storageError(503);
        }
        return null;
      };
      final draft = _draft(categoryId: _categoryId, photos: _threePhotos());
      await _expectFailure(
        repository.submitRequest(draft, userId: _userId),
        'requests.errors.submit_failed',
      );
      expect(backend.uploads, hasLength(2));
      expect(backend.rpc('submit_service_request'), isEmpty);
      expect(backend.rpc('get_service_request'), hasLength(2));
      expect(backend.requests[3].isRpc('get_service_request'), isTrue);
      expect(backend.deletions.single.json, {
        'prefixes': backend.uploads
            .map((request) => request.objectPath)
            .toList(),
      });
      expect(backend.objects.keys, [unrelated]);
      backend.intercept = null;
      final retried = await _success(
        repository.submitRequest(draft, userId: _userId),
      );
      expect(retried.photos, hasLength(3));
      expect(backend.uploads, hasLength(5));
      expect(backend.objects[unrelated], orderedEquals(_jpeg));
    });

    for (final (name, bytes) in <(String, List<int>)>[
      ('same-length changed JPEG', [..._jpeg.take(_jpeg.length - 1), 0]),
      ('different MIME at the same size', _png),
      ('different size', [..._jpeg, 0]),
    ]) {
      test('409 with $name is never reused or deleted', () async {
        const path = '$_userId/$_requestId/$_photoId.jpg';
        backend.objects[path] = Uint8List.fromList(bytes);
        await _expectFailure(
          repository.submitRequest(
            _draft(categoryId: _categoryId, photos: [_photo()]),
            userId: _userId,
          ),
          'requests.errors.conflict',
        );
        expect(backend.uploads, hasLength(1));
        expect(backend.downloads.single.objectPath, path);
        expect(backend.rpc('submit_service_request'), isEmpty);
        expect(backend.deletions, isEmpty);
        expect(backend.objects[path], orderedEquals(bytes));
      });
    }

    test(
      '409 staged objects are reused only after exact byte matching',
      () async {
        const path = '$_userId/$_requestId/$_photoId.jpg';
        backend.objects[path] = Uint8List.fromList(_jpeg);
        final draft = _draft(categoryId: _categoryId, photos: _threePhotos());
        final saved = await _success(
          repository.submitRequest(draft, userId: _userId),
        );
        expect(
          saved.photos.map((photo) => photo.id),
          draft.photos.map((photo) => photo.id),
        );
        expect(backend.uploads, hasLength(3));
        expect(backend.downloads.single.objectPath, path);
        expect(
          backend.downloads.single.authorization,
          'Bearer test-customer-token',
        );
        expect(backend.deletions, isEmpty);
        expect(backend.objects[path], orderedEquals(_jpeg));
      },
    );

    test(
      'SQL rejection deletes new uploads but never the matching 409 object',
      () async {
        const existingPath = '$_userId/$_requestId/$_photoId.jpg';
        backend.objects[existingPath] = Uint8List.fromList(_jpeg);
        backend.intercept = (request) => request.isRpc('submit_service_request')
            ? _Reply.sqlError('requests.errors.category')
            : null;
        await _expectFailure(
          repository.submitRequest(
            _draft(categoryId: _categoryId, photos: _threePhotos()),
            userId: _userId,
          ),
          'requests.errors.category',
        );
        expect(backend.deletions.single.json, {
          'prefixes': backend.uploads
              .skip(1)
              .map((request) => request.objectPath)
              .toList(),
        });
        expect(backend.objects.keys, [existingPath]);
        expect(backend.objects[existingPath], orderedEquals(_jpeg));
      },
    );

    test('later upload collision cleans earlier new objects, not the collision or unattempted photo', () async {
      const conflictingPath = '$_userId/$_requestId/$_secondPhotoId.png';
      backend.objects[conflictingPath] = Uint8List.fromList([..._png, 0]);
      await _expectFailure(
        repository.submitRequest(
          _draft(categoryId: _categoryId, photos: _threePhotos()),
          userId: _userId,
        ),
        'requests.errors.conflict',
      );
      expect(backend.uploads, hasLength(2));
      expect(backend.deletions.single.json, {
        'prefixes': [backend.uploads.first.objectPath],
      });
      expect(backend.objects.keys, [conflictingPath]);
      expect(backend.rpc('submit_service_request'), isEmpty);
    });

    test(
      'unreadable 409 objects are never deleted or trusted for publication',
      () async {
        backend.intercept = (request) =>
            request.isUpload ? _Reply.storageError(409) : null;
        await _expectFailure(
          repository.submitRequest(
            _draft(categoryId: _categoryId, photos: [_photo()]),
            userId: _userId,
          ),
          'requests.errors.photo_unavailable',
        );
        expect(backend.downloads, hasLength(1));
        expect(backend.deletions, isEmpty);
        expect(backend.rpc('submit_service_request'), isEmpty);
      },
    );

    test('upload failure with unavailable reconciliation defers all object deletion', () async {
      backend.intercept = (request) {
        if (request.isUpload) {
          backend.respond(request);
          return _Reply.storageError(503);
        }
        if (request.isRpc('get_service_request') &&
            backend.rpc('get_service_request').length > 1) {
          return _Reply.sqlError('private read failure', status: 503);
        }
        return null;
      };
      await _expectFailure(
        repository.submitRequest(
          _draft(categoryId: _categoryId, photos: [_photo()]),
          userId: _userId,
        ),
        'requests.errors.submit_failed',
      );
      expect(backend.objects, hasLength(1));
      expect(backend.deletions, isEmpty);
      expect(backend.rpc('submit_service_request'), isEmpty);
      expect(auth.checkCalls, 1);
    });

    test('definitive SQL rejection cleans staged photos and permits exact-ID retry', () async {
      final draft = _draft(categoryId: _categoryId, photos: _threePhotos());
      backend.intercept = (request) => request.isRpc('submit_service_request')
          ? _Reply.sqlError('requests.errors.category')
          : null;
      await _expectFailure(
        repository.submitRequest(draft, userId: _userId),
        'requests.errors.category',
      );
      expect(backend.deletions.single.json, {
        'prefixes': backend.uploads
            .map((request) => request.objectPath)
            .toList(),
      });
      expect(backend.objects, isEmpty);
      expect(backend.snapshots, isEmpty);
      backend.intercept = null;
      expect(
        (await _success(repository.submitRequest(draft, userId: _userId))).id,
        draft.id,
      );
    });

    test('cleanup failure retains sanitized SQL failure and does not invent success', () async {
      backend.intercept = (request) {
        if (request.isRpc('submit_service_request')) {
          return _Reply.sqlError('requests.errors.category');
        }
        if (request.method == 'DELETE') return _Reply.storageError(403);
        return null;
      };
      final draft = _draft(categoryId: _categoryId, photos: [_photo()]);
      await _expectFailure(
        repository.submitRequest(draft, userId: _userId),
        'requests.errors.category',
      );
      expect(backend.deletions, hasLength(1));
      expect(backend.snapshots, isEmpty);
      expect(backend.objects, hasLength(1));
      backend.intercept = null;
      await _success(repository.submitRequest(draft, userId: _userId));
      expect(backend.downloads, hasLength(1));
    });

    for (final count in [0, 3]) {
      test(
        'lost transport response reconciles canonical success for $count photos',
        () async {
          backend.intercept = (request) {
            if (!request.isRpc('submit_service_request')) return null;
            backend.respond(request);
            return const _Reply.disconnected();
          };
          final draft = _draft(
            categoryId: _categoryId,
            photos: count == 0 ? [] : _threePhotos(),
          );
          final saved = await _success(
            repository.submitRequest(draft, userId: _userId),
          );
          expect(saved, ServiceRequest.fromJson(backend.snapshots[draft.id]!));
          expect(saved.photos, hasLength(count));
          expect(backend.rpc('submit_service_request'), hasLength(1));
          expect(backend.rpc('get_service_request'), hasLength(2));
          expect(backend.uploads, hasLength(count));
          expect(backend.deletions, isEmpty);
          expect(auth.checkCalls, 1);
        },
      );
    }

    test('malformed submit response reconciles even an already-cancelled canonical record', () async {
      backend.intercept = (request) {
        if (!request.isRpc('submit_service_request')) return null;
        backend.respond(request);
        backend.snapshots[_requestId] = {
          ...backend.snapshots[_requestId]!,
          'status': 'cancelled',
          'cancelled_at': _instant.toIso8601String(),
        };
        return _Reply.json({'not': 'a request'});
      };
      final saved = await _success(
        repository.submitRequest(
          _draft(categoryId: _categoryId, photos: [_photo()]),
          userId: _userId,
        ),
      );
      expect(saved.status, ServiceRequestStatus.cancelled);
      expect(backend.deletions, isEmpty);
    });

    test(
      'absent reads never clear ambiguous publication or permit later cleanup',
      () async {
        final draft = _draft(
          categoryId: _categoryId,
          photos: [_photo()],
          preferredAt: clock.add(const Duration(hours: 1)),
        );
        backend.intercept = (request) => request.isRpc('submit_service_request')
            ? const _Reply.disconnected()
            : null;
        await _expectFailure(
          repository.submitRequest(draft, userId: _userId),
          'requests.errors.submit_uncertain',
        );
        final initialSubmit = backend.rpc('submit_service_request').single;
        expect(backend.snapshots, isEmpty);
        expect(backend.objects, hasLength(1));
        expect(backend.deletions, isEmpty);
        backend.intercept = (request) => request.isRpc('submit_service_request')
            ? _Reply.sqlError('requests.errors.category')
            : null;
        await _expectFailure(
          repository.submitRequest(draft, userId: _userId),
          'requests.errors.submit_uncertain',
        );
        expect(backend.downloads, hasLength(1));
        expect(backend.rpc('submit_service_request'), hasLength(2));
        expect(backend.deletions, isEmpty);
        backend.intercept = (request) => request.isRpc('get_service_request')
            ? _Reply.sqlError('private read failure', status: 503)
            : null;
        await _expectFailure(
          repository.submitRequest(draft, userId: _userId),
          'requests.errors.submit_uncertain',
        );
        backend.intercept = null;
        clock = clock.add(const Duration(days: 2));
        await _expectFailure(
          repository.submitRequest(draft, userId: _userId),
          'requests.errors.submit_uncertain',
        );
        expect(backend.rpc('submit_service_request'), hasLength(2));
        expect(backend.deletions, isEmpty);
        // The original transaction may become visible after all those absent reads.
        backend.respond(initialSubmit);
        final canonical = await _success(
          repository.submitRequest(draft, userId: _userId),
        );
        expect(canonical.id, draft.id);
        expect(canonical.preferredAt, draft.preferredAt);
        expect(backend.objects, hasLength(1));
        expect(backend.deletions, isEmpty);
        expect(backend.rpc('submit_service_request'), hasLength(2));
      },
    );

    test('failed reconciliation after transport loss remains uncertain until canonical success', () async {
      _Request? attemptedSubmit;
      backend.intercept = (request) {
        if (request.isRpc('submit_service_request')) {
          attemptedSubmit = request;
          return const _Reply.disconnected();
        }
        if (attemptedSubmit != null && request.isRpc('get_service_request')) {
          return _Reply.sqlError('private reconciliation failure', status: 503);
        }
        return null;
      };
      final draft = _draft(categoryId: _categoryId, photos: [_photo()]);
      await _expectFailure(
        repository.submitRequest(draft, userId: _userId),
        'requests.errors.submit_uncertain',
      );
      expect(backend.deletions, isEmpty);
      expect(backend.objects, hasLength(1));
      backend.respond(attemptedSubmit!);
      backend.intercept = null;
      expect(
        (await _success(repository.submitRequest(draft, userId: _userId))).id,
        draft.id,
      );
      expect(backend.uploads, hasLength(1));
      expect(backend.rpc('submit_service_request'), hasLength(1));
      expect(backend.deletions, isEmpty);
    });

    test('a non-allowlisted publication error is uncertain rather than safe to clean', () async {
      backend.intercept = (request) => request.isRpc('submit_service_request')
          ? _Reply.sqlError(
              'requests.errors.category private detail',
              status: 503,
            )
          : null;
      await _expectFailure(
        repository.submitRequest(
          _draft(categoryId: _categoryId, photos: [_photo()]),
          userId: _userId,
        ),
        'requests.errors.submit_uncertain',
      );
      expect(backend.deletions, isEmpty);
      expect(backend.objects, hasLength(1));
    });

    test(
      'conflicting canonical reconciliation never deletes committed photos',
      () async {
        backend.intercept = (request) {
          if (!request.isRpc('submit_service_request')) return null;
          backend.respond(request);
          backend.snapshots[_requestId]!['title'] =
              'Different canonical request';
          return const _Reply.disconnected();
        };
        await _expectFailure(
          repository.submitRequest(
            _draft(categoryId: _categoryId, photos: [_photo()]),
            userId: _userId,
          ),
          'requests.errors.conflict',
        );
        expect(backend.deletions, isEmpty);
        expect(backend.objects, hasLength(1));
      },
    );

    for (final committed in [false, true]) {
      test(
        'lost cancel response ${committed ? 'reconciles cancellation' : 'cannot invent cancellation'}',
        () async {
          backend.snapshots[_requestId] = _snapshot(photos: [_photoJson()]);
          backend.objects['$_userId/$_requestId/$_photoId.jpg'] =
              Uint8List.fromList(_jpeg);
          backend.intercept = (request) {
            if (!request.isRpc('cancel_service_request')) return null;
            if (committed) backend.respond(request);
            return const _Reply.disconnected();
          };
          final pending = repository.cancelRequest(_requestId, userId: _userId);
          if (committed) {
            expect(
              (await _success(pending)).status,
              ServiceRequestStatus.cancelled,
            );
          } else {
            await _expectFailure(pending, 'requests.errors.cancel_failed');
          }
          expect(backend.rpc('cancel_service_request'), hasLength(1));
          expect(backend.rpc('get_service_request'), hasLength(2));
          expect(backend.deletions, isEmpty);
          expect(backend.objects, hasLength(1));
        },
      );
    }
    test(
      'private downloads use current auth, no public URLs, and no byte cache',
      () async {
        const path = '$_userId/$_requestId/$_photoId.jpg';
        backend.snapshots[_requestId] = _snapshot(photos: [_photoJson()]);
        backend.objects[path] = Uint8List.fromList(_jpeg);
        for (var attempt = 0; attempt < 2; attempt++) {
          final bytes = await _success(
            repository.loadPhoto(
              userId: _userId,
              requestId: _requestId,
              photoId: _photoId,
            ),
          );
          expect(bytes, orderedEquals(_jpeg));
          expect(() => bytes[0] = 0, throwsUnsupportedError);
          expect(
            () => bytes.buffer.asUint8List()[0] = 0,
            throwsUnsupportedError,
          );
        }
        expect(backend.rpc('get_service_request'), hasLength(2));
        expect(backend.downloads, hasLength(2));
        for (final download in backend.downloads) {
          expect(download.uri.path, '/storage/v1/object/request-photos/$path');
          expect(download.uri.query, isEmpty);
          expect(download.authorization, 'Bearer test-customer-token');
        }
        expect(auth.checkCalls, 2);
      },
    );

    test('invalid IDs, missing attachments, or unsafe metadata cannot reach Storage', () async {
      await _expectFailure(
        repository.loadPhoto(
          userId: _userId,
          requestId: '../private',
          photoId: _photoId,
        ),
        'requests.errors.not_found',
      );
      await _expectFailure(
        repository.loadPhoto(
          userId: _userId,
          requestId: _requestId,
          photoId: '../private',
        ),
        'requests.errors.not_found',
      );
      expect(backend.requests, isEmpty);
      await _expectFailure(
        repository.loadPhoto(
          userId: _userId,
          requestId: _requestId,
          photoId: _photoId,
        ),
        'requests.errors.photo_unavailable',
      );
      backend.snapshots[_requestId] = _snapshot();
      await _expectFailure(
        repository.loadPhoto(
          userId: _userId,
          requestId: _requestId,
          photoId: _photoId,
        ),
        'requests.errors.photo_unavailable',
      );
      for (final change in <Map<String, Object?>>[
        {'storage_path': '$_otherId/$_requestId/$_photoId.jpg'},
        {'storage_path': '$_userId/../$_photoId.jpg'},
        {'storage_path': 'https://example.test/photo.jpg'},
        {'size_bytes': 0},
        {'size_bytes': RequestPhotoInput.maxBytes + 1},
        {'mime_type': 'application/pdf'},
      ]) {
        backend.snapshots[_requestId] = _snapshot(
          photos: [
            {..._photoJson(), ...change},
          ],
        );
        await _expectFailure(
          repository.loadPhoto(
            userId: _userId,
            requestId: _requestId,
            photoId: _photoId,
          ),
          'requests.errors.invalid_request',
        );
      }
      expect(backend.downloads, isEmpty);
    });

    test(
      'private downloads accept exactly 5 MiB with matching metadata',
      () async {
        const path = '$_userId/$_requestId/$_photoId.jpg';
        backend.snapshots[_requestId] = _snapshot(
          photos: [
            {..._photoJson(), 'size_bytes': RequestPhotoInput.maxBytes},
          ],
        );
        backend.objects[path] = Uint8List(RequestPhotoInput.maxBytes)
          ..setAll(0, _jpeg);
        final bytes = await _success(
          repository.loadPhoto(
            userId: _userId,
            requestId: _requestId,
            photoId: _photoId,
          ),
        );
        expect(bytes, hasLength(RequestPhotoInput.maxBytes));
        expect(bytes.take(_jpeg.length), orderedEquals(_jpeg));
        expect(() => bytes[bytes.length - 1] = 1, throwsUnsupportedError);
      },
    );

    test(
      'oversized private streams fail before the response is closed',
      () async {
        final finish = Completer<void>();
        addTearDown(() {
          if (!finish.isCompleted) finish.complete();
        });
        backend.snapshots[_requestId] = _snapshot(photos: [_photoJson()]);
        backend.intercept = (request) => request.isDownload
            ? _Reply(
                Uint8List(RequestPhotoInput.maxBytes + 1)..setAll(0, _jpeg),
                contentType: 'image/jpeg',
                finish: finish.future,
              )
            : null;
        await _expectFailure(
          repository
              .loadPhoto(
                userId: _userId,
                requestId: _requestId,
                photoId: _photoId,
              )
              .timeout(const Duration(seconds: 5)),
          'requests.errors.photo_size',
        );
        expect(finish.isCompleted, isFalse);
        finish.complete();
        expect(backend.downloads, hasLength(1));
      },
    );

    test(
      'download bytes must match allowed type and declared manifest size/MIME',
      () async {
        const path = '$_userId/$_requestId/$_photoId.jpg';
        backend.snapshots[_requestId] = _snapshot(photos: [_photoJson()]);
        for (final (bytes, key) in <(List<int>, String)>[
          ([], 'requests.errors.photo_size'),
          ('GIF89a'.codeUnits, 'requests.errors.photo_type'),
          ([..._jpeg, 0], 'requests.errors.photo_unavailable'),
          (_png, 'requests.errors.photo_unavailable'),
        ]) {
          backend.objects[path] = Uint8List.fromList(bytes);
          await _expectFailure(
            repository.loadPhoto(
              userId: _userId,
              requestId: _requestId,
              photoId: _photoId,
            ),
            key,
          );
        }
      },
    );

    test(
      'download storage errors are sanitized without returning stale bytes',
      () async {
        backend.snapshots[_requestId] = _snapshot(photos: [_photoJson()]);
        backend.intercept = (request) =>
            request.isDownload ? _Reply.storageError(404) : null;
        await _expectFailure(
          repository.loadPhoto(
            userId: _userId,
            requestId: _requestId,
            photoId: _photoId,
          ),
          'requests.errors.photo_unavailable',
        );
        expect(backend.downloads, hasLength(1));
      },
    );

    test(
      'duplicate submit and cancel cannot unlock or overlap an active upload',
      () async {
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (request) {
          if (!request.isUpload) return null;
          started.complete();
          return response.future;
        };
        final draft = _draft(categoryId: _categoryId, photos: [_photo()]);
        final first = repository.submitRequest(draft, userId: _userId);
        await started.future;
        await _expectFailure(
          repository.submitRequest(draft, userId: _userId),
          'requests.errors.busy',
        );
        await _expectFailure(
          repository.submitRequest(
            _draft(id: _id(9), categoryId: _categoryId),
            userId: _userId,
          ),
          'requests.errors.busy',
        );
        await _expectFailure(
          repository.cancelRequest(_requestId, userId: _userId),
          'requests.errors.busy',
        );
        expect(backend.requests, hasLength(2));
        response.complete(null);
        await _success(first);
        expect(backend.uploads, hasLength(1));
        expect(backend.rpc('submit_service_request'), hasLength(1));
        await _success(repository.cancelRequest(_requestId, userId: _userId));
        expect(backend.rpc('cancel_service_request'), hasLength(1));
        expect(auth.hasListeners, isFalse);
      },
    );

    for (final history in [false, true]) {
      test(
        'logout then same-user return invalidates pending ${history ? 'history' : 'detail'}',
        () async {
          backend.snapshots[_requestId] = _snapshot();
          final started = Completer<void>();
          final response = Completer<_Reply?>();
          backend.intercept = (_) {
            started.complete();
            return response.future;
          };
          final pending = history
              ? repository.loadRequests(userId: _userId)
              : repository.loadRequest(_requestId, userId: _userId);
          await started.future;
          auth.change(const AuthSession());
          auth.change(const AuthSession(user: _customer));
          response.complete(null);
          await _expectFailure(pending, 'requests.errors.access');
          expect(backend.requests, hasLength(1));
          expect(auth.hasListeners, isFalse);
        },
      );
    }

    test('raw SDK switch during upload prevents publication and new-account cleanup', () async {
      final started = Completer<void>();
      final response = Completer<_Reply?>();
      backend.intercept = (request) {
        if (!request.isUpload) return null;
        started.complete();
        return response.future;
      };
      final draft = _draft(categoryId: _categoryId, photos: [_photo()]);
      final pending = repository.submitRequest(draft, userId: _userId);
      await started.future;
      await backend.setSession(userId: _otherId);
      expect(auth.session.user, _customer);
      response.complete(null);
      await _expectFailure(pending, 'requests.errors.access');
      expect(
        backend.uploads.single.objectPath,
        '$_userId/$_requestId/$_photoId.jpg',
      );
      expect(backend.rpc('submit_service_request'), isEmpty);
      expect(backend.rpc('get_service_request'), hasLength(1));
      expect(backend.deletions, isEmpty);
      await backend.setSession();
      backend.intercept = null;
      expect(
        (await _success(repository.submitRequest(draft, userId: _userId))).id,
        draft.id,
      );
      expect(backend.downloads, hasLength(1));
    });

    test('session replacement during publication cannot return or clean old-account data', () async {
      final started = Completer<void>();
      final response = Completer<_Reply?>();
      backend.intercept = (request) {
        if (!request.isRpc('submit_service_request')) return null;
        started.complete();
        return response.future;
      };
      final pending = repository.submitRequest(
        _draft(categoryId: _categoryId, photos: [_photo()]),
        userId: _userId,
      );
      await started.future;
      await backend.setSession(userId: _otherId);
      auth.change(const AuthSession(user: _otherCustomer));
      response.complete(null);
      await _expectFailure(pending, 'requests.errors.access');
      expect(backend.requests, hasLength(3));
      expect(backend.snapshots[_requestId]!['customer_id'], _userId);
      expect(backend.deletions, isEmpty);
      expect(backend.rpc('get_service_request'), hasLength(1));
    });

    test('a mapped account switch during download prevents returning private bytes', () async {
      backend.snapshots[_requestId] = _snapshot(photos: [_photoJson()]);
      backend.objects['$_userId/$_requestId/$_photoId.jpg'] =
          Uint8List.fromList(_jpeg);
      final started = Completer<void>();
      final response = Completer<_Reply?>();
      backend.intercept = (request) {
        if (!request.isDownload) return null;
        started.complete();
        return response.future;
      };
      final pending = repository.loadPhoto(
        userId: _userId,
        requestId: _requestId,
        photoId: _photoId,
      );
      await started.future;
      auth.change(const AuthSession(user: _otherCustomer));
      response.complete(null);
      await _expectFailure(pending, 'requests.errors.access');
      expect(
        backend.downloads.single.authorization,
        'Bearer test-customer-token',
      );
    });

    test('raw SDK identity must match the captured owner before mapped auth or HTTP', () async {
      await backend.setSession(userId: _otherId);
      await _expectAllDenied(repository);
      expect(backend.requests, isEmpty);
      expect(auth.checkCalls, 0);
    });

    for (final type in [OtpType.email, OtpType.recovery]) {
      test(
        'raw ${type.name} auth transition invalidates a same-user pending operation',
        () async {
          backend.snapshots[_requestId] = _snapshot();
          final started = Completer<void>();
          final response = Completer<_Reply?>();
          backend.intercept = (request) {
            if (!request.isRpc('get_service_request')) return null;
            started.complete();
            return response.future;
          };
          final pending = repository.loadRequest(_requestId, userId: _userId);
          await started.future;
          await backend.client.auth.verifyOTP(
            email: _customer.email,
            token: '123456',
            type: type,
          );
          expect(auth.session, const AuthSession(user: _customer));
          response.complete(null);
          await _expectFailure(pending, 'requests.errors.access');
          expect(auth.checkCalls, 1);
        },
      );
    }

    test(
      'same-user SDK session replacement cannot revive an in-flight read',
      () async {
        backend.snapshots[_requestId] = _snapshot();
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (_) {
          started.complete();
          return response.future;
        };
        final pending = repository.loadRequest(_requestId, userId: _userId);
        await started.future;
        final before = backend.client.auth.currentSession;
        final replacement = backend.client.auth.onAuthStateChange.firstWhere(
          (state) =>
              state.event == AuthChangeEvent.initialSession &&
              !identical(state.session, before),
        );
        await backend.setSession();
        expect((await replacement).session!.user.id, _userId);
        response.complete(null);
        await _expectFailure(pending, 'requests.errors.access');
      },
    );

    test('normal token refresh preserves an authorized pending read', () async {
      backend.snapshots[_requestId] = _snapshot();
      final started = Completer<void>();
      final response = Completer<_Reply?>();
      backend.intercept = (request) {
        if (!request.isRpc('get_service_request')) return null;
        started.complete();
        return response.future;
      };
      final pending = repository.loadRequest(_requestId, userId: _userId);
      await started.future;
      await backend.client.auth.refreshSession();
      response.complete(null);
      expect(await _success(pending), ServiceRequest.fromJson(_snapshot()));
      expect(auth.checkCalls, 1);
    });

    test('restored same-user sessions tolerate initial replay without extra auth reads', () async {
      backend.snapshots[_requestId] = _snapshot();
      final before = backend.client.auth.currentSession;
      await backend.client.auth.recoverSession(
        jsonEncode(backend.sessionJson()),
      );
      expect(identical(backend.client.auth.currentSession, before), isFalse);
      expect(
        await _success(repository.loadRequest(_requestId, userId: _userId)),
        ServiceRequest.fromJson(_snapshot()),
      );
      expect(auth.checkCalls, 1);
      expect(backend.requests, hasLength(1));
    });

    test('replayed raw password recovery stays blocked before mapped profile catches up', () async {
      await backend.client.auth.verifyOTP(
        email: _customer.email,
        token: '123456',
        type: OtpType.recovery,
      );
      backend.requests.clear();
      expect(auth.session, const AuthSession(user: _customer));
      await _expectAllDenied(repository);
      expect(backend.requests, isEmpty);
    });
  });
}

String _id(int number) =>
    '00000000-0000-4000-8000-${number.toRadixString(16).padLeft(12, '0')}';

ServiceRequestDraft _draft({
  String id = _requestId,
  String categoryId = 'demo-plumbing',
  List<RequestPhotoInput> photos = const [],
  DateTime? preferredAt,
}) => ServiceRequestDraft(
  id: id,
  categoryId: categoryId,
  title: 'Leaking kitchen tap',
  description: 'The kitchen tap leaks continuously.',
  city: 'Cairo',
  address: '12 Sample Street',
  preferredAt: preferredAt,
  photos: photos,
  consent: true,
);

RequestPhotoInput _photo({String id = _photoId, List<int> bytes = _jpeg}) =>
    RequestPhotoInput.fromBytes(Uint8List.fromList(bytes), id: id);

List<RequestPhotoInput> _threePhotos() => [
  _photo(),
  _photo(id: _secondPhotoId, bytes: _png),
  _photo(id: _thirdPhotoId),
];

Map<String, dynamic> _snapshot({
  String id = _requestId,
  String userId = _userId,
  List<Map<String, Object?>> photos = const [],
}) => {
  'id': id,
  'customer_id': userId,
  'category_id': _categoryId,
  'category_name_en': 'Plumbing',
  'category_name_ar': 'Plumbing AR',
  'category_icon_key': 'plumbing',
  'title': 'Leaking kitchen tap',
  'description': 'The kitchen tap leaks continuously.',
  'city': 'Cairo',
  'address': '12 Sample Street',
  'preferred_at': null,
  'status': 'open',
  'created_at': _instant.toIso8601String(),
  'consented_at': _instant.toIso8601String(),
  'cancelled_at': null,
  'photos': photos,
};

Map<String, Object?> _photoJson({
  String id = _photoId,
  int position = 1,
  bool png = false,
}) => {
  'id': id,
  'storage_path': '$_userId/$_requestId/$id.${png ? 'png' : 'jpg'}',
  'mime_type': png ? 'image/png' : 'image/jpeg',
  'size_bytes': png ? _png.length : _jpeg.length,
  'position': position,
};

Future<T> _success<T>(FutureEither<T> task) async =>
    (await task).fold((failure) => fail(failure.message), (value) => value);

Future<Failure> _expectFailure<T>(FutureEither<T> task, String key) async {
  final failure = (await task).fold(
    (failure) => failure,
    (_) => fail('Expected $key'),
  );
  expect(failure.message, key);
  expect(failure.error, isNull);
  return failure;
}

Future<void> _expectAllDenied(
  ServiceRequestRepository repository, {
  String userId = _userId,
  String key = 'requests.errors.access',
}) async {
  await _expectFailure(repository.loadRequests(userId: userId), key);
  await _expectFailure(repository.loadRequest(_requestId, userId: userId), key);
  await _expectFailure(
    repository.submitRequest(_draft(categoryId: _categoryId), userId: userId),
    key,
  );
  await _expectFailure(
    repository.cancelRequest(_requestId, userId: userId),
    key,
  );
  await _expectFailure(
    repository.loadPhoto(
      userId: userId,
      requestId: _requestId,
      photoId: _photoId,
    ),
    key,
  );
}

class _SessionAuth extends DemoAuthRepository {
  _SessionAuth({required this.demo});

  final bool demo;
  AuthSession session = const AuthSession(user: _customer);
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

/// Only loopback HTTP is used; serialization and auth events use the real SDK.
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
  final requests = <_Request>[];
  final snapshots = <String, Map<String, dynamic>>{};
  final objects = <String, Uint8List>{};
  FutureOr<_Reply?> Function(_Request)? intercept;
  int cancelledResponses = 0;

  Iterable<_Request> get uploads =>
      requests.where((request) => request.isUpload);
  Iterable<_Request> get deletions =>
      requests.where((request) => request.method == 'DELETE');
  Iterable<_Request> get downloads =>
      requests.where((request) => request.isDownload);
  Iterable<_Request> rpc(String name) =>
      requests.where((request) => request.isRpc(name));

  static Future<_Backend> start() async {
    final backend = _Backend(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    await backend.setSession();
    return backend;
  }

  Map<String, Object?> sessionJson({String userId = _userId}) => {
    'access_token': 'test-customer-token',
    'refresh_token': 'test-refresh-token',
    'token_type': 'bearer',
    'user': {
      'id': userId,
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
      'aud': 'authenticated',
      'created_at': '2026-10-31T00:00:00Z',
    },
  };

  Future<void> setSession({String userId = _userId}) =>
      client.auth.setInitialSession(jsonEncode(sessionJson(userId: userId)));

  Future<void> _handle(HttpRequest incoming) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in incoming) {
      builder.add(chunk);
    }
    final request = _Request(
      incoming.method,
      incoming.uri,
      builder.takeBytes(),
      incoming.headers.value(HttpHeaders.authorizationHeader),
      incoming.headers.value('x-upsert'),
      incoming.headers.contentType,
    );
    requests.add(request);
    final reply = await intercept?.call(request) ?? respond(request);
    if (reply.disconnect) {
      final socket = await incoming.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    incoming.response.statusCode = reply.status;
    incoming.response.headers.contentType = ContentType.parse(
      reply.contentType,
    );
    try {
      incoming.response.add(reply.bytes);
      if (reply.finish != null) {
        await incoming.response.flush();
        await reply.finish;
      }
      await incoming.response.close();
    } on HttpException {
      // Bounded clients may cancel before a large or held-open response ends.
      cancelledResponses++;
    }
  }

  _Reply respond(_Request request) {
    if (request.uri.path == '/auth/v1/verify' ||
        request.uri.path == '/auth/v1/token') {
      return _Reply.json(sessionJson());
    }
    if (request.isRpc('get_service_request')) {
      return _Reply.json(snapshots[request.json['p_request_id']]);
    }
    if (request.uri.path == '/rest/v1/service_requests') {
      return _Reply.json(snapshots.values.toList());
    }
    if (request.isUpload) {
      if (objects.containsKey(request.objectPath)) {
        return _Reply.storageError(409);
      }
      objects[request.objectPath] = request.photoBytes;
      return _Reply.json({'Key': 'request-photos/${request.objectPath}'});
    }
    if (request.isRpc('submit_service_request')) {
      final params = request.json;
      final id = params['p_request_id'] as String;
      final manifest = params['p_photos'] as List;
      final snapshot = snapshots.putIfAbsent(
        id,
        () => {
          ..._snapshot(id: id),
          'category_id': params['p_category_id'],
          'title': params['p_title'],
          'description': params['p_description'],
          'city': params['p_city'],
          'address': params['p_address'],
          'preferred_at': params['p_preferred_at'],
          'photos': [
            for (final (index, photo) in manifest.indexed)
              {...photo as Map<String, dynamic>, 'position': index + 1},
          ],
        },
      );
      return _Reply.json(snapshot);
    }
    if (request.isRpc('cancel_service_request')) {
      final id = request.json['p_request_id'] as String;
      final snapshot = snapshots[id];
      if (snapshot == null) return _Reply.sqlError('requests.errors.not_found');
      snapshots[id] = {
        ...snapshot,
        'status': 'cancelled',
        'cancelled_at': _instant
            .add(const Duration(hours: 1))
            .toIso8601String(),
      };
      return _Reply.json(snapshots[id]);
    }
    if (request.method == 'DELETE' &&
        request.uri.path == '/storage/v1/object/request-photos') {
      final paths = (request.json['prefixes'] as List).cast<String>();
      for (final path in paths) {
        objects.remove(path);
      }
      return _Reply.json([
        for (final path in paths) {'name': path},
      ]);
    }
    if (request.isDownload) {
      final bytes = objects[request.objectPath];
      return bytes == null
          ? _Reply.storageError(404)
          : _Reply(bytes, contentType: 'application/octet-stream');
    }
    throw StateError(
      'Unexpected loopback request: ${request.method} ${request.uri}',
    );
  }

  Future<void> close() async {
    await client.dispose();
    await server.close(force: true);
  }
}

class _Request {
  const _Request(
    this.method,
    this.uri,
    this.bytes,
    this.authorization,
    this.upsert,
    this.contentType,
  );

  final String method;
  final Uri uri;
  final Uint8List bytes;
  final String? authorization;
  final String? upsert;
  final ContentType? contentType;
  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  bool isRpc(String name) => uri.path == '/rest/v1/rpc/$name';
  bool get isUpload =>
      method == 'POST' &&
      uri.path.startsWith('/storage/v1/object/request-photos/');
  bool get isDownload =>
      method == 'GET' &&
      uri.path.startsWith('/storage/v1/object/request-photos/');
  String get objectPath =>
      uri.path.substring('/storage/v1/object/request-photos/'.length);

  Uint8List get photoBytes {
    final boundary = contentType?.parameters['boundary'];
    if (boundary == null) throw StateError('Expected multipart upload.');
    for (final part in latin1.decode(bytes).split('--$boundary')) {
      if (!part.toLowerCase().contains('content-type: image/')) continue;
      final start = part.indexOf('\r\n\r\n') + 4;
      return Uint8List.fromList(
        latin1.encode(part.substring(start, part.length - 2)),
      );
    }
    throw StateError('Missing image upload part.');
  }
}

class _Reply {
  const _Reply(
    this.bytes, {
    this.status = 200,
    this.contentType = 'application/json',
    this.finish,
  }) : disconnect = false;

  const _Reply.disconnected()
    : bytes = const [],
      status = 200,
      contentType = 'application/json',
      disconnect = true,
      finish = null;

  factory _Reply.json(Object? value, {int status = 200}) =>
      _Reply(utf8.encode(jsonEncode(value)), status: status);

  factory _Reply.sqlError(
    String message, {
    String code = 'P0001',
    int status = 400,
  }) => _Reply.json({
    'code': code,
    'message': message,
    'details': 'private backend details',
    'hint': 'private hint',
  }, status: status);

  factory _Reply.storageError(int status) => _Reply.json({
    'statusCode': '$status',
    'message': 'private storage error',
  }, status: status);

  final List<int> bytes;
  final int status;
  final String contentType;
  final bool disconnect;
  final Future<void>? finish;
}
