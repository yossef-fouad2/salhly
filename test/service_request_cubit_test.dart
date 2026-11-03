import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/service_category.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/service_request_repository.dart';
import 'package:salahly/src/services/request_photo_picker.dart';
import 'package:salahly/src/ui/requests/service_request_detail_cubit.dart';
import 'package:salahly/src/ui/requests/service_request_form_cubit.dart';
import 'package:salahly/src/ui/requests/service_request_history_cubit.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';

final _now = DateTime.utc(2026, 11, 1, 12);
const _owner = 'customer-a';

RequestPhotoInput _photo() =>
    RequestPhotoInput.fromBytes(Uint8List.fromList([0xff, 0xd8, 0xff, 1]));

ServiceRequest _saved(ServiceRequestDraft draft, {bool cancelled = false}) =>
    ServiceRequest(
      id: draft.id,
      customerId: _owner,
      categoryId: draft.categoryId!,
      categoryNameEn: 'Plumbing',
      categoryNameAr: 'Plumbing',
      categoryIconKey: 'plumbing',
      title: draft.title.trim(),
      description: draft.description.trim(),
      city: draft.city.trim(),
      address: draft.address.trim(),
      preferredAt: draft.preferredAt,
      status: cancelled
          ? ServiceRequestStatus.cancelled
          : ServiceRequestStatus.open,
      createdAt: _now,
      consentedAt: _now,
      cancelledAt: cancelled ? _now : null,
      photos: [
        for (final (index, photo) in draft.photos.indexed)
          ServiceRequestPhoto(
            id: photo.id,
            storagePath: '$_owner/${draft.id}/${photo.id}.${photo.extension}',
            mimeType: photo.mimeType,
            sizeBytes: photo.sizeBytes,
            position: index + 1,
          ),
      ],
    );

ServiceRequestDraft _draft({List<RequestPhotoInput> photos = const []}) =>
    ServiceRequestDraft.create(categoryId: 'demo-plumbing').copyWith(
      title: 'Kitchen tap leaks',
      description: 'The kitchen tap keeps dripping after it is turned off.',
      city: 'Cairo',
      address: '10 Demo Street, apartment 2',
      photos: photos,
      consent: true,
    );

class _Repository extends ServiceRequestRepository {
  _Repository() : super(authRepository: DemoAuthRepository());
  int submissions = 0;
  int loads = 0;
  int cancellations = 0;
  int downloads = 0;
  String? submittedUser;
  ServiceRequestDraft? submittedDraft;
  ServiceRequest? cursor;
  Failure? failure;
  Completer<Either<Failure, ServiceRequest>>? pendingSubmit;
  Completer<Either<Failure, ServiceRequestPage>>? pendingList;
  Completer<Either<Failure, ServiceRequest>>? pendingCancel;
  Completer<Either<Failure, Uint8List>>? pendingPhoto;
  late ServiceRequest record = _saved(_draft());
  ServiceRequestPage page = ServiceRequestPage(items: [], hasMore: false);

  @override
  FutureEither<ServiceRequest> submitRequest(
    ServiceRequestDraft draft, {
    required String userId,
  }) async {
    submissions++;
    submittedUser = userId;
    submittedDraft = draft;
    return pendingSubmit?.future ??
        (failure == null ? right(_saved(draft)) : left(failure!));
  }

  @override
  FutureEither<ServiceRequestPage> loadRequests({
    required String userId,
    ServiceRequest? before,
    int limit = 20,
  }) async {
    loads++;
    cursor = before;
    return pendingList?.future ??
        (failure == null ? right(page) : left(failure!));
  }

  @override
  FutureEither<ServiceRequest> loadRequest(
    String requestId, {
    required String userId,
  }) async => failure == null ? right(record) : left(failure!);

  @override
  FutureEither<ServiceRequest> cancelRequest(
    String requestId, {
    required String userId,
  }) async {
    cancellations++;
    return pendingCancel?.future ??
        (failure == null
            ? right(
                ServiceRequest.fromJson({
                  ...record.toJson(),
                  'status': 'cancelled',
                  'cancelled_at': _now.toIso8601String(),
                }),
              )
            : left(failure!));
  }

