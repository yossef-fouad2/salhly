import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/app.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/service_request_repository.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/services/request_photo_picker.dart';
import 'package:salahly/src/shared/motion/staggered_entrance.dart';
import 'package:salahly/src/shared/widgets/app_button.dart';
import 'package:salahly/src/shared/wrappers/state_wrapper.dart';
import 'package:salahly/src/ui/requests/request_photo_image.dart';
import 'package:salahly/src/ui/requests/service_request_detail_page.dart';
import 'package:salahly/src/ui/requests/service_request_form_cubit.dart';
import 'package:salahly/src/ui/requests/service_request_form_page.dart';
import 'package:salahly/src/ui/requests/service_request_history_page.dart';
import 'package:salahly/src/ui/requests/service_request_location_step.dart';
import 'package:salahly/src/ui/requests/service_request_problem_step.dart';
import 'package:salahly/src/ui/requests/service_request_review_step.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Translations extends AssetLoader {
  const _Translations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      jsonDecode(File('$path/${locale.languageCode}.json').readAsStringSync())
          as Map<String, dynamic>;
}

late Uint8List _png;

class _Picker extends RequestPhotoPicker {
  @override
  FutureEither<RequestPhotoInput?> pick() async =>
      right(RequestPhotoInput.fromBytes(_png));
}

class _Repository extends ServiceRequestRepository {
  _Repository(DemoAuthRepository auth) : super(authRepository: auth);
  int submissions = 0;
  int downloads = 0;
  int historyLoads = 0;
  @override
  FutureEither<ServiceRequest> submitRequest(
    ServiceRequestDraft draft, {
    required String userId,
  }) {
    submissions++;
    return super.submitRequest(draft, userId: userId);
  }

  @override
  FutureEither<Uint8List> loadPhoto({
    required String userId,
    required String requestId,
    required String photoId,
  }) {
    downloads++;
    return super.loadPhoto(
      userId: userId,
      requestId: requestId,
      photoId: photoId,
    );
  }

  @override
  FutureEither<ServiceRequestPage> loadRequests({
    required String userId,
    ServiceRequest? before,
    int limit = 20,
  }) {
    historyLoads++;
    return super.loadRequests(userId: userId, before: before, limit: limit);
  }
}

Future<DemoAuthRepository> _pumpApp(
  WidgetTester tester, {
  DemoAuthRepository? auth,
  _Repository? repository,
  String initialLocation = AppRoutes.createServiceRequest,
  UserRole role = UserRole.customer,
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
  bool reducedMotion = false,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reducedMotion);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final authRepository = auth ?? DemoAuthRepository();
  await authRepository.login(
    email: role == UserRole.customer
        ? DemoAuthRepository.customerEmail
        : DemoAuthRepository.providerEmail,
    password: DemoAuthRepository.demoPassword,
  );
  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ar')],
      path: 'assets/translations',
      startLocale: locale,
      fallbackLocale: const Locale('en'),
      saveLocale: false,
      assetLoader: const _Translations(),
      child: StateWrapper(
        authRepository: authRepository,
        serviceRequestRepository: repository,
        requestPhotoPicker: _Picker(),
        child: App(initialLocation: initialLocation),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return authRepository;
}

Finder _key(String key) => find.byKey(ValueKey(key));
Finder _field(String key) =>
    find.descendant(of: _key(key), matching: find.byType(TextFormField));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  await tester.ensureVisible(_field(key));
  await tester.enterText(_field(key), value);
  await tester.pump();
}

Future<void> _problem(WidgetTester tester, {bool photo = false}) async {
  await _tap(tester, _key('request-category-demo-plumbing'));
  await _enter(tester, 'request-title', 'Kitchen tap leaks');
  await _enter(
    tester,
    'request-description',
    'The kitchen tap keeps dripping after the handle is closed.',
  );
  if (photo) await _tap(tester, _key('request-add-photo'));
}

Future<void> _location(WidgetTester tester) async {
  await _enter(tester, 'request-city', 'Cairo');
  await _enter(tester, 'request-address', '10 Demo Street, apartment 2');
}

Future<void> _next(WidgetTester tester) => _tap(tester, _key('request-next'));

Future<void> _consent(WidgetTester tester) => _tap(
  tester,
  find.descendant(of: _key('request-consent'), matching: find.byType(Checkbox)),
);

