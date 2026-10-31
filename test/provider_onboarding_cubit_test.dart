import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/service_category.dart';
import 'package:salahly/src/data/models/verification_document.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/provider_repository.dart';
import 'package:salahly/src/services/verification_document_picker.dart';
import 'package:salahly/src/ui/provider/provider_onboarding_cubit.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';

final _document = VerificationDocument.fromBytes(
  Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0, 1, 2, 3]),
);

ProviderProfile _completeProfile() => ProviderProfile(
  userId: 'provider-a',
  bio: 'I repair household plumbing and maintain water pipes.',
  skillIds: const ['demo-plumbing'],
  serviceAreas: const ['Central district'],
  availability: const [
    ProviderAvailability(weekday: 1, startMinute: 540, endMinute: 1020),
  ],
);

ProviderVerification _pending() => ProviderVerification(
  id: 'verification-a',
  documentPath: 'provider-a/evidence.jpg',
  mimeType: _document.mimeType,
  sizeBytes: _document.sizeBytes,
  status: ProviderVerificationStatus.pending,
  submittedAt: DateTime.utc(2026, 10, 18),
);

class _Repository extends ProviderRepository {
  _Repository() : super(authRepository: DemoAuthRepository());

  ProviderProfile profile = _completeProfile();
  int loads = 0;
  int saves = 0;
  int submissions = 0;
  Completer<Either<Failure, ProviderProfile>>? delayedLoad;
  Completer<Either<Failure, ProviderProfile>>? delayedSave;
  Completer<Either<Failure, ProviderProfile>>? delayedSubmit;
  Failure? saveFailure;
  Failure? loadFailure;
  Failure? submitFailure;

  @override
  FutureEither<ProviderProfile> loadProfile(String userId) async {
    loads++;
    if (delayedLoad != null) return delayedLoad!.future;
    if (loadFailure != null) return left(loadFailure!);
    return right(profile);
  }

  @override
  FutureEither<ProviderProfile> saveProfile(ProviderProfile value) async {
    saves++;
    if (delayedSave != null) return delayedSave!.future;
    if (saveFailure != null) return left(saveFailure!);
    profile = value;
    return right(profile);
  }

  @override
  FutureEither<ProviderProfile> submitVerification({
    required String userId,
    required VerificationDocument document,
    required bool consent,
  }) async {
    submissions++;
    if (delayedSubmit != null) return delayedSubmit!.future;
    if (submitFailure != null) return left(submitFailure!);
    profile = profile.copyWith(verification: _pending());
    return right(profile);
  }

  @override
  FutureEither<Uint8List> loadDocument({
    required String userId,
    required String verificationId,
  }) async => right(_document.bytes);
}

class _Picker extends VerificationDocumentPicker {
  VerificationDocument? document = _document;
  Failure? failure;
  Completer<Either<Failure, VerificationDocument?>>? delayed;

  @override
  FutureEither<VerificationDocument?> pick() async {
    if (delayed != null) return delayed!.future;
    return failure == null ? right(document) : left(failure!);
  }
}

class _Catalog extends CatalogRepository {
  bool fail = false;

  @override
  FutureEither<List<ServiceCategory>> loadCategories() => fail
      ? Future.value(left(const ServerFailure('errors.network')))
      : super.loadCategories();
}

