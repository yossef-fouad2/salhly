import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:salahly/src/app.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/shared/motion/staggered_entrance.dart';
import 'package:salahly/src/shared/widgets/app_text_field.dart';
import 'package:salahly/src/shared/wrappers/state_wrapper.dart';
import 'package:salahly/src/ui/auth/signup_screen.dart';
import 'package:salahly/src/ui/auth/verify_email_screen.dart';
import 'package:salahly/src/ui/auth/widgets/account_role_card.dart';
import 'package:salahly/src/ui/auth/widgets/auth_layout.dart';
import 'package:salahly/src/ui/onboarding/onboarding_page.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Translations extends AssetLoader {
  const _Translations();

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      jsonDecode(File('$path/${locale.languageCode}.json').readAsStringSync())
          as Map<String, dynamic>;
}

class _DelayedSignUpRepository extends DemoAuthRepository {
  final release = Completer<void>();
  UserRole? submittedRole;

  @override
  FutureEither<SignUpResult> signUp({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) async {
    submittedRole = role;
    await release.future;
    return super.signUp(
      name: name,
      email: email,
      password: password,
      role: role,
    );
  }
}

Future<void> _pumpApp(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  double keyboardInset = 0,
  bool reducedMotion = false,
  DemoAuthRepository? authRepository,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reducedMotion);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ar')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: locale,
      saveLocale: false,
      assetLoader: const _Translations(),
      child: StateWrapper(
        authRepository: authRepository ?? DemoAuthRepository(),
        child: const App(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is AppTextField && widget.label == label,
);

Future<void> _tap(WidgetTester tester, String label) async {
  final finder = find.text(label).last;
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _expectFinishedEntrance(WidgetTester tester) {
  expect(find.byType(StaggeredEntrance), findsOneWidget);
  final fades = find.descendant(
    of: find.byType(EntranceItem),
    matching: find.byWidgetPredicate(
      (widget) => widget is FadeTransition && widget.alwaysIncludeSemantics,
    ),
  );
  expect(fades, findsNWidgets(2));
  for (final fade in tester.widgetList<FadeTransition>(fades)) {
    expect(fade.opacity.value, 1);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('welcome role cards hand off to the editable signup role', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _tap(tester, 'Explore account types');
    expect(find.byType(OnboardingPage), findsOneWidget);
    final entrance = tester.state(find.byType(StaggeredEntrance));
    final customer = find.byKey(const ValueKey('welcome-role-customer'));
    final provider = find.byKey(const ValueKey('welcome-role-provider'));
    Semantics selection(Finder card) => tester.widget<Semantics>(
      find.descendant(of: card, matching: find.byType(Semantics)).first,
    );
    expect(selection(customer).properties.checked, isTrue);
    expect(selection(provider).properties.checked, isFalse);

    await _tap(tester, 'I am a professional');
    expect(selection(customer).properties.checked, isFalse);
    expect(selection(provider).properties.checked, isTrue);
    expect(tester.state(find.byType(StaggeredEntrance)), same(entrance));
    _expectFinishedEntrance(tester);

    await _tap(tester, 'Create an account');
    expect(
      tester.widget<SignupScreen>(find.byType(SignupScreen)).initialRole,
      UserRole.provider,
    );
    expect(find.byType(DropdownButtonFormField<UserRole>), findsNothing);
    expect(find.byType(AccountRoleCard), findsNWidgets(2));
    final signupCustomer = find.byKey(const ValueKey('signup-role-customer'));
    final signupProvider = find.byKey(const ValueKey('signup-role-provider'));
    expect(selection(signupCustomer).properties.checked, isFalse);
    expect(selection(signupProvider).properties.checked, isTrue);
    expect(
      find.textContaining('Creating an account does not verify you.'),
      findsOneWidget,
    );
    await tester.enterText(_field('Full name'), 'Local Professional');
    await tester.enterText(_field('Password'), 'Password123!');
    await tester.ensureVisible(find.byTooltip('Show password').first);
    await tester.tap(find.byTooltip('Show password').first);
    await tester.pumpAndSettle();
    final form = tester.state(find.byType(Form));
    await _tap(tester, 'I need home services');
    expect(selection(signupCustomer).properties.checked, isTrue);
    expect(selection(signupProvider).properties.checked, isFalse);
    expect(tester.state(find.byType(Form)), same(form));
    expect(
      tester.widget<AppTextField>(_field('Full name')).controller!.text,
      'Local Professional',
    );
    expect(
      tester.widget<AppTextField>(_field('Password')).obscureText,
      isFalse,
    );
    expect(
      find.textContaining('Creating an account does not verify you.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final role in UserRole.values) {
    testWidgets('signup submits the $role card and locks roles while loading', (
      tester,
    ) async {
      final repository = _DelayedSignUpRepository();
      addTearDown(() {
        if (!repository.release.isCompleted) repository.release.complete();
      });
      await _pumpApp(tester, authRepository: repository);
      await _tap(tester, 'Create an account');
      final selected = find.byKey(ValueKey('signup-role-${role.name}'));
      final other = find.byKey(
        ValueKey(
          'signup-role-${role == UserRole.customer ? 'provider' : 'customer'}',
        ),
      );
      await tester.ensureVisible(selected);
      await tester.tap(selected);
      await tester.pumpAndSettle();
      await tester.enterText(_field('Full name'), 'New Account');
      await tester.enterText(_field('Email'), 'new-${role.name}@example.com');
      await tester.enterText(_field('Password'), 'Password123!');
      await tester.enterText(_field('Confirm password'), 'Password123!');
      final submit = find.text('Create an account').last;
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.submittedRole, role);
      for (final card in tester.widgetList<AccountRoleCard>(
        find.byType(AccountRoleCard),
      )) {
        expect(card.onTap, isNull);
      }
      final semantics = tester.widget<Semantics>(
        find.descendant(of: selected, matching: find.byType(Semantics)).first,
      );
      expect(semantics.properties.enabled, isFalse);
      expect(semantics.properties.checked, isTrue);
      await tester.ensureVisible(other);
      await tester.tap(other);
      await tester.pump();
      expect(tester.widget<AccountRoleCard>(selected).selected, isTrue);
      expect(tester.widget<AccountRoleCard>(other).selected, isFalse);
      repository.release.complete();
      await tester.pumpAndSettle();
      expect(find.byType(VerifyEmailScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'auth errors, resize and language changes retain the login form',
    (tester) async {
      await _pumpApp(tester);
      final form = tester.state(find.byType(Form));
      final entrance = tester.state(find.byType(StaggeredEntrance));
      await tester.enterText(_field('Email'), 'missing@example.com');
      await tester.enterText(_field('Password'), 'Password123!');
      await tester.ensureVisible(find.byTooltip('Show password'));
      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      await _tap(tester, 'Sign in');
      expect(find.text('The email or password is incorrect.'), findsOneWidget);
      expect(tester.state(find.byType(Form)), same(form));
      expect(tester.state(find.byType(StaggeredEntrance)), same(entrance));
      _expectFinishedEntrance(tester);

      tester.view.physicalSize = const Size(1200, 900);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(Form)), same(form));
      expect(
        tester.widget<AppTextField>(_field('Password')).obscureText,
        isFalse,
      );
      expect(
        tester.widget<AppTextField>(_field('Email')).controller!.text,
        'missing@example.com',
      );
      await _tap(tester, 'Arabic');
      final context = tester.element(find.byType(AuthLayout));
      expect(Directionality.of(context), TextDirection.rtl);
      expect(find.text('app.name'.tr(context: context)), findsOneWidget);
      expect(find.text('Salhly'), findsNothing);
      expect(tester.state(find.byType(Form)), same(form));
      expect(
        tester
            .widget<AppTextField>(_field('auth.email'.tr(context: context)))
            .controller!
            .text,
        'missing@example.com',
      );
      expect(tester.state(find.byType(StaggeredEntrance)), same(entrance));
      _expectFinishedEntrance(tester);
      expect(tester.takeException(), isNull);
    },
  );

  for (final variant in [
    (const Size(320, 640), const Locale('en'), Brightness.light, 2.0, 260.0),
    (const Size(320, 640), const Locale('ar'), Brightness.dark, 2.0, 260.0),
    (const Size(1200, 900), const Locale('en'), Brightness.light, 1.0, 0.0),
    (const Size(1200, 900), const Locale('ar'), Brightness.dark, 1.8, 0.0),
  ]) {
    testWidgets('auth layouts adapt to $variant', (tester) async {
      await _pumpApp(
        tester,
        size: variant.$1,
        locale: variant.$2,
        brightness: variant.$3,
        textScale: variant.$4,
        keyboardInset: variant.$5,
        reducedMotion: true,
      );
      for (final page in [
        (AppRouteNames.login, 'auth.sign_in'),
        (AppRouteNames.onboarding, 'auth.create_account'),
        (AppRouteNames.signup, 'auth.create_account'),
        (AppRouteNames.forgotPassword, 'auth.send_code'),
        (AppRouteNames.verifyEmail, 'auth.verify_email'),
        (AppRouteNames.resetPassword, 'auth.update_password'),
      ]) {
        tester
            .element(find.byType(AuthLayout))
            .goNamed(
              page.$1,
              queryParameters: {
                'role': 'provider',
                'email': DemoAuthRepository.customerEmail,
              },
            );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(AuthLayout));
        final action = find.text(page.$2.tr(context: context)).last;
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        expect(
          Directionality.of(context),
          variant.$2.languageCode == 'ar'
              ? TextDirection.rtl
              : TextDirection.ltr,
        );
        _expectFinishedEntrance(tester);
        for (final scale in tester.widgetList<AnimatedScale>(
          find.byType(AnimatedScale),
        )) {
          expect(scale.duration, Duration.zero);
        }
        expect(tester.takeException(), isNull, reason: page.$1);
      }
    });
  }
}
