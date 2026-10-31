import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salahly/src/app.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/shared/motion/staggered_entrance.dart';
import 'package:salahly/src/shared/widgets/app_text_field.dart';
import 'package:salahly/src/shared/wrappers/state_wrapper.dart';
import 'package:salahly/src/ui/auth/reset_password_screen.dart';
import 'package:salahly/src/ui/auth/signup_screen.dart';
import 'package:salahly/src/ui/auth/verify_email_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestTranslations extends AssetLoader {
  const _TestTranslations();

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return jsonDecode(
      File('$path/${locale.languageCode}.json').readAsStringSync(),
    ) as Map<String, dynamic>;
  }
}

Future<void> _pumpApp(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
  String initialLocation = AppRoutes.home,
  bool disableAnimations = false,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: disableAnimations);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
      assetLoader: const _TestTranslations(),
      child: StateWrapper(
        authRepository: DemoAuthRepository(),
        child: App(initialLocation: initialLocation),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is AppTextField && (widget.label == label || widget.hint == label),
);

Future<void> _dismissSnackBars(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final finder = find.text(label).last;
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'dummy startup guards a protected deep link and validates login',
    (tester) async {
      await _pumpApp(tester, initialLocation: AppRoutes.profile);
      expect(find.text('Welcome to Salhly'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Demo mode'), findsOneWidget);
      await _tap(tester, 'Sign in');
      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Enter your password.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home has three tabs, filters categories, and explains future bookings',
    (tester) async {
      await _pumpApp(tester);
      await _tap(tester, 'Try as customer');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(find.text('Hello, Demo Customer'), findsOneWidget);
      final rootNavigator = Navigator.of(
        tester.element(find.byType(NavigationBar)),
        rootNavigator: true,
      );

      await tester.enterText(_field('Search services'), 'plumb');
      await tester.pumpAndSettle();
      expect(find.text('Plumbing'), findsOneWidget);
      expect(find.text('Carpentry'), findsNothing);
      await _tap(tester, 'Plumbing');
      expect(find.textContaining('no booking is made here'), findsWidgets);
      expect(
        ModalRoute.of(tester.element(find.byType(BottomSheet)))!.navigator,
        same(rootNavigator),
      );
      await _tap(tester, 'Close');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'notification read state is preserved per user and profile edits update home',
    (tester) async {
      await _pumpApp(tester);
      await _tap(tester, 'Try as customer');
      await _tab(tester, 'Notifications');
      final unreadCount = find.text('Mark as read').evaluate().length;
      expect(unreadCount, greaterThan(0));
      await _tap(tester, 'Mark as read');
      expect(find.text('Mark as read').evaluate().length, unreadCount - 1);

      await _tab(tester, 'Profile');
      await tester.enterText(_field('Full name'), 'Updated Customer');
      await _tap(tester, 'Save changes');
      await _dismissSnackBars(tester);
      await _tab(tester, 'Home');
      expect(find.text('Hello, Updated Customer'), findsOneWidget);

      await _tab(tester, 'Profile');
      await _tap(tester, 'Sign out');
      expect(find.byType(NavigationBar), findsNothing);
      await _tap(tester, 'Try as provider');
      await _tab(tester, 'Notifications');
      expect(find.text('Mark as read').evaluate().length, unreadCount);
      await _tab(tester, 'Profile');
      expect(
        find.textContaining('does not verify your credentials'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'signup remains outside the shell until its email code is confirmed',
    (tester) async {
      await _pumpApp(tester);
      await _tap(tester, 'Create an account');
      await tester.enterText(_field('Full name'), 'New Customer');
      await tester.enterText(_field('Email'), 'new@example.com');
      await tester.enterText(_field('Password'), 'Password123!');
      await tester.enterText(_field('Confirm password'), 'Password123!');
      await _tap(tester, 'Create an account');
      expect(find.byType(VerifyEmailScreen), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.enterText(_field('Email code'), '000000');
      await _tap(tester, 'Confirm email');
      expect(find.textContaining('invalid or expired'), findsOneWidget);
      await tester.enterText(_field('Email code'), DemoAuthRepository.demoCode);
      await _tap(tester, 'Confirm email');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Hello, New Customer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('password recovery can be completed entirely inside the app', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _tap(tester, 'Forgot password?');
    await tester.enterText(_field('Email'), DemoAuthRepository.customerEmail);
    await _tap(tester, 'Send recovery code');
    expect(find.byType(ResetPasswordScreen), findsOneWidget);
    await tester.enterText(_field('Email code'), DemoAuthRepository.demoCode);
    await tester.enterText(_field('New password'), 'Replacement123!');
    await tester.enterText(_field('Confirm password'), 'Replacement123!');
    await _tap(tester, 'Update password');
    expect(find.byType(NavigationBar), findsOneWidget);

    await _tab(tester, 'Profile');
    await _tap(tester, 'Sign out');
    await tester.enterText(_field('Email'), DemoAuthRepository.customerEmail);
    await tester.enterText(_field('Password'), 'Replacement123!');
    await _tap(tester, 'Sign in');
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('animated tabs keep search text and unsaved profile input', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _tap(tester, 'Try as customer');
    await tester.enterText(_field('Search services'), 'plumb');
    await tester.pumpAndSettle();
    await _tab(tester, 'Profile');
    await tester.enterText(_field('Full name'), 'Unsaved draft');
    await _tab(tester, 'Home');
    expect(find.text('Carpentry'), findsNothing);
    final search = find.descendant(
      of: _field('Search services'),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(search).controller!.text, 'plumb');
    await _tab(tester, 'Profile');
    final name = find.descendant(
      of: _field('Full name'),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(name).controller!.text, 'Unsaved draft');
    expect(tester.takeException(), isNull);
  });

  testWidgets('system reduced motion applies across auth and the app shell', (
    tester,
  ) async {
    await _pumpApp(tester, disableAnimations: true);
    await _tap(tester, 'Try as customer');
    expect(
      tester
          .widget<NavigationBar>(find.byType(NavigationBar))
          .animationDuration,
      Duration.zero,
    );
    final entrances = find.descendant(
      of: find.byType(EntranceItem),
      matching: find.byType(FadeTransition),
    );
    expect(entrances, findsWidgets);
    for (final fade in tester.widgetList<FadeTransition>(entrances)) {
      expect(fade.opacity.value, 1);
    }
    await _tab(tester, 'Notifications');
    await _tab(tester, 'Profile');
    for (final scale in tester.widgetList<AnimatedScale>(
      find.byType(AnimatedScale),
    )) {
      expect(scale.duration, Duration.zero);
    }
    await _tap(tester, 'Sign out');
    expect(find.text('Welcome to Salhly'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'discovery action scrolls to services and reset preserves the entrance',
    (tester) async {
      await _pumpApp(tester);
      await _tap(tester, 'Try as customer');
      expect(find.text('Salhly'), findsOneWidget);
      await _tap(tester, 'Browse services');
      final search = _field('Search services');
      expect(tester.getRect(search).top, greaterThan(0));
      expect(
        tester.getRect(search).bottom,
        lessThan(tester.getRect(find.byType(NavigationBar)).top),
      );
      await tester.enterText(search, 'plumb');
      await tester.pumpAndSettle();
      expect(find.text('Carpentry'), findsNothing);
      await _tap(tester, 'Show all');
      expect(find.text('Carpentry'), findsOneWidget);
      for (final fade in tester.widgetList<FadeTransition>(
        find.descendant(
          of: find.byType(EntranceItem),
          matching: find.byType(FadeTransition),
        ),
      )) {
        expect(fade.opacity.value, 1);
      }
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final role in ['provider', 'admin']) {
    testWidgets('signup safely maps the $role role preset', (tester) async {
      await _pumpApp(tester, initialLocation: '${AppRoutes.signup}?role=$role');
      expect(
        tester.widget<SignupScreen>(find.byType(SignupScreen)).initialRole,
        role == 'provider' ? UserRole.provider : UserRole.customer,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final locale in [const Locale('en'), const Locale('ar')]) {
    testWidgets('redesigned pages fit narrow enlarged text in $locale', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        size: const Size(320, 640),
        locale: locale,
        brightness: Brightness.dark,
        textScale: 1.6,
      );
      expect(tester.takeException(), isNull);
      final arabic = locale.languageCode == 'ar';
      await _tap(tester, arabic ? 'التجربة كعميل' : 'Try as customer');
      expect(tester.takeException(), isNull);
      await _tap(tester, arabic ? 'تصفح الخدمات' : 'Browse services');
      expect(tester.takeException(), isNull);
      await _tab(tester, arabic ? 'الإشعارات' : 'Notifications');
      expect(tester.takeException(), isNull);
      await _tab(tester, arabic ? 'الملف الشخصي' : 'Profile');
      expect(tester.takeException(), isNull);
    });
  }

  for (final variant in [
    (const Size(320, 640), const Locale('en'), Brightness.light),
    (const Size(320, 640), const Locale('ar'), Brightness.dark),
    (const Size(1200, 900), const Locale('en'), Brightness.light),
    (const Size(390, 844), const Locale('ar'), Brightness.dark),
  ]) {
    testWidgets('responsive ${variant.$1} ${variant.$2} ${variant.$3}', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        size: variant.$1,
        locale: variant.$2,
        brightness: variant.$3,
      );
      final arabic = variant.$2.languageCode == 'ar';
      await _tap(tester, arabic ? 'التجربة كعميل' : 'Try as customer');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.byType(NavigationBar))),
        arabic ? TextDirection.rtl : TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
      await _tab(tester, arabic ? 'الإشعارات' : 'Notifications');
      expect(tester.takeException(), isNull);
      await _tab(tester, arabic ? 'الملف الشخصي' : 'Profile');
      expect(tester.takeException(), isNull);
    });
  }
}