void main() {
  late _Repository repository;
  late _Picker picker;
  late _Catalog catalog;
  late ProviderOnboardingCubit cubit;

  setUp(() async {
    repository = _Repository();
    picker = _Picker();
    catalog = _Catalog();
    cubit = ProviderOnboardingCubit(
      userId: 'provider-a',
      repository: repository,
      catalog: catalog,
      documentPicker: picker,
    );
    await cubit.load();
  });
  tearDown(() async {
    if (!cubit.isClosed) await cubit.close();
  });

  test('typing and step navigation are local and preserve the draft', () {
    final before = cubit.state.profile!;
    cubit.updateBio('Updated professional introduction with more experience.');
    cubit.toggleSkill('demo-electrical');
    cubit.updateAreas('Central district\n  North district  \n');
    cubit.setStep(1);
    cubit.updateAvailability(
      3,
      const ProviderAvailability(weekday: 3, startMinute: 600, endMinute: 900),
    );
    cubit.setStep(2);
    cubit.setStep(0);

    expect(cubit.state.profile!.bio, startsWith('Updated'));
    expect(cubit.state.profile!.serviceAreas, [
      'Central district',
      'North district',
    ]);
    expect(cubit.state.profile!.availability.map((hours) => hours.weekday), [
      1,
      3,
    ]);
    expect(cubit.state.profile!.skillIds, ['demo-plumbing', 'demo-electrical']);
    expect(before.skillIds, ['demo-plumbing']);
    expect(cubit.state.isDirty, isTrue);
    expect(repository.loads, 1);
    expect(repository.saves, 0);
    expect(repository.submissions, 0);
  });

  test('old unavailable skills can be removed but never newly added', () async {
    repository.profile = repository.profile.copyWith(skillIds: ['retired']);
    await cubit.load();
    cubit.toggleSkill('retired');
    expect(cubit.state.profile!.skillIds, isEmpty);
    cubit.toggleSkill('retired');
    expect(cubit.state.profile!.skillIds, isEmpty);
  });

  test(
    'duplicate saves and edits are blocked until a save completes',
    () async {
      cubit.updateBio('The updated introduction that will actually be saved.');
      final draft = cubit.state.profile!;
      repository.delayedSave = Completer();
      final first = cubit.save();
      await cubit.save();
      cubit.updateBio('Must not replace an in-flight save.');
      cubit.setStep(1);
      expect(cubit.state.profile, draft);
      expect(cubit.state.step, 0);
      expect(repository.saves, 1);
      repository.delayedSave!.complete(right(draft));
      await first;
      expect(cubit.state.isDirty, isFalse);
      expect(cubit.state.isBusy, isFalse);
      expect(cubit.state.notice, 'provider.saved');
    },
  );

  test('save failure retains edits, selected document, and consent', () async {
    cubit.updateBio('A changed introduction that should remain after failure.');
    await cubit.pickDocument();
    cubit.setConsent(true);
    repository.saveFailure = const ServerFailure('errors.network');
    final draft = cubit.state.profile;
    await cubit.save();
    expect(cubit.state.profile, draft);
    expect(cubit.state.isDirty, isTrue);
    expect(cubit.state.document, same(_document));
    expect(cubit.state.consent, isTrue);
    expect(cubit.state.errorMessage, 'errors.network');
    expect(cubit.state.canEdit, isTrue);
  });

  test(
    'submission validates before doing any I/O and reveals invalid section',
    () async {
      cubit.updateBio('short');
      cubit.setStep(2);
      await cubit.submit();
      expect(cubit.state.errorMessage, 'provider.errors.bio');
      expect(cubit.state.step, 0);
      cubit.updateBio(_completeProfile().bio);
      cubit.updateAreas('');
      cubit.setStep(2);
      await cubit.submit();
      expect(cubit.state.errorMessage, 'provider.errors.areas');
      expect(cubit.state.step, 1);
      expect(repository.saves, 0);
      expect(repository.submissions, 0);
    },
  );

  test(
    'document and explicit consent are required, not inferred from a selection',
    () async {
      await cubit.submit();
      expect(cubit.state.errorMessage, 'provider.errors.document_required');
      await cubit.pickDocument();
      await cubit.submit();
      expect(cubit.state.errorMessage, 'provider.errors.consent');
      expect(repository.saves, 0);
      expect(repository.submissions, 0);
    },
  );

  test('submission saves once, prevents double taps, and releases staged bytes on success', () async {
    await cubit.pickDocument();
    cubit.setConsent(true);
    cubit.setStep(2);
    repository.delayedSubmit = Completer();
    final first = cubit.submit();
    await Future<void>.delayed(Duration.zero);
    await cubit.submit();
    await cubit.load();
    expect(repository.saves, 1);
    expect(repository.submissions, 1);
    expect(repository.loads, 1);
    expect(cubit.state.operation, ProviderOperation.submitting);
    final submitted = repository.profile.copyWith(verification: _pending());
    repository.delayedSubmit!.complete(right(submitted));
    await first;
    expect(
      cubit.state.profile!.verification!.status,
      ProviderVerificationStatus.pending,
    );
    expect(cubit.state.document, isNull);
    expect(cubit.state.consent, isFalse);
    expect(cubit.state.hasUnsavedChanges, isFalse);
    expect(cubit.state.canEdit, isFalse);
    expect(cubit.state.profile!.canSubmit, isFalse);
  });

  test('upload failure keeps the selection retryable without pretending submission succeeded', () async {
    await cubit.pickDocument();
    cubit.setConsent(true);
    repository.submitFailure = const ServerFailure('provider.errors.upload');
    await cubit.submit();
    expect(cubit.state.errorMessage, 'provider.errors.upload');
    expect(cubit.state.profile!.verification, isNull);
    expect(cubit.state.isDirty, isFalse);
    expect(cubit.state.document, same(_document));
    expect(cubit.state.consent, isTrue);
    expect(cubit.state.hasUnsavedChanges, isTrue);
  });

  test('status refresh preserves local edits and reconciles an already-submitted document', () async {
    cubit.updateBio(
      'Keep this local introduction rather than the server version.',
    );
    await cubit.pickDocument();
    final localBio = cubit.state.profile!.bio;
    repository.profile = repository.profile.copyWith(verification: _pending());
    await cubit.load();
    expect(cubit.state.profile!.bio, localBio);
    expect(
      cubit.state.profile!.verification!.status,
      ProviderVerificationStatus.pending,
    );
    expect(cubit.state.isDirty, isTrue);
    expect(cubit.state.document, isNull);
    expect(cubit.state.canEdit, isFalse);
  });

  test('failed refresh keeps existing content and the current step', () async {
    cubit.setStep(1);
    final profile = cubit.state.profile;
    repository.loadFailure = const ServerFailure('errors.network');
    await cubit.load();
    expect(cubit.state.profile, same(profile));
    expect(cubit.state.categories, hasLength(6));
    expect(cubit.state.step, 1);
    expect(cubit.state.errorMessage, 'errors.network');
  });

  test(
    'picker cancellation keeps prior selection; replacement resets consent',
    () async {
      await cubit.pickDocument();
      cubit.setConsent(true);
      picker.document = null;
      await cubit.pickDocument();
      expect(cubit.state.document, same(_document));
      expect(cubit.state.consent, isTrue);
      picker.document = _document;
      await cubit.pickDocument();
      expect(cubit.state.consent, isFalse);
      cubit.removeDocument();
      expect(cubit.state.document, isNull);
      expect(cubit.state.hasUnsavedChanges, isFalse);
    },
  );

  test(
    'closing during save prevents a later upload or state emission',
    () async {
      await cubit.pickDocument();
      cubit.setConsent(true);
      repository.delayedSave = Completer();
      final operation = cubit.submit();
      await cubit.close();
      repository.delayedSave!.complete(right(repository.profile));
      await operation;
      expect(repository.submissions, 0);
    },
  );

  test(
    'catalog failure cannot hide authoritative pending review status',
    () async {
      await cubit.pickDocument();
      cubit.setConsent(true);
      cubit.updateBio(
        'Keep this unsaved local introduction across review checks.',
      );
      final bio = cubit.state.profile!.bio;
      final categories = cubit.state.categories;
      repository.profile = repository.profile.copyWith(
        verification: _pending(),
      );
      catalog.fail = true;
      await cubit.load();
      expect(
        cubit.state.profile!.verification!.status,
        ProviderVerificationStatus.pending,
      );
      expect(cubit.state.profile!.bio, bio);
      expect(cubit.state.categories, same(categories));
      expect(cubit.state.document, isNull);
      expect(cubit.state.consent, isFalse);
      expect(cubit.state.canEdit, isFalse);
      expect(cubit.state.errorMessage, 'errors.network');
    },
  );

  test('closing during picker safely ignores late results', () async {
    picker.delayed = Completer();
    final operation = cubit.pickDocument();
    await cubit.close();
    picker.delayed!.complete(right(_document));
    await operation;
    expect(cubit.state.document, isNull);
  });
}