  @override
  FutureEither<Uint8List> loadPhoto({
    required String userId,
    required String requestId,
    required String photoId,
  }) async {
    downloads++;
    return pendingPhoto?.future ??
        (failure == null ? right(_photo().bytes) : left(failure!));
  }
}

class _Picker extends RequestPhotoPicker {
  int calls = 0;
  bool cancel = false;
  Completer<Either<Failure, RequestPhotoInput?>>? pending;
  @override
  FutureEither<RequestPhotoInput?> pick() async {
    calls++;
    return pending?.future ?? right(cancel ? null : _photo());
  }
}

class _Catalog extends CatalogRepository {
  bool fail = false;
  bool omitPlumbing = false;
  @override
  FutureEither<List<ServiceCategory>> loadCategories() async {
    if (fail) return left(const NetworkFailure('errors.network'));
    final result = await super.loadCategories();
    return result.map(
      (categories) => categories
          .where((category) => !omitPlumbing || category.id != 'demo-plumbing')
          .toList(),
    );
  }
}

void _complete(ServiceRequestFormCubit cubit) {
  cubit.selectCategory('demo-plumbing');
  cubit.updateTitle('Kitchen tap leaks');
  cubit.updateDescription(
    'The kitchen tap keeps dripping after it is turned off.',
  );
  cubit.updateCity('Cairo');
  cubit.updateAddress('10 Demo Street, apartment 2');
  cubit.setConsent(true);
}

