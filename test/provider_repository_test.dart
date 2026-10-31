import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/models/verification_document.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/provider_repository.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';

const _userId = '11111111-1111-4111-8111-111111111111';
const _otherId = '22222222-2222-4222-8222-222222222222';
const _skillId = '33333333-3333-4333-8333-333333333333';
const _verificationId = '44444444-4444-4444-8444-444444444444';
const _oldPath = '$_userId/00000000000000000000000000000000.jpg';
const _jpeg = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x02, 0xff, 0xd9];
const _png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const _hours = ProviderAvailability(
  weekday: 1,
  startMinute: 540,
  endMinute: 1020,
);
const _provider = AppUser(
  id: _userId,
  email: 'provider@example.test',
  name: 'Provider',
  role: UserRole.provider,
);
const _otherProvider = AppUser(
  id: _otherId,
  email: 'other@example.test',
  name: 'Other Provider',
  role: UserRole.provider,
);

void main() {
  group('ProviderProfile', () {
    test('empty drafts are editable, not ready to submit, and immutable', () {
      final profile = ProviderProfile.empty(_userId);
      expect(profile.userId, _userId);
      expect(profile.bio, isEmpty);
      expect(profile.skillIds, isEmpty);
      expect(profile.serviceAreas, isEmpty);
      expect(profile.availability, isEmpty);
      expect(profile.verification, isNull);
      expect(profile.canEdit, isTrue);
      expect(profile.canSubmit, isTrue);
      expect(profile.validate(), isNull);
      expect(profile.validate(forSubmission: true), 'provider.errors.bio');
      expect(() => profile.skillIds.add('arbitrary'), throwsUnsupportedError);
    });

    test('constructors and copyWith defensively copy all lists', () {
      final skills = ['demo-plumbing'];
      final areas = ['Cairo'];
      final hours = [_hours];
      final profile = ProviderProfile(
        userId: _userId,
        skillIds: skills,
        serviceAreas: areas,
        availability: hours,
      );
      skills.clear();
      areas.clear();
      hours.clear();
      expect(profile.skillIds, ['demo-plumbing']);
      expect(profile.serviceAreas, ['Cairo']);
      expect(profile.availability, [_hours]);
      expect(() => profile.serviceAreas.clear(), throwsUnsupportedError);
      expect(() => profile.availability.clear(), throwsUnsupportedError);
      final replacement = ['Giza'];
      final copied = profile.copyWith(serviceAreas: replacement);
      replacement.clear();
      expect(copied.serviceAreas, ['Giza']);
      expect(copied.skillIds, profile.skillIds);
      expect(copied, profile.copyWith(serviceAreas: ['Giza']));
      expect(copied, isNot(profile));
    });

    test(
      'submission minima identify their fields without rejecting drafts',
      () {
        final complete = _profile();
        expect(complete.validate(forSubmission: true), isNull);
        final cases = <ProviderProfile, String>{
          complete.copyWith(bio: 'Too short'): 'provider.errors.bio',
          complete.copyWith(skillIds: []): 'provider.errors.skills',
          complete.copyWith(serviceAreas: []): 'provider.errors.areas',
          complete.copyWith(availability: []): 'provider.errors.availability',
        };
        for (final entry in cases.entries) {
          expect(entry.key.validate(), isNull);
          expect(entry.key.validate(forSubmission: true), entry.value);
        }
        expect(
          _profile().copyWith(bio: 'x' * 20).validate(forSubmission: true),
          isNull,
        );
      },
    );

    test('validates identity, trimmed character lengths, and skill limits', () {
      final profile = _profile();
      expect(
        profile.copyWith(userId: '  ').validate(),
        'provider.errors.invalid_profile',
      );
      expect(
        profile.copyWith(bio: 'x' * 1001).validate(),
        'provider.errors.bio',
      );
      expect(profile.copyWith(bio: '  ${'x' * 1000}  ').validate(), isNull);
      final supplementaryCharacter = String.fromCharCode(0x1f600);
      expect(
        profile.copyWith(bio: supplementaryCharacter * 1000).validate(),
        isNull,
      );
      expect(
        profile.copyWith(bio: supplementaryCharacter * 1001).validate(),
        'provider.errors.bio',
      );
      for (final skills in <List<String>>[
        [''],
        ['  '],
        [' demo-plumbing'],
        ['duplicate', 'duplicate'],
        ['ABC', 'abc'],
        List.generate(21, (index) => 'skill-$index'),
      ]) {
        expect(
          profile.copyWith(skillIds: skills).validate(),
          'provider.errors.skills',
        );
      }
      expect(
        profile
            .copyWith(skillIds: List.generate(20, (index) => 'skill-$index'))
            .validate(),
        isNull,
      );
    });

    test('validates normalized unique service-area labels', () {
      for (final areas in <List<String>>[
        [''],
        ['a'],
        [' ${'x' * 101} '],
        [' Cairo ', 'cAiRo'],
        List.generate(11, (index) => 'Area $index'),
      ]) {
        expect(
          _profile().copyWith(serviceAreas: areas).validate(),
          'provider.errors.areas',
        );
      }
      expect(
        _profile().copyWith(serviceAreas: [' XX ', 'y' * 100]).validate(),
        isNull,
      );
      expect(
        _profile()
            .copyWith(serviceAreas: List.generate(10, (index) => 'Area $index'))
            .validate(),
        isNull,
      );
    });

    test(
      'accepts ISO weekdays and rejects duplicate/overnight/outside hours',
      () {
        for (final hours in <List<ProviderAvailability>>[
          [_hours, _hours],
          [
            const ProviderAvailability(
              weekday: 0,
              startMinute: 0,
              endMinute: 1,
            ),
          ],
          [
            const ProviderAvailability(
              weekday: 8,
              startMinute: 0,
              endMinute: 1,
            ),
          ],
          [
            const ProviderAvailability(
              weekday: 1,
              startMinute: -1,
              endMinute: 1,
            ),
          ],
          [
            const ProviderAvailability(
              weekday: 1,
              startMinute: 0,
              endMinute: 0,
            ),
          ],
          [
            const ProviderAvailability(
              weekday: 1,
              startMinute: 1440,
              endMinute: 1440,
            ),
          ],
          [
            const ProviderAvailability(
              weekday: 1,
              startMinute: 0,
              endMinute: 1441,
            ),
          ],
          [
            const ProviderAvailability(
              weekday: 1,
              startMinute: 1200,
              endMinute: 60,
            ),
          ],
        ]) {
          expect(
            _profile().copyWith(availability: hours).validate(),
            'provider.errors.availability',
          );
        }
        final fullWeek = List.generate(
          7,
          (index) => ProviderAvailability(
            weekday: index + 1,
            startMinute: 0,
            endMinute: 1440,
          ),
        );
        expect(_profile().copyWith(availability: fullWeek).validate(), isNull);
        expect(
          _profile()
              .copyWith(
                availability: const [
                  ProviderAvailability(
                    weekday: 7,
                    startMinute: 1439,
                    endMinute: 1440,
                  ),
                ],
              )
              .validate(),
          isNull,
        );
        expect(_hours.toJson(), {
          'weekday': 1,
          'start_minute': 540,
          'end_minute': 1020,
        });
        expect(ProviderAvailability.fromJson(_hours.toJson()), _hours);
      },
    );

    test(
      'maps SQL snapshots, nullable reviews, UTC times, and lifecycle rules',
      () {
        final emptyVerification = ProviderProfile.fromJson(_snapshot());
        expect(emptyVerification.verification, isNull);
        for (final status in ProviderVerificationStatus.values) {
          final profile = ProviderProfile.fromJson(
            _snapshot(status: status.name),
          );
          final verification = profile.verification!;
          expect(profile.skillIds, [_skillId]);
          expect(profile.availability, [_hours]);
          expect(verification.id, _verificationId);
          expect(verification.documentPath, _oldPath);
          expect(verification.mimeType, 'image/jpeg');
          expect(verification.sizeBytes, _jpeg.length);
          expect(verification.status, status);
          expect(verification.submittedAt, DateTime.utc(2026, 10, 18, 8));
          expect(
            verification.reviewedAt,
            status == ProviderVerificationStatus.pending
                ? null
                : DateTime.utc(2026, 10, 18, 9),
          );
          expect(
            verification.reviewNote,
            status == ProviderVerificationStatus.pending ? null : 'Review note',
          );
          expect(profile.canEdit, status != ProviderVerificationStatus.pending);
          expect(
            profile.canSubmit,
            status == ProviderVerificationStatus.rejected,
          );
          expect(profile.copyWith(), profile);
          expect(profile.copyWith(bio: 'Changed').verification, verification);
          expect(profile.copyWith(verification: null).verification, isNull);
          expect(profile.toString(), isNot(contains(_oldPath)));
          expect(verification.toString(), isNot(contains(_oldPath)));
        }
        expect(
          () => ProviderProfile.fromJson(_snapshot(status: 'unknown')),
          throwsArgumentError,
        );
      },
    );
  });

  group('ProviderRepository demo and access', () {
    late _SessionAuth auth;
    late ProviderRepository repository;

    setUp(() {
      auth = _SessionAuth(demo: true);
      repository = ProviderRepository(authRepository: auth);
    });
    tearDown(() => auth.dispose());

    test(
      'all operations reject signed-out, customer, foreign, and recovery users',
      () async {
        for (final session in const [
          AuthSession(),
          AuthSession(
            user: AppUser(
              id: _userId,
              email: 'customer@example.test',
              name: 'Customer',
            ),
          ),
          AuthSession(user: _otherProvider),
          AuthSession(user: _provider, needsPasswordUpdate: true),
        ]) {
          auth.change(session);
          await _expectFailure(
            repository.loadProfile(_userId),
            'provider.errors.access',
          );
          await _expectFailure(
            repository.saveProfile(_profile()),
            'provider.errors.access',
          );
          await _expectFailure(
            repository.submitVerification(
              userId: _userId,
              document: _document(),
              consent: true,
            ),
            'provider.errors.access',
          );
          await _expectFailure(
            repository.loadDocument(
              userId: _userId,
              verificationId: _verificationId,
            ),
            'provider.errors.access',
          );
          expect(auth.hasListeners, isFalse);
        }
        auth.change(const AuthSession(user: _provider));
        await _expectFailure(
          repository.loadProfile(''),
          'provider.errors.access',
        );
        await _expectFailure(
          repository.loadProfile(_otherId),
          'provider.errors.access',
        );
      },
    );

    test(
      'drafts persist locally, normalize fields, and reject arbitrary skills',
      () async {
        expect(repository.isDemo, isTrue);
        expect(
          await _success(repository.loadProfile(_userId)),
          ProviderProfile.empty(_userId),
        );
        final saved = await _success(
          repository.saveProfile(
            _profile().copyWith(
              bio: '  Skilled plumbing provider.  ',
              serviceAreas: [' Cairo '],
            ),
          ),
        );
        expect(saved.bio, 'Skilled plumbing provider.');
        expect(saved.serviceAreas, ['Cairo']);
        expect(await _success(repository.loadProfile(_userId)), saved);
        await _expectFailure(
          repository.saveProfile(saved.copyWith(skillIds: ['made-up-skill'])),
          'provider.errors.skills',
        );
        expect(await _success(repository.loadProfile(_userId)), saved);
        final fresh = ProviderRepository(authRepository: auth);
        expect(
          await _success(fresh.loadProfile(_userId)),
          ProviderProfile.empty(_userId),
        );
        expect(auth.hasListeners, isFalse);
      },
    );

    test('client-provided verification cannot grant approval or bypass pending lock', () async {
      final forged = ProviderProfile.fromJson(_snapshot(status: 'verified'))
          .verification!;
      final saved = await _success(
        repository.saveProfile(_profile().copyWith(verification: forged)),
      );
      expect(saved.verification, isNull);
      final submitted = await _success(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
      );
      expect(
        submitted.verification!.status,
        ProviderVerificationStatus.pending,
      );
      expect(submitted.canEdit, isFalse);
      expect(submitted.canSubmit, isFalse);
      await _expectFailure(
        repository.saveProfile(
          submitted.copyWith(bio: 'Forged change', verification: null),
        ),
        'provider.errors.locked',
      );
      await _expectFailure(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
        'provider.errors.locked',
      );
      expect(await _success(repository.loadProfile(_userId)), submitted);
      final bytes = await _success(
        repository.loadDocument(
          userId: _userId,
          verificationId: submitted.verification!.id,
        ),
      );
      expect(bytes, orderedEquals(_jpeg));
      expect(() => bytes[0] = 0, throwsUnsupportedError);
      await _expectFailure(
        repository.loadDocument(
          userId: _userId,
          verificationId: 'old-or-foreign',
        ),
        'provider.errors.document_unavailable',
      );
    });

    test(
      'consent and complete saved profile are required before submission',
      () async {
        await _expectFailure(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: false,
          ),
          'provider.errors.consent',
        );
        await _expectFailure(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
          'provider.errors.bio',
        );
        final draft = await _success(repository.loadProfile(_userId));
        expect(draft.verification, isNull);
      },
    );

    test(
      'account switches isolate drafts and the latest in-memory evidence',
      () async {
        await _success(repository.saveProfile(_profile()));
        final alice = await _success(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
        );
        auth.change(const AuthSession(user: _otherProvider));
        await _expectFailure(
          repository.loadProfile(_userId),
          'provider.errors.access',
        );
        expect(
          await _success(repository.loadProfile(_otherId)),
          ProviderProfile.empty(_otherId),
        );
        await _expectFailure(
          repository.loadDocument(
            userId: _otherId,
            verificationId: alice.verification!.id,
          ),
          'provider.errors.document_unavailable',
        );
        final bob = await _success(
          repository.saveProfile(
            _profile(userId: _otherId).copyWith(serviceAreas: ['Giza']),
          ),
        );
        auth.change(const AuthSession(user: _provider));
        expect(await _success(repository.loadProfile(_userId)), alice);
        auth.change(const AuthSession(user: _otherProvider));
        expect(await _success(repository.loadProfile(_otherId)), bob);
      },
    );

    test(
      'overlapping writes are bounded, and locks release after completion',
      () async {
        final firstSave = repository.saveProfile(_profile());
        await _expectFailure(
          repository.saveProfile(_profile()),
          'provider.errors.locked',
        );
        await _success(firstSave);
        final firstSubmit = repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        );
        await _expectFailure(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
          'provider.errors.locked',
        );
        final submitted = await _success(firstSubmit);
        expect(await _success(repository.loadProfile(_userId)), submitted);
      },
    );

    test(
      'logout and same-user re-login invalidate a stale authorization result',
      () async {
        final pending = Completer<Either<Failure, AuthSession>>();
        auth.checkOverride = () => pending.future;
        final result = repository.saveProfile(_profile());
        auth.change(const AuthSession());
        auth.change(const AuthSession(user: _provider));
        pending.complete(right(const AuthSession(user: _provider)));
        await _expectFailure(result, 'provider.errors.access');
        auth.checkOverride = null;
        expect(
          await _success(repository.loadProfile(_userId)),
          ProviderProfile.empty(_userId),
        );
        expect(auth.hasListeners, isFalse);
      },
    );

    test(
      'failed authorization checks do not use cached/demo profile data',
      () async {
        await _success(repository.saveProfile(_profile()));
        auth.checkOverride = () async =>
            left(const NetworkFailure('errors.network'));
        await _expectFailure(
          repository.loadProfile(_userId),
          'provider.errors.access',
        );
      },
    );

    test(
      'works with the real demo auth repository and its provider identity',
      () async {
        final demoAuth = DemoAuthRepository();
        addTearDown(demoAuth.dispose);
        final user = await _success(
          demoAuth.login(
            email: DemoAuthRepository.providerEmail,
            password: DemoAuthRepository.demoPassword,
          ),
        );
        final demo = ProviderRepository(authRepository: demoAuth);
        await _success(demo.saveProfile(_profile(userId: user.id)));
        final profile = await _success(
          demo.submitVerification(
            userId: user.id,
            document: _document(),
            consent: true,
          ),
        );
        expect(
          await _success(
            demo.loadDocument(
              userId: user.id,
              verificationId: profile.verification!.id,
            ),
          ),
          orderedEquals(_jpeg),
        );
        await _success(demoAuth.logout());
        await _expectFailure(
          demo.loadProfile(user.id),
          'provider.errors.access',
        );
      },
    );

    test(
      'live mode with a missing client fails without demo fallback',
      () async {
        final liveAuth = _SessionAuth(demo: false);
        addTearDown(liveAuth.dispose);
        final live = ProviderRepository(authRepository: liveAuth);
        expect(live.isDemo, isFalse);
        await _expectFailure(
          live.loadProfile(_userId),
          'errors.database_setup',
        );
        await _expectFailure(
          live.saveProfile(_profile()),
          'errors.database_setup',
        );
        await _expectFailure(
          live.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
          'errors.database_setup',
        );
        await _expectFailure(
          live.loadDocument(userId: _userId, verificationId: _verificationId),
          'errors.database_setup',
        );
      },
    );
  });

  group('ProviderRepository live fake transport', () {
    late _Backend backend;
    late _SessionAuth auth;
    late ProviderRepository repository;

    setUp(() async {
      backend = await _Backend.start();
      auth = _SessionAuth(demo: false);
      repository = ProviderRepository(
        authRepository: auth,
        client: backend.client,
      );
    });
    tearDown(() async {
      await backend.close();
      await auth.dispose();
    });

    test(
      'loads the owned snapshot through an authenticated scoped RPC',
      () async {
        final profile = await _success(repository.loadProfile(_userId));
        expect(repository.isDemo, isFalse);
        expect(profile, ProviderProfile.fromJson(backend.snapshot));
        final request = backend.requests.single;
        expect(request.method, 'POST');
        expect(request.uri.path, '/rest/v1/rpc/get_provider_onboarding');
        expect(request.json, {'p_provider_id': _userId});
        expect(request.authorization, 'Bearer test-provider-token');
        expect(auth.checkCalls, 1);
        expect(auth.hasListeners, isFalse);
      },
    );

    test(
      'saves only allowed fields with exact SQL names, never verification',
      () async {
        backend.snapshot = _snapshot(status: 'verified');
        final input = _profile(skillId: _skillId).copyWith(
          bio: '  Experienced home service provider.  ',
          serviceAreas: [' Cairo '],
        );
        final saved = await _success(repository.saveProfile(input));
        expect(saved.verification!.status, ProviderVerificationStatus.verified);
        expect(saved.canEdit, isTrue);
        final request = backend.requests.single;
        expect(request.uri.path, '/rest/v1/rpc/save_provider_onboarding');
        expect(request.json, {
          'p_provider_id': _userId,
          'p_bio': 'Experienced home service provider.',
          'p_skill_ids': [_skillId],
          'p_service_areas': ['Cairo'],
          'p_availability': [_hours.toJson()],
        });
      },
    );

    test('explicit demo mode ignores even an injected live client', () async {
      final demoAuth = _SessionAuth(demo: true);
      addTearDown(demoAuth.dispose);
      final demo = ProviderRepository(
        authRepository: demoAuth,
        client: backend.client,
      );
      expect(demo.isDemo, isTrue);
      await _success(demo.saveProfile(_profile()));
      final profile = await _success(
        demo.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
      );
      await _success(
        demo.loadDocument(
          userId: _userId,
          verificationId: profile.verification!.id,
        ),
      );
      expect(backend.requests, isEmpty);
    });

    test('forbidden callers never send RPC or Storage requests', () async {
      for (final session in const [
        AuthSession(),
        AuthSession(user: _otherProvider),
        AuthSession(user: _provider, needsPasswordUpdate: true),
      ]) {
        auth.change(session);
        await _expectFailure(
          repository.loadProfile(_userId),
          'provider.errors.access',
        );
        await _expectFailure(
          repository.saveProfile(_profile(skillId: _skillId)),
          'provider.errors.access',
        );
        await _expectFailure(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
          'provider.errors.access',
        );
      }
      expect(backend.requests, isEmpty);
    });

    test(
      'allowlists exact SQL error keys and never retains server details',
      () async {
        for (final key in [
          'access',
          'invalid_profile',
          'bio',
          'skills',
          'areas',
          'availability',
          'incomplete',
          'consent',
          'locked',
          'document_unavailable',
          'document_type',
          'document_size',
        ]) {
          backend.intercept = (_) => _Reply.sqlError('provider.errors.$key');
          final failure = await _expectFailure(
            repository.loadProfile(_userId),
            'provider.errors.$key',
          );
          expect(failure.error, isNull);
        }
        backend.intercept = (_) =>
            _Reply.sqlError('provider.errors.access private path/token');
        final failure = await _expectFailure(
          repository.loadProfile(_userId),
          'errors.request_failed',
        );
        expect(failure.error, isNull);
        backend.intercept = (_) =>
            _Reply.sqlError('missing function', code: 'PGRST202');
        await _expectFailure(
          repository.loadProfile(_userId),
          'errors.database_setup',
        );
      },
    );

    test('rejects foreign and malformed snapshots rather than manufacturing drafts', () async {
      backend.snapshot = {..._snapshot(), 'user_id': _otherId};
      await _expectFailure(
        repository.loadProfile(_userId),
        'provider.errors.access',
      );
      backend.snapshot = {'user_id': _userId};
      await _expectFailure(
        repository.loadProfile(_userId),
        'provider.errors.invalid_profile',
      );
      backend.snapshot = _snapshot(status: 'unknown');
      await _expectFailure(
        repository.loadProfile(_userId),
        'provider.errors.invalid_profile',
      );
    });

    test('uploads once with secure owned path/MIME then submits scoped consent RPC', () async {
      final submitted = await _success(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
      );
      final path = submitted.verification!.documentPath;
      expect(path, matches(RegExp('^$_userId/[0-9a-f]{32}\\.jpg\$')));
      expect(
        submitted.verification!.status,
        ProviderVerificationStatus.pending,
      );
      final upload = backend.uploads.single;
      expect(upload.uri.path, '/storage/v1/object/provider-verification/$path');
      expect(upload.upsert, 'false');
      expect(upload.authorization, 'Bearer test-provider-token');
      final multipart = latin1.decode(upload.bytes);
      expect(multipart.toLowerCase(), contains('content-type: image/jpeg'));
      expect(multipart, contains(latin1.decode(_jpeg)));
      expect(multipart, isNot(contains('name="metadata"')));
      final submit = backend.requests.last;
      expect(submit.uri.path, '/rest/v1/rpc/submit_provider_verification');
      expect(submit.json, {
        'p_provider_id': _userId,
        'p_document_path': path,
        'p_consent': true,
      });
      expect(backend.requests, hasLength(3));
      expect(auth.checkCalls, 1);
    });

    test('reconciliation adds no repeated auth/profile HTTP reads', () async {
      auth.checkOverride = () async {
        await backend.client.from('profiles').select('id,role');
        return right(auth.session);
      };
      backend.intercept = (request) {
        if (request.uri.path == '/rest/v1/profiles') {
          return _Reply.json([
            {'id': _userId, 'role': 'provider'},
          ]);
        }
        if (request.isRpc('submit_provider_verification')) {
          return _Reply.sqlError('provider.errors.skills');
        }
        return null;
      };
      await _expectFailure(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
        'provider.errors.skills',
      );
      expect(auth.checkCalls, 1);
      expect(
        backend.requests.where(
          (request) => request.uri.path == '/rest/v1/profiles',
        ),
        hasLength(1),
      );
      expect(backend.uploads, hasLength(1));
      expect(backend.deletions, hasLength(1));
    });

    test(
      'PNG evidence uses PNG suffix and MIME, not caller filenames',
      () async {
        backend.documentBytes = Uint8List.fromList(_png);
        final submitted = await _success(
          repository.submitVerification(
            userId: _userId,
            document: VerificationDocument.fromBytes(backend.documentBytes),
            consent: true,
          ),
        );
        expect(submitted.verification!.documentPath, endsWith('.png'));
        expect(submitted.verification!.mimeType, 'image/png');
        expect(
          latin1.decode(backend.uploads.single.bytes),
          contains('image/png'),
        );
      },
    );

    test(
      'pending/verified preflight prevents uploads; rejected can resubmit',
      () async {
        for (final status in ['pending', 'verified']) {
          backend.snapshot = _snapshot(status: status);
          await _expectFailure(
            repository.submitVerification(
              userId: _userId,
              document: _document(),
              consent: true,
            ),
            'provider.errors.locked',
          );
        }
        expect(backend.uploads, isEmpty);
        backend.snapshot = _snapshot(status: 'rejected');
        final profile = await _success(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
        );
        expect(profile.verification!.documentPath, isNot(_oldPath));
        expect(backend.deletions, isEmpty);
      },
    );

    test('consent and invalid profile fail before any upload', () async {
      await _expectFailure(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: false,
        ),
        'provider.errors.consent',
      );
      expect(backend.requests, isEmpty);
      backend.snapshot = {..._snapshot(), 'bio': ''};
      await _expectFailure(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
        'provider.errors.bio',
      );
      expect(backend.uploads, isEmpty);
    });

    test(
      'duplicate save/submit cannot start another write during an upload',
      () async {
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (request) {
          if (request.isUpload) {
            started.complete();
            return response.future;
          }
          return null;
        };
        final first = repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        );
        await started.future;
        await _expectFailure(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
          'provider.errors.locked',
        );
        await _expectFailure(
          repository.saveProfile(_profile(skillId: _skillId)),
          'provider.errors.locked',
        );
        response.complete(null);
        await _success(first);
        expect(backend.uploads, hasLength(1));
        expect(
          backend.requests.where(
            (request) => request.isRpc('submit_provider_verification'),
          ),
          hasLength(1),
        );
      },
    );

    test('upload failure reconciles then cleans only its new object', () async {
      backend.snapshot = _snapshot(status: 'rejected');
      backend.intercept = (request) => request.isUpload
          ? _Reply.json({
              'message': 'private upload error',
              'statusCode': '503',
            }, status: 503)
          : null;
      final failure = await _expectFailure(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
        'provider.errors.upload',
      );
      expect(failure.error, isNull);
      expect(backend.uploads, hasLength(1));
      final newPath = backend.uploads.single.objectPath;
      expect(newPath, isNot(_oldPath));
      expect(backend.deletions.single.json, {
        'prefixes': [newPath],
      });
      expect(
        backend.requests.where(
          (request) => request.isRpc('submit_provider_verification'),
        ),
        isEmpty,
      );
      expect(backend.requests[2].isRpc('get_provider_onboarding'), isTrue);
    });

    test(
      'upload conflict cannot delete a preexisting colliding object',
      () async {
        backend.intercept = (request) => request.isUpload
            ? _Reply.json({
                'message': 'Already exists',
                'statusCode': '409',
              }, status: 409)
            : null;
        await _expectFailure(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
          'provider.errors.upload',
        );
        expect(backend.deletions, isEmpty);
        expect(backend.uploads, hasLength(1));
      },
    );

    test('submit rejection keeps original safe failure and never deletes old evidence', () async {
      backend.snapshot = _snapshot(status: 'rejected');
      backend.intercept = (request) =>
          request.isRpc('submit_provider_verification')
          ? _Reply.sqlError('provider.errors.skills')
          : null;
      await _expectFailure(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
        'provider.errors.skills',
      );
      expect(backend.deletions.single.json, {
        'prefixes': [backend.uploads.single.objectPath],
      });
      expect(
        backend.deletions.single.json['prefixes'],
        isNot(contains(_oldPath)),
      );
      expect(
        backend.snapshot['verification'],
        _verificationJson(status: 'rejected'),
      );
    });

    test('lost submit response returns canonical committed snapshot without deletion', () async {
      backend.intercept = (request) {
        if (!request.isRpc('submit_provider_verification')) return null;
        backend.respond(request);
        return _Reply.sqlError('lost response', status: 503);
      };
      final profile = await _success(
        repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        ),
      );
      expect(
        profile.verification!.documentPath,
        backend.uploads.single.objectPath,
      );
      expect(profile.verification!.status, ProviderVerificationStatus.pending);
      expect(backend.deletions, isEmpty);
      expect(
        backend.requests.where(
          (request) => request.isRpc('submit_provider_verification'),
        ),
        hasLength(1),
      );
    });

    test(
      'reconciles a malformed response even if review already completed',
      () async {
        backend.intercept = (request) {
          if (!request.isRpc('submit_provider_verification')) return null;
          backend.respond(request);
          backend.snapshot['verification'] = _verificationJson(
            status: 'verified',
            path: request.json['p_document_path'] as String,
          );
          return _Reply.json({'not': 'a snapshot'});
        };
        final profile = await _success(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
        );
        expect(
          profile.verification!.status,
          ProviderVerificationStatus.verified,
        );
        expect(backend.deletions, isEmpty);
      },
    );

    test(
      'ambiguous read failure defers deletion and preserves original failure',
      () async {
        var submitAttempted = false;
        backend.intercept = (request) {
          if (request.isRpc('submit_provider_verification')) {
            submitAttempted = true;
            return _Reply.sqlError('provider.errors.document_unavailable');
          }
          if (submitAttempted && request.isRpc('get_provider_onboarding')) {
            return _Reply.sqlError('private read error', status: 503);
          }
          return null;
        };
        final failure = await _expectFailure(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
          'provider.errors.cleanup',
        );
        expect(
          (failure.error! as Failure).message,
          'provider.errors.document_unavailable',
        );
        expect((failure.error! as Failure).error, isNull);
        expect(backend.deletions, isEmpty);
      },
    );

    test(
      'cleanup failure is explicit and retains the sanitized original error',
      () async {
        backend.intercept = (request) {
          if (request.isRpc('submit_provider_verification')) {
            return _Reply.sqlError('provider.errors.skills');
          }
          if (request.method == 'DELETE') {
            return _Reply.json({
              'message': 'private cleanup error',
              'statusCode': '403',
            }, status: 403);
          }
          return null;
        };
        final failure = await _expectFailure(
          repository.submitVerification(
            userId: _userId,
            document: _document(),
            consent: true,
          ),
          'provider.errors.cleanup',
        );
        expect((failure.error! as Failure).message, 'provider.errors.skills');
        expect(backend.deletions, hasLength(1));
      },
    );

    test(
      'logout during a load cannot return previous-account data after re-login',
      () async {
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (_) {
          started.complete();
          return response.future;
        };
        final pending = repository.loadProfile(_userId);
        await started.future;
        auth.change(const AuthSession());
        auth.change(const AuthSession(user: _provider));
        response.complete(_Reply.json(backend.snapshot));
        await _expectFailure(pending, 'provider.errors.access');
        expect(auth.hasListeners, isFalse);
      },
    );

    test(
      'account switch during save never retargets writes or returns stale data',
      () async {
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (_) {
          started.complete();
          return response.future;
        };
        final pending = repository.saveProfile(_profile(skillId: _skillId));
        await started.future;
        auth.change(const AuthSession(user: _otherProvider));
        response.complete(_Reply.json(backend.snapshot));
        await _expectFailure(pending, 'provider.errors.access');
        expect(backend.requests.single.json['p_provider_id'], _userId);
        expect(
          backend.requests.single.authorization,
          'Bearer test-provider-token',
        );
      },
    );

    test(
      'switch during upload prevents submit or cleanup under the new account',
      () async {
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (request) {
          if (!request.isUpload) return null;
          started.complete();
          return response.future;
        };
        final pending = repository.submitVerification(
          userId: _userId,
          document: _document(),
          consent: true,
        );
        await started.future;
        auth.change(const AuthSession(user: _otherProvider));
        response.complete(null);
        await _expectFailure(pending, 'provider.errors.access');
        expect(backend.requests, hasLength(2));
        expect(backend.deletions, isEmpty);
      },
    );

    test(
      'live SDK identity must also match the mapped provider session',
      () async {
        await backend.setSession(userId: _otherId);
        await _expectFailure(
          repository.loadProfile(_userId),
          'provider.errors.access',
        );
        expect(backend.requests, isEmpty);
        expect(auth.checkCalls, 0);
      },
    );

    test(
      'raw SDK account switch is guarded before the mapped session catches up',
      () async {
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (request) {
          if (!request.isRpc('get_provider_onboarding')) return null;
          started.complete();
          return response.future;
        };
        final pending = repository.loadProfile(_userId);
        await started.future;
        await backend.setSession(userId: _otherId);
        expect(auth.session.user, _provider);
        response.complete(null);
        await _expectFailure(pending, 'provider.errors.access');
        expect(auth.checkCalls, 1);
      },
    );

    for (final type in [OtpType.email, OtpType.recovery]) {
      test(
        'raw ${type.name} auth transition invalidates the same-user operation',
        () async {
          final started = Completer<void>();
          final response = Completer<_Reply?>();
          backend.intercept = (request) {
            if (!request.isRpc('get_provider_onboarding')) return null;
            started.complete();
            return response.future;
          };
          final pending = repository.loadProfile(_userId);
          await started.future;
          await backend.client.auth.verifyOTP(
            email: _provider.email,
            token: '123456',
            type: type,
          );
          expect(auth.session, const AuthSession(user: _provider));
          response.complete(null);
          await _expectFailure(pending, 'provider.errors.access');
          expect(auth.checkCalls, 1);
        },
      );
    }

    test(
      'normal SDK token refresh does not invalidate a matching provider',
      () async {
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (request) {
          if (!request.isRpc('get_provider_onboarding')) return null;
          started.complete();
          return response.future;
        };
        final pending = repository.loadProfile(_userId);
        await started.future;
        await backend.client.auth.refreshSession();
        response.complete(null);
        expect(
          await _success(pending),
          ProviderProfile.fromJson(backend.snapshot),
        );
        expect(auth.checkCalls, 1);
      },
    );

    test('restored same-user session tolerates SDK replay without extra auth reads', () async {
      final before = backend.client.auth.currentSession;
      await backend.client.auth.recoverSession(
        jsonEncode(backend.sessionJson()),
      );
      expect(identical(backend.client.auth.currentSession, before), isFalse);
      expect(
        await _success(repository.loadProfile(_userId)),
        ProviderProfile.fromJson(backend.snapshot),
      );
      expect(auth.checkCalls, 1);
      expect(backend.requests, hasLength(1));
    });

    test(
      'replayed password recovery stays blocked before profile mapping',
      () async {
        await backend.client.auth.verifyOTP(
          email: _provider.email,
          token: '123456',
          type: OtpType.recovery,
        );
        backend.requests.clear();
        await _expectFailure(
          repository.loadProfile(_userId),
          'provider.errors.access',
        );
        expect(backend.requests, isEmpty);
      },
    );

    test(
      'downloads owned latest evidence with auth, no public URLs or cache',
      () async {
        backend.snapshot = _snapshot(status: 'pending');
        final bytes = await _success(
          repository.loadDocument(
            userId: _userId,
            verificationId: _verificationId,
          ),
        );
        expect(bytes, orderedEquals(_jpeg));
        expect(() => bytes[0] = 0, throwsUnsupportedError);
        final download = backend.requests.last;
        expect(download.method, 'GET');
        expect(
          download.uri.path,
          '/storage/v1/object/provider-verification/$_oldPath',
        );
        expect(download.uri.query, isEmpty);
        expect(download.authorization, 'Bearer test-provider-token');
        await _success(
          repository.loadDocument(
            userId: _userId,
            verificationId: _verificationId,
          ),
        );
        expect(
          backend.requests.where((request) => request.method == 'GET'),
          hasLength(2),
        );
      },
    );

    test('caller IDs and corrupt/foreign paths cannot reach Storage', () async {
      backend.snapshot = _snapshot(status: 'pending');
      for (final id in ['', 'foreign-id', _oldPath]) {
        await _expectFailure(
          repository.loadDocument(userId: _userId, verificationId: id),
          'provider.errors.document_unavailable',
        );
      }
      for (final path in [
        '$_otherId/00000000000000000000000000000000.jpg',
        '$_userId/../evidence.jpg',
        'https://example.test/evidence.jpg',
        '$_userId/ABCDEF.jpg',
      ]) {
        backend.snapshot['verification'] = {
          ..._verificationJson(),
          'document_path': path,
        };
        await _expectFailure(
          repository.loadDocument(
            userId: _userId,
            verificationId: _verificationId,
          ),
          'provider.errors.document_unavailable',
        );
      }
      expect(
        backend.requests.where((request) => request.method == 'GET'),
        isEmpty,
      );
    });

    test('metadata limits reject documents before a download', () async {
      for (final size in [0, VerificationDocument.maxBytes + 1]) {
        backend.snapshot = {
          ..._snapshot(),
          'verification': {..._verificationJson(), 'size_bytes': size},
        };
        await _expectFailure(
          repository.loadDocument(
            userId: _userId,
            verificationId: _verificationId,
          ),
          'provider.errors.document_size',
        );
      }
      backend.snapshot = {
        ..._snapshot(),
        'verification': {
          ..._verificationJson(),
          'mime_type': 'application/pdf',
        },
      };
      await _expectFailure(
        repository.loadDocument(
          userId: _userId,
          verificationId: _verificationId,
        ),
        'provider.errors.document_type',
      );
      expect(
        backend.requests.where((request) => request.method == 'GET'),
        isEmpty,
      );
    });

    test(
      'bounds streamed bytes and validates type and metadata after download',
      () async {
        backend.snapshot = _snapshot(status: 'pending');
        backend.documentBytes = Uint8List(VerificationDocument.maxBytes + 1)
          ..setAll(0, _jpeg);
        await _expectFailure(
          repository.loadDocument(
            userId: _userId,
            verificationId: _verificationId,
          ),
          'provider.errors.document_size',
        );
        backend.documentBytes = Uint8List.fromList('GIF89a'.codeUnits);
        await _expectFailure(
          repository.loadDocument(
            userId: _userId,
            verificationId: _verificationId,
          ),
          'provider.errors.document_type',
        );
        backend.documentBytes = Uint8List.fromList([..._jpeg, 0]);
        await _expectFailure(
          repository.loadDocument(
            userId: _userId,
            verificationId: _verificationId,
          ),
          'provider.errors.document_unavailable',
        );
        backend.documentBytes = Uint8List.fromList(_png);
        await _expectFailure(
          repository.loadDocument(
            userId: _userId,
            verificationId: _verificationId,
          ),
          'provider.errors.document_unavailable',
        );
      },
    );

    test('download errors do not expose storage details', () async {
      backend.snapshot = _snapshot(status: 'pending');
      backend.intercept = (request) => request.method == 'GET'
          ? _Reply.json({
              'message': 'private path',
              'statusCode': '404',
            }, status: 404)
          : null;
      final failure = await _expectFailure(
        repository.loadDocument(
          userId: _userId,
          verificationId: _verificationId,
        ),
        'provider.errors.document_unavailable',
      );
      expect(failure.error, isNull);
    });

    test(
      'a switch while downloading prevents returning the previous image',
      () async {
        backend.snapshot = _snapshot(status: 'pending');
        final started = Completer<void>();
        final response = Completer<_Reply?>();
        backend.intercept = (request) {
          if (request.method != 'GET') return null;
          started.complete();
          return response.future;
        };
        final pending = repository.loadDocument(
          userId: _userId,
          verificationId: _verificationId,
        );
        await started.future;
        auth.change(const AuthSession(user: _otherProvider));
        response.complete(null);
        await _expectFailure(pending, 'provider.errors.access');
      },
    );
  });
}