void _settledEntrance(WidgetTester tester) {
  expect(find.byType(StaggeredEntrance), findsOneWidget);
  final fades = tester
      .widgetList<FadeTransition>(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(FadeTransition),
        ),
      )
      .where((fade) => fade.alwaysIncludeSemantics);
  expect(fades, hasLength(1));
  expect(fades.single.opacity.value, 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xff808080), BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 8);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    _png = data!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'customer creates a request, previews privately, cancels and returns to refreshed history',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = _Repository(auth);
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        initialLocation: AppRoutes.serviceRequests,
      );
      expect(find.text('A fresh start for your home'), findsOneWidget);
      await _tap(tester, find.widgetWithText(AppButton, 'New request'));
      await _problem(tester, photo: true);
      expect(repository.submissions, 0);
      await _next(tester);
      expect(find.byType(ServiceRequestProblemStep), findsNothing);
      await _location(tester);
      await _next(tester);
      expect(find.byType(ServiceRequestReviewStep), findsOneWidget);
      await _next(tester);
      expect(repository.submissions, 0);
      expect(
        find.text(
          'Review the details and confirm location and photo storage before submitting.',
        ),
        findsOneWidget,
      );
      await _consent(tester);
      await _next(tester);
      expect(repository.submissions, 1);
      expect(find.byType(ServiceRequestDetailPage), findsOneWidget);
      expect(find.text('Kitchen tap leaks'), findsOneWidget);
      expect(find.text('Your request has been saved.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(repository.downloads, 0);
      await _tap(
        tester,
        find.widgetWithText(AppButton, 'View private photo 1'),
      );
      expect(repository.downloads, 1);
      expect(find.byType(RequestPhotoImage), findsOneWidget);
      final rendered = tester.widget<Image>(
        find.descendant(
          of: find.byType(RequestPhotoImage),
          matching: find.byType(Image),
        ),
      );
      final provider = rendered.image as ResizeImage;
      expect(provider.width, 1200);
      expect(provider.height, 1200);
      expect(provider.policy, ResizeImagePolicy.fit);
      final cacheKey = await provider.obtainKey(ImageConfiguration.empty);
      await _tap(tester, find.widgetWithText(AppButton, 'Close'));
      expect(
        PaintingBinding.instance.imageCache.containsKey(cacheKey),
        isFalse,
      );
      await _tap(tester, _key('cancel-service-request'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel request'),
        ),
      );
      expect(find.text('Cancelled'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cancel-service-request')),
        findsNothing,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ServiceRequestHistoryPage), findsOneWidget);
      expect(find.text('Kitchen tap leaks'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      expect(repository.historyLoads, greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'category chips, photo widgets and entrance remain stable while typing',
    (tester) async {
      await _pumpApp(tester);
      await _tap(tester, _key('request-add-photo'));
      final chip = tester.widget<ChoiceChip>(
        _key('request-category-demo-plumbing'),
      );
      final photo = tester.widget<RequestPhotoImage>(
        find.byType(RequestPhotoImage),
      );
      final cubit = tester
          .element(find.byType(ServiceRequestProblemStep))
          .read<ServiceRequestFormCubit>();
      final id = cubit.state.draft.id;
      await _enter(tester, 'request-title', 'A retained private draft');
      expect(
        tester.widget<ChoiceChip>(_key('request-category-demo-plumbing')),
        same(chip),
      );
      expect(
        tester.widget<RequestPhotoImage>(find.byType(RequestPhotoImage)),
        same(photo),
      );
      expect(cubit.state.draft.id, id);
      _settledEntrance(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discard confirmation protects an unsent draft without uploading',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = _Repository(auth);
      await _pumpApp(tester, auth: auth, repository: repository);
      await _problem(tester, photo: true);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard this draft?'), findsOneWidget);
      await _tap(tester, find.text('Stay here'));
      expect(find.byType(ServiceRequestFormPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Discard draft'));
      expect(find.byType(ServiceRequestFormPage), findsNothing);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(repository.submissions, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching accounts revokes an open private photo and the draft',
    (tester) async {
      final auth = await _pumpApp(tester);
      await _tap(tester, _key('request-add-photo'));
      await _tap(tester, find.byType(RequestPhotoImage));
      expect(find.byType(RequestPhotoImage), findsNWidgets(2));
      await auth.login(
        email: DemoAuthRepository.providerEmail,
        password: DemoAuthRepository.demoPassword,
      );
      await tester.pumpAndSettle();
      expect(find.byType(RequestPhotoImage), findsNothing);
      expect(find.byType(ServiceRequestFormPage), findsNothing);
      expect(find.text('Manage provider setup'), findsOneWidget);
      expect(PaintingBinding.instance.imageCache.currentSize, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a service category sheet opens a preselected request form', (
    tester,
  ) async {
    await _pumpApp(tester, initialLocation: AppRoutes.home);
    await _tap(tester, find.text('Plumbing'));
    await _tap(tester, find.widgetWithText(AppButton, 'Request this service'));
    expect(find.byType(ServiceRequestFormPage), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(_key('request-category-demo-plumbing'))
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  for (final location in [
    AppRoutes.serviceRequests,
    AppRoutes.createServiceRequest,
    '/requests/123e4567-e89b-42d3-a456-426614174000',
  ]) {
    testWidgets('provider cannot open customer route $location', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        role: UserRole.provider,
        initialLocation: location,
      );
      expect(find.byType(ServiceRequestFormPage), findsNothing);
      expect(find.byType(ServiceRequestHistoryPage), findsNothing);
      expect(find.byType(ServiceRequestDetailPage), findsNothing);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });
  }

  for (final variant in [
    (const Size(320, 640), const Locale('en'), Brightness.light, 2.0, false),
    (const Size(320, 640), const Locale('ar'), Brightness.dark, 1.6, true),
    (const Size(1200, 900), const Locale('en'), Brightness.light, 1.0, false),
  ]) {
    testWidgets(
      'request form fits $variant with keyboard and one active step',
      (tester) async {
        await _pumpApp(
          tester,
          size: variant.$1,
          locale: variant.$2,
          brightness: variant.$3,
          textScale: variant.$4,
          reducedMotion: variant.$5,
        );
        expect(tester.takeException(), isNull);
        _settledEntrance(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        await _problem(tester);
        await _next(tester);
        expect(find.byType(ServiceRequestLocationStep), findsOneWidget);
        expect(find.byType(ServiceRequestProblemStep), findsNothing);
        await _location(tester);
        await _next(tester);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(find.byType(ServiceRequestReviewStep), findsOneWidget);
        expect(find.byType(ServiceRequestLocationStep), findsNothing);
        _settledEntrance(tester);
        await _consent(tester);
        await _next(tester);
        expect(find.byType(ServiceRequestDetailPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