void main() {
  group('local request form', () {
    late _Repository repository;
    late _Picker picker;
    late _Catalog catalog;
    late ServiceRequestFormCubit cubit;
    setUp(() async {
      repository = _Repository();
      picker = _Picker();
      catalog = _Catalog();
      cubit = ServiceRequestFormCubit(
        userId: _owner,
        repository: repository,
        catalog: catalog,
        photoPicker: picker,
        now: () => _now,
      );
      await cubit.load();
    });
    tearDown(() async {
      if (!cubit.isClosed) await cubit.close();
      if (repository.pendingSubmit?.isCompleted == false) {
        repository.pendingSubmit!.complete(
          left(const NetworkFailure('errors.network')),
        );
      }
      if (picker.pending?.isCompleted == false) {
        picker.pending!.complete(right(null));
      }
    });

    test(
      'typing and step navigation retain the local draft without writes',
      () {
        final id = cubit.state.draft.id;
        _complete(cubit);
        cubit.nextStep();
        cubit.nextStep();
        cubit.previousStep();
        cubit.previousStep();
        expect(cubit.state.step, 0);
        expect(cubit.state.draft.id, id);
        expect(cubit.state.draft.title, 'Kitchen tap leaks');
        expect(cubit.state.draft.address, '10 Demo Street, apartment 2');
        expect(cubit.state.hasUnsavedChanges, isTrue);
        expect(repository.submissions, 0);
      },
    );

    test(
      'validation returns to the field section and consent is mandatory',
      () async {
        cubit.nextStep();
        expect(cubit.state.errorMessage, 'requests.errors.category');
        _complete(cubit);
        cubit.updateAddress('');
        cubit.nextStep();
        cubit.nextStep();
        expect(cubit.state.step, 1);
        expect(cubit.state.errorMessage, 'requests.errors.address');
        cubit.updateAddress('10 Demo Street, apartment 2');
        cubit.nextStep();
        await cubit.submit();
        expect(cubit.state.errorMessage, 'requests.errors.consent');
        expect(repository.submissions, 0);
        cubit.setConsent(true);
        await cubit.submit();
        expect(repository.submissions, 1);
        expect(repository.submittedUser, _owner);
        expect(cubit.state.submitted, isNotNull);
        expect(cubit.state.hasUnsavedChanges, isFalse);
      },
    );

    test(
      'photo picking is bounded, local, cancellable, and resets consent',
      () async {
        picker.cancel = true;
        await cubit.pickPhoto();
        expect(cubit.state.isDirty, isFalse);
        picker.cancel = false;
        _complete(cubit);
        for (var i = 0; i < 3; i++) {
          await cubit.pickPhoto();
        }
        expect(cubit.state.draft.photos.length, 3);
        expect(cubit.state.draft.consent, isFalse);
        await cubit.pickPhoto();
        expect(picker.calls, 4);
        expect(cubit.state.errorMessage, 'requests.errors.photos');
        final removed = cubit.state.draft.photos.first.id;
        cubit.removePhoto(removed);
        expect(cubit.state.draft.photos.length, 2);
        expect(repository.submissions, 0);
      },
    );

    test(
      'duplicate picker requests and edits are blocked while picking',
      () async {
        picker.pending = Completer();
        final first = cubit.pickPhoto();
        await cubit.pickPhoto();
        cubit.updateTitle('This must not replace the draft.');
        expect(picker.calls, 1);
        expect(cubit.state.draft.title, isEmpty);
        picker.pending!.complete(right(_photo()));
        await first;
        expect(cubit.state.draft.photos.length, 1);
      },
    );

    test(
      'submission locks the exact snapshot and releases photo bytes on success',
      () async {
        _complete(cubit);
        await cubit.pickPhoto();
        cubit.setConsent(true);
        final original = cubit.state.draft;
        repository.pendingSubmit = Completer();
        final first = cubit.submit();
        await cubit.submit();
        cubit.updateTitle('Not the submitted draft');
        cubit.removePhoto(original.photos.single.id);
        expect(repository.submissions, 1);
        expect(repository.submittedDraft, same(original));
        expect(cubit.state.draft, same(original));
        repository.pendingSubmit!.complete(right(_saved(original)));
        await first;
        expect(cubit.state.draft.photos, isEmpty);
        expect(cubit.state.submitted!.photos.length, 1);
        expect(cubit.state.canEdit, isFalse);
      },
    );

    test(
      'ordinary failure retains fields and permits correcting the draft',
      () async {
        _complete(cubit);
        repository.failure = const ServerFailure(
          'requests.errors.submit_failed',
        );
        await cubit.submit();
        expect(cubit.state.canEdit, isTrue);
        expect(cubit.state.draft.title, 'Kitchen tap leaks');
        expect(cubit.state.draft.consent, isTrue);
        cubit.updateTitle('Updated kitchen problem');
        expect(cubit.state.draft.consent, isFalse);
      },
    );

    test(
      'ambiguous submission freezes details until the same request is resolved',
      () async {
        _complete(cubit);
        final original = cubit.state.draft;
        repository.failure = const ServerFailure(
          'requests.errors.submit_uncertain',
        );
        await cubit.submit();
        cubit.updateTitle('Must not change');
        cubit.setConsent(false);
        cubit.previousStep();
        expect(cubit.state.step, 2);
        expect(cubit.state.draft, same(original));
        expect(cubit.state.canEdit, isFalse);
        repository.failure = null;
        await cubit.submit();
        expect(repository.submittedDraft, same(original));
        expect(cubit.state.submitted!.id, original.id);
      },
    );

    test(
      'a later network failure cannot unfreeze an uncertain submission',
      () async {
        _complete(cubit);
        repository.failure = const ServerFailure(
          'requests.errors.submit_uncertain',
        );
        await cubit.submit();
        repository.failure = const NetworkFailure('errors.network');
        await cubit.submit();
        expect(cubit.state.outcomeUncertain, isTrue);
        expect(cubit.state.canEdit, isFalse);
        expect(cubit.state.step, 2);
      },
    );

    test('catalog failures preserve fields and successful refresh removes inactive selection', () async {
      _complete(cubit);
      catalog.fail = true;
      final categories = cubit.state.categories;
      await cubit.load();
      expect(cubit.state.categories, same(categories));
      expect(cubit.state.draft.title, 'Kitchen tap leaks');
      catalog.fail = false;
      catalog.omitPlumbing = true;
      await cubit.load();
      expect(cubit.state.draft.categoryId, isNull);
      expect(cubit.state.draft.consent, isFalse);
    });

    test('preferred time validates and can return to flexible', () async {
      _complete(cubit);
      cubit.updatePreferredAt(_now.subtract(const Duration(hours: 1)));
      await cubit.submit();
      expect(cubit.state.errorMessage, 'requests.errors.preferred_time');
      expect(cubit.state.step, 1);
      cubit.updatePreferredAt(null);
      cubit.setConsent(true);
      await cubit.submit();
      expect(repository.submittedDraft!.preferredAt, isNull);
    });

    test(
      'late picker and submit completions do not emit after disposal',
      () async {
        picker.pending = Completer();
        final picking = cubit.pickPhoto();
        await cubit.close();
        picker.pending!.complete(right(_photo()));
        await picking;
        expect(cubit.state.draft.photos, isEmpty);
      },
    );
  });

  test('history pages append by cursor, retain content on failure, and serialize loads', () async {
    final repository = _Repository();
    final first = _saved(_draft());
    final second = _saved(_draft());
    repository.page = ServiceRequestPage(items: [first], hasMore: true);
    final cubit = ServiceRequestHistoryCubit(
      userId: _owner,
      repository: repository,
    );
    addTearDown(cubit.close);
    await cubit.refresh();
    repository.pendingList = Completer();
    final next = cubit.loadMore();
    await cubit.refresh();
    await cubit.loadMore();
    expect(repository.loads, 2);
    expect(repository.cursor, first);
    expect(cubit.state.items, [first]);
    repository.pendingList!.complete(
      right(ServiceRequestPage(items: [first, second], hasMore: false)),
    );
    await next;
    expect(cubit.state.items, [first, second]);
    repository.pendingList = null;
    repository.failure = const NetworkFailure('errors.network');
    await cubit.refresh();
    expect(cubit.state.items, [first, second]);
    expect(cubit.state.errorMessage, 'errors.network');
  });

  test('history ignores a late refresh after close', () async {
    final repository = _Repository()..pendingList = Completer();
    final cubit = ServiceRequestHistoryCubit(
      userId: _owner,
      repository: repository,
    );
    final loading = cubit.refresh();
    await cubit.close();
    repository.pendingList!.complete(
      right(ServiceRequestPage(items: [_saved(_draft())], hasMore: false)),
    );
    await loading;
    expect(cubit.state.items, isEmpty);
  });

  test('detail retains the request on cancel failure and blocks duplicate cancellation', () async {
    final repository = _Repository();
    final cubit = ServiceRequestDetailCubit(
      userId: _owner,
      requestId: repository.record.id,
      repository: repository,
    );
    addTearDown(cubit.close);
    await cubit.load();
    repository.pendingCancel = Completer();
    final cancelling = cubit.cancel();
    await cubit.cancel();
    await cubit.load();
    expect(repository.cancellations, 1);
    expect(cubit.state.request, repository.record);
    repository.pendingCancel!.complete(
      left(const ServerFailure('requests.errors.cancel_failed')),
    );
    await cancelling;
    expect(cubit.state.request!.status, ServiceRequestStatus.open);
    repository.pendingCancel = null;
    await cubit.cancel();
    expect(cubit.state.request!.status, ServiceRequestStatus.cancelled);
  });

  test(
    'photos load on demand only, one at a time, and late bytes are discarded',
    () async {
      final photo = _photo();
      final repository = _Repository()
        ..record = _saved(_draft(photos: [photo]));
      final cubit = ServiceRequestDetailCubit(
        userId: _owner,
        requestId: repository.record.id,
        repository: repository,
      );
      await cubit.load();
      expect(repository.downloads, 0);
      expect(await cubit.readPhoto('not-attached'), isNull);
      repository.pendingPhoto = Completer();
      final loading = cubit.readPhoto(photo.id);
      expect(await cubit.readPhoto(photo.id), isNull);
      expect(repository.downloads, 1);
      await cubit.close();
      repository.pendingPhoto!.complete(right(photo.bytes));
      expect(await loading, isNull);
    },
  );
}
