import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/app.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/models/verification_document.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/provider_repository.dart';
import 'package:salahly/src/routing/app_router.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/services/verification_document_picker.dart';
import 'package:salahly/src/shared/motion/staggered_entrance.dart';
import 'package:salahly/src/shared/wrappers/state_wrapper.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';
import 'package:salahly/src/ui/provider/provider_coverage_step.dart';
import 'package:salahly/src/ui/provider/provider_details_step.dart';
import 'package:salahly/src/ui/provider/provider_onboarding_cubit.dart';
import 'package:salahly/src/ui/provider/provider_onboarding_page.dart';
import 'package:salahly/src/ui/provider/provider_verification_step.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Translations extends AssetLoader {
  const _Translations();

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      jsonDecode(File('$path/${locale.languageCode}.json').readAsStringSync())
          as Map<String, dynamic>;
}

class _Picker extends VerificationDocumentPicker {
  _Picker(this.document);

  final VerificationDocument document;
  int calls = 0;

  @override
  FutureEither<VerificationDocument?> pick() async {
    calls++;
    return right(document);
  }
}

class _DelayedRepository extends ProviderRepository {
  _DelayedRepository(DemoAuthRepository auth) : super(authRepository: auth);

  Completer<Either<Failure, ProviderProfile>>? delayedLoad;

  @override
  FutureEither<ProviderProfile> loadProfile(String userId) =>
      delayedLoad?.future ?? super.loadProfile(userId);
}

late VerificationDocument _document;

