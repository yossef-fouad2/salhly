import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:salahly/src/app.dart';
import 'package:salahly/src/data/models/marketplace.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/service_request_repository.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/shared/widgets/app_button.dart';
import 'package:salahly/src/shared/wrappers/state_wrapper.dart';
import 'package:salahly/src/ui/marketplace/customer_quotes_page.dart';
import 'package:salahly/src/ui/marketplace/job_detail_page.dart';
import 'package:salahly/src/ui/marketplace/provider_browse_page.dart';
import 'package:salahly/src/ui/marketplace/provider_quote_page.dart';
import 'package:salahly/src/ui/requests/service_request_detail_page.dart';
import 'package:salahly/src/ui/requests/service_request_form_page.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'marketplace_ui_fakes.dart';

class _Translations extends AssetLoader {
  const _Translations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      jsonDecode(File('$path/${locale.languageCode}.json').readAsStringSync())
          as Map<String, dynamic>;
}

class _Requests extends ServiceRequestRepository {
  _Requests(DemoAuthRepository auth, this.marketplace)
    : super(authRepository: auth);
  final MarketplaceUiRepository marketplace;
  int loads = 0;

  @override
  FutureEither<ServiceRequest> loadRequest(
    String requestId, {
    required String userId,
  }) async {
    loads++;
    return right(
      ServiceRequest(
        id: requestId,
        customerId: userId,
        categoryId: 'demo-plumbing',
        categoryNameEn: 'Plumbing',
        categoryNameAr: 'سباكة',
        categoryIconKey: 'plumbing',
        title: 'Original private request title',
        description:
            'Original private details that were never copied into the listing.',
        city: 'Private city field',
        address: 'Private building 27, apartment 9',
        status: marketplace.book.requestStatus,
        createdAt: uiNow,
        consentedAt: uiNow,
        photos: const [],
      ),
    );
  }
}

String _requestQuotesLocation() =>
    AppRoutes.requestQuotes.replaceFirst(':requestId', uiRequestId);
String _providerQuoteLocation() =>
    AppRoutes.providerQuote.replaceFirst(':requestId', uiRequestId);
String _jobLocation() => AppRoutes.jobDetail.replaceFirst(':jobId', uiJobId);