ProviderProfile _profile({
  String userId = _userId,
  String skillId = 'demo-plumbing',
}) => ProviderProfile(
  userId: userId,
  bio: 'Experienced home service provider.',
  skillIds: [skillId],
  serviceAreas: const ['Cairo'],
  availability: const [_hours],
);

VerificationDocument _document() =>
    VerificationDocument.fromBytes(Uint8List.fromList(_jpeg));

Map<String, dynamic> _snapshot({String? status}) => {
  'user_id': _userId,
  'bio': 'Experienced home service provider.',
  'skill_ids': [_skillId],
  'service_areas': ['Cairo'],
  'availability': [_hours.toJson()],
  'verification': status == null ? null : _verificationJson(status: status),
};

Map<String, dynamic> _verificationJson({
  String status = 'pending',
  String path = _oldPath,
  int? size,
}) => {
  'id': _verificationId,
  'document_path': path,
  'mime_type': path.endsWith('.png') ? 'image/png' : 'image/jpeg',
  'size_bytes': size ?? _jpeg.length,
  'status': status,
  'submitted_at': '2026-10-18T10:00:00+02:00',
  'reviewed_at': status == 'pending' ? null : '2026-10-18T11:00:00+02:00',
  'review_note': status == 'pending' ? null : 'Review note',
};