Future<DemoAuthRepository> _pumpApp(
  WidgetTester tester, {
  DemoAuthRepository? auth,
  ProviderRepository? repository,
  UserRole role = UserRole.provider,
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
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final authRepository = auth ?? DemoAuthRepository();
  await authRepository.login(
    email: role == UserRole.provider
        ? DemoAuthRepository.providerEmail
        : DemoAuthRepository.customerEmail,
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
        providerRepository: repository,
        verificationDocumentPicker: _Picker(_document),
        child: const App(initialLocation: AppRoutes.providerOnboarding),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return authRepository;
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _next(WidgetTester tester) => _tap(tester, _key('provider-next'));

Future<void> _details(WidgetTester tester) async {
  await tester.enterText(
    _key('provider-bio'),
    'I repair household plumbing and maintain water pipes.',
  );
  await _tap(tester, _key('provider-skill-demo-plumbing'));
  await _next(tester);
}

Future<void> _coverage(WidgetTester tester) async {
  await tester.enterText(
    _key('provider-areas'),
    'Central district\nNorth district',
  );
  await _tap(tester, _key('provider-day-1'));
  await _next(tester);
}

ProviderOnboardingCubit _cubit(WidgetTester tester) =>
    tester.element(_key('provider-next')).read<ProviderOnboardingCubit>();

Future<void> _dismissSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color(0xff808080), BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 8);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    _document = VerificationDocument.fromBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('provider deep links require a signed-in provider, never a recovery session', () {
    const provider = AppUser(
      id: 'provider',
      email: 'provider@example.test',
      name: 'Provider',
      role: UserRole.provider,
    );
    const customer = AppUser(
      id: 'customer',
      email: 'customer@example.test',
      name: 'Customer',
    );
    expect(
      redirectForSession(
        const SessionState(status: SessionStatus.authenticated, user: provider),
        AppRoutes.providerOnboarding,
      ),
      isNull,
    );
    expect(
      redirectForSession(
        const SessionState(status: SessionStatus.authenticated, user: customer),
        AppRoutes.providerOnboarding,
      ),
      AppRoutes.home,
    );
    expect(
      redirectForSession(
        const SessionState(status: SessionStatus.unauthenticated),
        AppRoutes.providerOnboarding,
      ),
      AppRoutes.login,
    );
    expect(
      redirectForSession(
        const SessionState(
          status: SessionStatus.passwordRecovery,
          user: provider,
        ),
        AppRoutes.providerOnboarding,
      ),
      AppRoutes.resetPassword,
    );
  });

  testWidgets('customer deep links never mount provider UI', (tester) async {
    await _pumpApp(tester, role: UserRole.customer);
    expect(find.byType(ProviderOnboardingPage), findsNothing);
    expect(find.text('Hello, Demo Customer'), findsOneWidget);
    expect(find.text('Manage provider setup'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'one active section and one entrance; typing does not rebuild skill chips',
    (tester) async {
      await _pumpApp(tester);
      expect(find.byType(ProviderDetailsStep), findsOneWidget);
      expect(find.byType(ProviderCoverageStep), findsNothing);
      expect(find.byType(ProviderVerificationStep), findsNothing);
      expect(find.byType(StaggeredEntrance), findsOneWidget);
      final chip = tester.widget<FilterChip>(
        _key('provider-skill-demo-plumbing'),
      );
      for (var index = 0; index < 8; index++) {
        await tester.enterText(
          _key('provider-bio'),
          'A local draft introduction $index',
        );
        await tester.pump();
      }
      expect(
        tester.widget<FilterChip>(_key('provider-skill-demo-plumbing')),
        same(chip),
      );
      await _next(tester);
      expect(find.byType(ProviderDetailsStep), findsNothing);
      expect(find.byType(ProviderCoverageStep), findsOneWidget);
      expect(find.byType(StaggeredEntrance), findsOneWidget);
      await _tap(tester, find.text('Back'));
      final field = find.descendant(
        of: _key('provider-bio'),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        'A local draft introduction 7',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'provider can submit once, review pending state, and privately preview bounded images',
    (tester) async {
      await _pumpApp(tester);
      await _details(tester);
      await _coverage(tester);
      await _tap(tester, _key('provider-pick-document'));
      expect(find.textContaining('Not uploaded yet.'), findsOneWidget);
      await _tap(tester, _key('provider-consent'));
      await _next(tester);
      expect(find.text('Awaiting review'), findsOneWidget);
      expect(find.text('Credential verified'), findsNothing);
      expect(find.textContaining('No real review or approval'), findsOneWidget);
      expect(_cubit(tester).state.document, isNull);
      expect(_cubit(tester).state.canEdit, isFalse);
      await _dismissSnackBar(tester);
      await _tap(tester, find.text('View submitted document'));
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<ResizeImage>());
      final resize = image.image as ResizeImage;
      expect(resize.width, 1200);
      expect(resize.height, 1200);
      expect(resize.policy, ResizeImagePolicy.fit);
      final imageKey = await resize.obtainKey(ImageConfiguration.empty);
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Close'),
        ),
      );
      expect(
        PaintingBinding.instance.imageCache.containsKey(imageKey),
        isFalse,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'provider account switch removes the prior private preview and cache',
    (tester) async {
      final auth = DemoAuthRepository();
      const email = 'second-provider@example.test';
      await auth.signUp(
        name: 'Second Provider',
        email: email,
        password: DemoAuthRepository.demoPassword,
        role: UserRole.provider,
      );
      await auth.confirmEmail(email: email, code: DemoAuthRepository.demoCode);
      await _pumpApp(tester, auth: auth);
      await _details(tester);
      await _coverage(tester);
      await _tap(tester, _key('provider-pick-document'));
      await _tap(tester, _key('provider-consent'));
      await _next(tester);
      await _dismissSnackBar(tester);
      await _tap(tester, find.text('View submitted document'));
      final image = tester.widget<Image>(find.byType(Image));
      final imageKey = await image.image.obtainKey(ImageConfiguration.empty);
      final previousUserId = _cubit(tester).state.profile!.userId;
      final sessionBloc = tester
          .element(_key('provider-next'))
          .read<SessionBloc>();
      final switched = sessionBloc.stream.firstWhere(
        (state) =>
            state.status == SessionStatus.authenticated &&
            state.user?.id != previousUserId,
      );
      final login = await auth.login(
        email: email,
        password: DemoAuthRepository.demoPassword,
      );
      expect(login.isRight(), isTrue);
      await switched;
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        PaintingBinding.instance.imageCache.containsKey(imageKey),
        isFalse,
      );
      expect(_cubit(tester).state.profile!.userId, isNot(previousUserId));
      expect(_cubit(tester).state.profile!.bio, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial saved drafts resume after leaving; unsaved exits require confirmation',
    (tester) async {
      await _pumpApp(tester);
      await tester.enterText(
        _key('provider-bio'),
        'A saved partial introduction.',
      );
      await _tap(tester, _key('provider-save'));
      await _dismissSnackBar(tester);
      await _tap(tester, find.byType(BackButton));
      expect(find.text('Hello, Demo Provider'), findsOneWidget);
      await _tap(tester, find.text('Manage provider setup'));
      final field = find.descendant(
        of: _key('provider-bio'),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        'A saved partial introduction.',
      );
      await tester.enterText(
        _key('provider-bio'),
        'An unsaved replacement introduction.',
      );
      await _tap(tester, find.byType(BackButton));
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await _tap(tester, find.text('Keep editing'));
      expect(
        tester.widget<TextField>(field).controller!.text,
        'An unsaved replacement introduction.',
      );
      await _tap(tester, find.byType(BackButton));
      await _tap(tester, find.text('Discard changes'));
      expect(find.byType(ProviderOnboardingPage), findsNothing);
      await _tap(tester, find.text('Manage provider setup'));
      expect(
        tester.widget<TextField>(field).controller!.text,
        'A saved partial introduction.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'logout removes an unsaved provider draft without exposing it to a customer',
    (tester) async {
      final auth = await _pumpApp(tester);
      await tester.enterText(
        _key('provider-bio'),
        'Private unsaved provider details.',
      );
      await auth.logout();
      await tester.pumpAndSettle();
      expect(find.byType(ProviderOnboardingPage), findsNothing);
      expect(find.text('Welcome to Salhly'), findsOneWidget);
      await _tap(tester, find.text('Try as customer'));
      expect(find.text('Hello, Demo Customer'), findsOneWidget);
      expect(find.text('Private unsaved provider details.'), findsNothing);
      expect(find.text('Manage provider setup'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh keeps mounted verification content and scroll during delayed failure',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = _DelayedRepository(auth);
      await _pumpApp(tester, auth: auth, repository: repository);
      await _details(tester);
      await _coverage(tester);
      await tester.ensureVisible(_key('provider-consent'));
      await tester.pumpAndSettle();
      final scroll = Scrollable.of(tester.element(_key('provider-consent')))
          .position;
      final offset = scroll.pixels;
      final element = tester.element(find.byType(ProviderVerificationStep));
      repository.delayedLoad = Completer();
      final operation = _cubit(tester).load();
      await tester.pump();
      expect(
        tester.element(find.byType(ProviderVerificationStep)),
        same(element),
      );
      expect(scroll.pixels, offset);
      repository.delayedLoad!.complete(
        left(const ServerFailure('errors.network')),
      );
      await operation;
      await tester.pumpAndSettle();
      expect(
        tester.element(find.byType(ProviderVerificationStep)),
        same(element),
      );
      expect(scroll.pixels, offset);
      expect(find.textContaining('Could not connect.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion finishes immediately, including a mid-step preference change',
    (tester) async {
      await _pumpApp(tester);
      await tester.tap(_key('provider-next'));
      await tester.pump(const Duration(milliseconds: 50));
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpAndSettle();
      final fades = find.descendant(
        of: find.byType(EntranceItem),
        matching: find.byType(FadeTransition),
      );
      for (final fade in tester.widgetList<FadeTransition>(fades)) {
        expect(fade.opacity.value, 1);
      }
      expect(tester.binding.transientCallbackCount, 0);
      await _next(tester);
      expect(find.byType(ProviderVerificationStep), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'provider form remains usable above the keyboard with enlarged text',
    (tester) async {
      await _pumpApp(
        tester,
        size: const Size(320, 640),
        textScale: 1.4,
        reducedMotion: true,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        _key('provider-bio'),
        'A locally edited introduction above the keyboard.',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _next(tester);
      expect(find.byType(ProviderCoverageStep), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await _next(tester);
      expect(find.byType(ProviderVerificationStep), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final variant in [
    (const Size(320, 640), const Locale('en'), Brightness.light),
    (const Size(320, 640), const Locale('ar'), Brightness.dark),
    (const Size(1200, 900), const Locale('en'), Brightness.light),
  ]) {
    testWidgets(
      'provider steps fit ${variant.$1} ${variant.$2} ${variant.$3}',
      (tester) async {
        await _pumpApp(
          tester,
          size: variant.$1,
          locale: variant.$2,
          brightness: variant.$3,
          reducedMotion: true,
        );
        final direction = variant.$2.languageCode == 'ar'
            ? TextDirection.rtl
            : TextDirection.ltr;
        expect(
          Directionality.of(tester.element(_key('provider-bio'))),
          direction,
        );
        await _details(tester);
        expect(tester.takeException(), isNull);
        await _coverage(tester);
        expect(tester.takeException(), isNull);
        await _tap(tester, _key('provider-pick-document'));
        await _tap(tester, _key('provider-consent'));
        await _next(tester);
        expect(
          _cubit(tester).state.profile!.verification!.status,
          ProviderVerificationStatus.pending,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