Future<MarketplaceUiRepository> _pumpApp(
  WidgetTester tester, {
  DemoAuthRepository? auth,
  MarketplaceUiRepository? repository,
  ServiceRequestRepository? requests,
  String? initialLocation,
  bool provider = false,
  Locale locale = const Locale('en'),
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final account = auth ?? DemoAuthRepository();
  await account.login(
    email: provider
        ? DemoAuthRepository.marketplaceProviderEmail
        : DemoAuthRepository.customerEmail,
    password: DemoAuthRepository.demoPassword,
  );
  final marketplace = repository ?? MarketplaceUiRepository(account);
  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ar')],
      path: 'assets/translations',
      startLocale: locale,
      fallbackLocale: const Locale('en'),
      saveLocale: false,
      assetLoader: const _Translations(),
      child: StateWrapper(
        authRepository: account,
        marketplaceRepository: marketplace,
        serviceRequestRepository: requests,
        child: App(
          initialLocation: initialLocation ?? _requestQuotesLocation(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return marketplace;
}

Finder _key(String key) => find.byKey(ValueKey(key));
Finder _field(String key) =>
    find.descendant(of: _key(key), matching: find.byType(TextFormField));

Future<void> _visible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      350,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pump();
}

Future<void> _tap(
  WidgetTester tester,
  Finder finder, {
  bool settle = true,
}) async {
  if (find.byType(SnackBar).evaluate().isNotEmpty) {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }
  await _visible(tester, finder);
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  await _visible(tester, _field(key));
  await tester.enterText(_field(key), value);
  await tester.pump();
}

Finder _dialogButton(String label) => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.widgetWithText(TextButton, label),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'publication uses blank separate fields and cannot skip consent',
    (tester) async {
      final repository = await _pumpApp(tester);
      expect(find.byType(CustomerQuotesPage), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNothing);
      expect(
        tester
            .widget<TextFormField>(_field('marketplace-public-summary'))
            .initialValue,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(_field('marketplace-public-city'))
            .initialValue,
        isEmpty,
      );
      expect(find.text('Original private request title'), findsNothing);
      expect(find.text('Private building 27, apartment 9'), findsNothing);
      await _enter(
        tester,
        'marketplace-public-summary',
        'A new broad public plumbing summary.',
      );
      await _enter(tester, 'marketplace-public-city', 'Cairo');
      await _tap(tester, _key('marketplace-publish'));
      expect(repository.publications, isEmpty);
      expect(
        find.text(
          'Review the sharing information and explicitly confirm before continuing.',
        ),
        findsOneWidget,
      );
      await _tap(
        tester,
        find.descendant(
          of: _key('marketplace-publish-consent'),
          matching: find.byType(Checkbox),
        ),
      );
      await _tap(tester, _key('marketplace-publish'));
      expect(repository.publications, hasLength(1));
      expect(repository.publications.single.consent, isTrue);
      expect(find.text('Your shared listing'), findsOneWidget);
      expect(find.text('A new broad public plumbing summary.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('marketplace-public-summary')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dirty publication exit confirms without submitting', (
    tester,
  ) async {
    final repository = await _pumpApp(tester);
    await _enter(
      tester,
      'marketplace-public-summary',
      'An unfinished public summary',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await _tap(tester, _dialogButton('Stay here'));
    expect(find.byType(CustomerQuotesPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _tap(tester, _dialogButton('Discard changes'));
    expect(find.byType(CustomerQuotesPage), findsNothing);
    expect(repository.publications, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider can submit, withdraw and reactivate a quote', (
    tester,
  ) async {
    final repository = await _pumpApp(
      tester,
      provider: true,
      initialLocation: _providerQuoteLocation(),
    );
    expect(find.byType(ProviderQuotePage), findsOneWidget);
    expect(find.text('Private building 27, apartment 9'), findsNothing);
    await _enter(tester, 'marketplace-quote-amount', '١٢٥٫٥٠');
    await _enter(tester, 'marketplace-quote-duration', '٩٠');
    await _enter(
      tester,
      'marketplace-quote-notes',
      'Sample labour terms only.',
    );
    await _tap(tester, _key('marketplace-save-quote'));
    expect(repository.drafts.single.amountMinor, 12550);
    expect(repository.drafts.single.durationMinutes, 90);
    expect(find.text('Pending quote'), findsOneWidget);
    await _tap(tester, _key('marketplace-withdraw-quote'));
    await _tap(tester, _dialogButton('Withdraw quote'));
    expect(repository.withdrawals, hasLength(1));
    expect(repository.quote!.status, QuoteStatus.withdrawn);
    expect(
      tester.widget<AppButton>(_key('marketplace-save-quote')).label,
      'Reactivate quote',
    );
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    await _visible(tester, find.text('Withdrawn'));
    expect(find.text('Withdrawn'), findsOneWidget);
    await _tap(tester, _key('marketplace-save-quote'));
    expect(repository.drafts, hasLength(2));
    expect(repository.drafts.last.expectedRevision, 1);
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    await _visible(tester, find.text('Pending quote'));
    expect(find.text('Pending quote'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uncertain save freezes fields and retries the same draft', (
    tester,
  ) async {
    final repository = await _pumpApp(
      tester,
      provider: true,
      initialLocation: _providerQuoteLocation(),
    );
    await _enter(tester, 'marketplace-quote-amount', '125.50');
    await _enter(tester, 'marketplace-quote-duration', '90');
    repository.pendingSave = Completer();
    await _tap(tester, _key('marketplace-save-quote'), settle: false);
    expect(repository.drafts, hasLength(1));
    expect(
      tester.widget<AppButton>(_key('marketplace-save-quote')).onPressed,
      isNull,
    );
    repository.pendingSave!.complete(
      left(const ServerFailure('marketplace.errors.uncertain')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(_field('marketplace-quote-amount')).enabled,
      isFalse,
    );
    final original = repository.drafts.single;
    repository.pendingSave = null;
    await _tap(tester, _key('marketplace-retry-original'));
    expect(repository.drafts, hasLength(2));
    expect(repository.drafts.last, same(original));
    expect(
      tester.widget<TextFormField>(_field('marketplace-quote-amount')).enabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'stale acceptance shows consent and never creates an optimistic job',
    (tester) async {
      final auth = DemoAuthRepository();
      final quote = uiQuote();
      final repository = MarketplaceUiRepository(auth)
        ..book = uiBook(quotes: [quote])
        ..mutationFailure = const ServerFailure('marketplace.errors.conflict');
      await _pumpApp(tester, auth: auth, repository: repository);
      await _tap(tester, _key('accept-quote-$uiQuoteId'));
      expect(find.text('Accept these exact terms?'), findsOneWidget);
      expect(
        find.textContaining(
          'Photos stay owner-only; contact details and credentials',
        ),
        findsOneWidget,
      );
      await _tap(tester, _dialogButton('Accept and share details'));
      expect(repository.acceptances.single.quote, same(quote));
      expect(repository.acceptances.single.quote.revision, 1);
      expect(
        find.byKey(const ValueKey('marketplace-open-assigned-job')),
        findsNothing,
      );
      expect(repository.book.job, isNull);
      expect(
        find.textContaining('The recorded terms or status changed.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'request detail opens comparison and refreshes after accepted job returns',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MarketplaceUiRepository(auth)
        ..book = uiBook(quotes: [uiQuote()]);
      final requests = _Requests(auth, repository);
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        requests: requests,
        initialLocation: AppRoutes.serviceRequestDetail.replaceFirst(
          ':requestId',
          uiRequestId,
        ),
      );
      await _tap(tester, _key('request-open-quotes'));
      expect(find.byType(CustomerQuotesPage), findsOneWidget);
      await _tap(tester, _key('accept-quote-$uiQuoteId'));
      await _tap(tester, _dialogButton('Accept and share details'));
      await _tap(tester, _key('marketplace-open-assigned-job'));
      expect(find.byType(JobDetailPage), findsOneWidget);
      expect(find.text('Private building 27, apartment 9'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ServiceRequestDetailPage), findsOneWidget);
      expect(find.text('Provider selected'), findsOneWidget);
      expect(_key('cancel-service-request'), findsNothing);
      expect(requests.loads, greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('provider can skip on-the-way but cannot confirm completion', (
    tester,
  ) async {
    final repository = await _pumpApp(
      tester,
      provider: true,
      initialLocation: _jobLocation(),
    );
    expect(_key('job-action-on_the_way'), findsOneWidget);
    expect(_key('job-action-completed'), findsNothing);
    await _tap(tester, _key('job-action-in_progress'));
    await _tap(tester, _dialogButton('Start work'));
    expect(repository.transitions.single.target, JobStatus.inProgress);
    expect(_key('job-action-cancelled'), findsNothing);
    await _tap(tester, _key('job-action-awaiting_confirmation'));
    await _tap(tester, _dialogButton('Request completion confirmation'));
    expect(repository.job.status, JobStatus.awaitingConfirmation);
    expect(_key('job-action-completed'), findsNothing);
    expect(repository.job.history.map((event) => event.status), [
      JobStatus.selected,
      JobStatus.inProgress,
      JobStatus.awaitingConfirmation,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'only customer completion closes the job and adds recorded history',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MarketplaceUiRepository(auth)
        ..job = uiJob(status: JobStatus.awaitingConfirmation);
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        initialLocation: _jobLocation(),
      );
      expect(_key('job-action-in_progress'), findsNothing);
      expect(_key('job-action-cancelled'), findsNothing);
      await _tap(tester, _key('job-action-completed'));
      await _tap(tester, _dialogButton('Confirm completion'));
      expect(repository.transitions.single.target, JobStatus.completed);
      expect(repository.job.history.last.actorId, uiCustomerId);
      expect(_key('job-action-completed'), findsNothing);
      expect(
        find.textContaining('The customer confirmed completion.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account replacement hides the old address even with a late load',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MarketplaceUiRepository(auth);
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        initialLocation: _jobLocation(),
      );
      expect(find.text('Private building 27, apartment 9'), findsOneWidget);
      repository.pendingJob = Completer();
      await auth.login(
        email: DemoAuthRepository.providerEmail,
        password: DemoAuthRepository.demoPassword,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Private building 27, apartment 9'), findsNothing);
      repository.pendingJob!.complete(right(uiJob()));
      await tester.pumpAndSettle();
      expect(find.text('Private building 27, apartment 9'), findsNothing);
      expect(_key('marketplace-job-address'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a rebuilt page offers the retained original operation retry', (
    tester,
  ) async {
    final auth = DemoAuthRepository();
    final repository = MarketplaceUiRepository(auth)..storedPending = true;
    await _pumpApp(tester, auth: auth, repository: repository);
    expect(_key('marketplace-retry-original'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(_field('marketplace-public-summary'))
          .enabled,
      isFalse,
    );
    repository.book = uiBook(job: uiJob());
    await _tap(tester, _key('marketplace-retry-original'));
    expect(repository.storedRetries, 1);
    expect(_key('marketplace-open-assigned-job'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final route in [
    AppRoutes.providerRequestFeed,
    AppRoutes.providerQuotes,
    _providerQuoteLocation(),
  ]) {
    testWidgets(
      'customer deep-link guard rejects $route without changing three tabs',
      (tester) async {
        await _pumpApp(tester, initialLocation: route);
        expect(find.byType(ProviderBrowsePage), findsNothing);
        expect(find.byType(ProviderQuotePage), findsNothing);
        expect(find.byType(NavigationDestination), findsNWidgets(3));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('provider cannot deep-link into customer comparison', (
    tester,
  ) async {
    await _pumpApp(tester, provider: true);
    expect(find.byType(CustomerQuotesPage), findsNothing);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'static new-request route keeps precedence over request identifiers',
    (tester) async {
      await _pumpApp(tester, initialLocation: AppRoutes.createServiceRequest);
      expect(find.byType(ServiceRequestFormPage), findsOneWidget);
      expect(find.byType(ServiceRequestDetailPage), findsNothing);
      expect(find.byType(CustomerQuotesPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final variant in [
    (const Size(320, 640), const Locale('en'), Brightness.light, 2.0),
    (const Size(320, 640), const Locale('ar'), Brightness.dark, 1.8),
    (const Size(1200, 900), const Locale('en'), Brightness.light, 1.0),
  ]) {
    testWidgets('quote form and keyboard fit $variant', (tester) async {
      await _pumpApp(
        tester,
        provider: true,
        initialLocation: _providerQuoteLocation(),
        size: variant.$1,
        locale: variant.$2,
        brightness: variant.$3,
        textScale: variant.$4,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      await _enter(tester, 'marketplace-quote-amount', '150.25');
      await _enter(tester, 'marketplace-quote-duration', '120');
      await _enter(
        tester,
        'marketplace-quote-notes',
        'A sample note that wraps naturally. ' * 3,
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await _tap(tester, _key('marketplace-save-quote'));
      expect(tester.takeException(), isNull);
    });
  }

  test('marketplace translation keys and lifecycle labels match in English and Arabic', () {
    final en = jsonDecode(
      File('assets/translations/en.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final ar = jsonDecode(
      File('assets/translations/ar.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    Set<String> keys(Map<String, dynamic> map, [String prefix = '']) => {
      for (final entry in map.entries)
        if (entry.value is Map<String, dynamic>)
          ...keys(entry.value as Map<String, dynamic>, '$prefix${entry.key}.')
        else
          '$prefix${entry.key}',
    };
    expect(keys(en), keys(ar));
    for (final translations in [en, ar]) {
      final marketplace = translations['marketplace'] as Map<String, dynamic>;
      final jobs = marketplace['job_status'] as Map<String, dynamic>;
      final quotes = marketplace['quote_status'] as Map<String, dynamic>;
      expect(
        jobs.keys.toSet(),
        JobStatus.values.map((value) => value.wireName).toSet(),
      );
      expect(
        quotes.keys.toSet(),
        QuoteStatus.values.map((value) => value.wireName).toSet(),
      );
    }
  });
}