Future<T> _success<T>(FutureEither<T> task) async =>
    (await task).fold((failure) => fail(failure.message), (value) => value);

Future<Failure> _expectFailure<T>(FutureEither<T> task, String key) async {
  final failure = (await task).fold(
    (failure) => failure,
    (_) => fail('Expected $key'),
  );
  expect(failure.message, key);
  return failure;
}

class _SessionAuth extends DemoAuthRepository {
  _SessionAuth({required this.demo});

  final bool demo;
  AuthSession session = const AuthSession(user: _provider);
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

/// A loopback HTTP fake exercises the real Supabase RPC/Storage serialization.
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
  Map<String, dynamic> snapshot = _snapshot();
  Uint8List documentBytes = Uint8List.fromList(_jpeg);
  FutureOr<_Reply?> Function(_Request)? intercept;
  int cancelledResponses = 0;

  Iterable<_Request> get uploads =>
      requests.where((request) => request.isUpload);
  Iterable<_Request> get deletions =>
      requests.where((request) => request.method == 'DELETE');

  static Future<_Backend> start() async {
    final backend = _Backend(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    await backend.setSession();
    return backend;
  }

  Map<String, Object?> sessionJson({String userId = _userId}) => {
    'access_token': 'test-provider-token',
    'refresh_token': 'test-refresh-token',
    'token_type': 'bearer',
    'user': {
      'id': userId,
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
      'aud': 'authenticated',
      'created_at': '2026-10-18T00:00:00Z',
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
    );
    requests.add(request);
    final reply = await intercept?.call(request) ?? respond(request);
    incoming.response.statusCode = reply.status;
    incoming.response.headers.contentType = ContentType.parse(
      reply.contentType,
    );
    try {
      incoming.response.add(reply.bytes);
      await incoming.response.close();
    } on HttpException {
      // The bounded stream reader can cancel before the fixture finishes sending.
      cancelledResponses++;
    }
  }

  _Reply respond(_Request request) {
    if (request.uri.path == '/auth/v1/verify' ||
        request.uri.path == '/auth/v1/token') {
      return _Reply.json(sessionJson());
    }
    if (request.isRpc('get_provider_onboarding')) return _Reply.json(snapshot);
    if (request.isRpc('save_provider_onboarding')) {
      final verification = snapshot['verification'] as Map<String, dynamic>?;
      if (verification?['status'] == 'pending') {
        return _Reply.sqlError('provider.errors.locked');
      }
      final values = request.json;
      snapshot = {
        ...snapshot,
        'bio': values['p_bio'],
        'skill_ids': values['p_skill_ids'],
        'service_areas': values['p_service_areas'],
        'availability': values['p_availability'],
      };
      return _Reply.json(snapshot);
    }
    if (request.isUpload) {
      return _Reply.json({
        'Key': 'provider-verification/${request.objectPath}',
      });
    }
    if (request.isRpc('submit_provider_verification')) {
      snapshot = {
        ...snapshot,
        'verification': _verificationJson(
          path: request.json['p_document_path'] as String,
          size: documentBytes.length,
        ),
      };
      return _Reply.json(snapshot);
    }
    if (request.method == 'DELETE') {
      return _Reply.json([
        for (final path in request.json['prefixes'] as List<Object?>)
          {'name': path},
      ]);
    }
    if (request.method == 'GET') {
      return _Reply(documentBytes, contentType: 'image/jpeg');
    }
    return _Reply.sqlError('Unexpected fake request', status: 500);
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
  );

  final String method;
  final Uri uri;
  final Uint8List bytes;
  final String? authorization;
  final String? upsert;
  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  bool isRpc(String name) => uri.path == '/rest/v1/rpc/$name';
  bool get isUpload =>
      method == 'POST' && uri.path.startsWith('/storage/v1/object/');
  String get objectPath =>
      uri.path.substring('/storage/v1/object/provider-verification/'.length);
}

class _Reply {
  const _Reply(
    this.bytes, {
    this.status = 200,
    this.contentType = 'application/json',
  });

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

  final List<int> bytes;
  final int status;
  final String contentType;
}
