import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:salahly/src/app.dart';
import 'package:salahly/src/data/models/matching.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/shared/wrappers/state_wrapper.dart';
import 'package:salahly/src/ui/marketplace/customer_quotes_page.dart';
import 'package:salahly/src/ui/matching/provider_matching_cubit.dart';
import 'package:salahly/src/ui/matching/provider_matching_settings_page.dart';
import 'package:salahly/src/ui/matching/request_matches_page.dart';
import 'package:salahly/src/ui/matching/request_matching_cubit.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'matching_ui_fakes.dart';

class _Translations extends AssetLoader {
  const _Translations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      jsonDecode(File('$path/${locale.languageCode}.json').readAsStringSync())
          as Map<String, dynamic>;
}

String _matchesLocation() =>
    AppRoutes.requestMatches.replaceFirst(':requestId', uiRequestId);
String _quotesLocation() =>
    AppRoutes.requestQuotes.replaceFirst(':requestId', uiRequestId);
Finder _key(String key) => find.byWidgetPredicate(
  (widget) => widget.key == ValueKey(key) || widget.key == PageStorageKey(key),
);
Finder _storage(String key) => find.byKey(PageStorageKey(key));
Finder _field(String key) =>
    find.descendant(of: _key(key), matching: find.byType(TextFormField));

Future<MatchingUiRepository> _pumpApp(
  WidgetTester tester, {
  DemoAuthRepository? auth,
  MatchingUiRepository? repository,
  MarketplaceUiRepository? marketplace,
  MatchingUiCatalog? catalog,
  MatchingUiPrivateProviders? providers,
  MatchingUiPrivateRequests? requests,
  String? initialLocation,
  bool provider = false,
  bool guest = false,
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
  if (!guest) {
    await account.login(
      email: provider
          ? DemoAuthRepository.marketplaceProviderEmail
          : DemoAuthRepository.customerEmail,
      password: DemoAuthRepository.demoPassword,
    );
  }
  final matching = repository ?? MatchingUiRepository(account);
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
        marketplaceRepository: marketplace ?? MarketplaceUiRepository(account),
        matchingRepository: matching,
        providerRepository: providers ?? MatchingUiPrivateProviders(account),
        serviceRequestRepository:
            requests ?? MatchingUiPrivateRequests(account),
        child: RepositoryProvider<CatalogRepository>.value(
          value: catalog ?? MatchingUiCatalog(),
          child: App(
            initialLocation:
                initialLocation ??
                (provider
                    ? AppRoutes.providerMatchingSettings
                    : _matchesLocation()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  return matching;
}

Future<void> _visible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        240,
        scrollable: scrollable,
        maxScrolls: 60,
      );
    }
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(
  WidgetTester tester,
  Finder finder, {
  bool settle = true,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await _visible(tester, finder);
  ScaffoldMessenger.maybeOf(tester.element(finder))?.removeCurrentSnackBar();
  await tester.pump();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _type(WidgetTester tester, String key, String value) async {
  await _visible(tester, _field(key));
  await tester.enterText(_field(key), value);
  await tester.pumpAndSettle();
}

Future<void> _inputs(WidgetTester tester) =>
    _tap(tester, _storage('matching-optional-inputs'));
RequestMatchingCubit _requestCubit(WidgetTester tester) => tester
    .element(find.byType(RefreshIndicator).first)
    .read<RequestMatchingCubit>();
ProviderMatchingCubit _settingsCubit(WidgetTester tester) => tester
    .element(find.byType(RefreshIndicator).first)
    .read<ProviderMatchingCubit>();

Future<void> _explain(WidgetTester tester, String providerId) async {
  final card = _key('matching-provider-$providerId');
  await _visible(tester, card);
  await _tap(
    tester,
    find.descendant(of: card, matching: find.text('matching.explain'.tr())),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'matching cold start uses blank separate inputs and no private M5 or M6 enrichment',
    (tester) async {
      final auth = DemoAuthRepository();
      final providers = MatchingUiPrivateProviders(auth);
      final requests = MatchingUiPrivateRequests(auth);
      final repository = await _pumpApp(
        tester,
        auth: auth,
        providers: providers,
        requests: requests,
      );
      expect(find.byType(RequestMatchesPage), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(providers.loads, 0);
      expect(requests.loads, 0);
      expect(find.textContaining('NEVER RENDER PRIVATE M5'), findsNothing);
      expect(find.textContaining('NEVER COPY PRIVATE REQUEST'), findsNothing);
      expect(find.textContaining('Private home address 55'), findsNothing);
      await _inputs(tester);
      for (final key in [
        'matching-query-latitude',
        'matching-query-longitude',
        'matching-query-time',
      ]) {
        expect(tester.widget<TextFormField>(_field(key)).initialValue, isEmpty);
      }
      expect(
        tester
            .widget<CheckboxListTile>(_key('matching-query-location-consent'))
            .value,
        isFalse,
      );
      expect(repository.reads.single.query.weekday, isNull);
      expect(repository.reads.single.query.hasLocation, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final provider in [false, true]) {
    testWidgets('central guards reject the other role, provider=$provider', (
      tester,
    ) async {
      final repository = await _pumpApp(
        tester,
        provider: provider,
        initialLocation: provider
            ? _matchesLocation()
            : AppRoutes.providerMatchingSettings,
      );
      expect(find.byType(RequestMatchesPage), findsNothing);
      expect(find.byType(ProviderMatchingSettingsPage), findsNothing);
      expect(repository.reads, isEmpty);
      expect(repository.profileLoads, 0);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(3));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'cold matching Back supplies request parameters to the existing quotes route',
    (tester) async {
      final auth = DemoAuthRepository();
      final quotes = MarketplaceUiRepository(auth)..book = uiBook();
      final repository = await _pumpApp(
        tester,
        auth: auth,
        marketplace: quotes,
      );
      await _tap(tester, find.byType(BackButton).first);
      expect(find.byType(CustomerQuotesPage), findsOneWidget);
      expect(find.byType(RequestMatchesPage), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(repository.reads, hasLength(1));
      expect(quotes.publications, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('guest cold start does not call matching backend', (
    tester,
  ) async {
    final repository = await _pumpApp(tester, guest: true);
    expect(repository.reads, isEmpty);
    expect(find.byType(RequestMatchesPage), findsNothing);
    expect(find.byType(ProviderMatchingSettingsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('malformed request ID is rejected before a candidate read', (
    tester,
  ) async {
    final repository = await _pumpApp(
      tester,
      initialLocation: AppRoutes.requestMatches.replaceFirst(
        ':requestId',
        'not-a-request',
      ),
    );
    expect(repository.reads, isEmpty);
    expect(find.text('matching.errors.not_found'.tr()), findsWidgets);
    expect(find.text('Synthetic Matching Provider'), findsNothing);
  });

  testWidgets(
    'quotes publication is required before the matching entry appears',
    (tester) async {
      final auth = DemoAuthRepository();
      final quotes = MarketplaceUiRepository(auth)
        ..book = uiBook(published: false);
      final repository = await _pumpApp(
        tester,
        auth: auth,
        marketplace: quotes,
        initialLocation: _quotesLocation(),
      );
      expect(_key('matching-open-request-matches'), findsNothing);
      expect(repository.reads, isEmpty);
      await _type(
        tester,
        'marketplace-public-summary',
        'A broad, explicitly reviewed public summary.',
      );
      await _type(tester, 'marketplace-public-city', 'Cairo');
      await _tap(tester, _key('marketplace-publish-consent'));
      await _tap(tester, _key('marketplace-publish'));
      await _tap(tester, _key('matching-open-request-matches'));
      expect(quotes.publications, hasLength(1));
      expect(find.byType(RequestMatchesPage), findsOneWidget);
      expect(repository.reads.single.query.hasLocation, isFalse);
      expect(find.byType(NavigationBar), findsNothing);
    },
  );

  testWidgets(
    'unpublished matching query keeps publication explicit and links to existing quotes',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MatchingUiRepository(auth)
        ..readFailure = const ServerFailure('matching.errors.unpublished');
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        marketplace: MarketplaceUiRepository(auth)
          ..book = uiBook(published: false),
      );
      expect(find.text('matching.errors.unpublished'.tr()), findsWidgets);
      expect(find.text('Synthetic Matching Provider'), findsNothing);
      await _tap(tester, _key('matching-open-quotes'));
      expect(find.byType(CustomerQuotesPage), findsOneWidget);
      expect(find.byType(RequestMatchesPage), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
    },
  );

  testWidgets('profile matching entry keeps the three-tab shell unchanged', (
    tester,
  ) async {
    await _pumpApp(tester, provider: true, initialLocation: AppRoutes.profile);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
      hasLength(3),
    );
    await _tap(tester, _key('matching-open-provider-settings'));
    expect(find.byType(ProviderMatchingSettingsPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'manual point requires consent and an edit revokes the previous confirmation',
    (tester) async {
      final repository = await _pumpApp(tester);
      await _inputs(tester);
      await _type(tester, 'matching-query-latitude', '30.04');
      await _type(tester, 'matching-query-longitude', '31.20');
      await _tap(tester, _key('matching-apply-inputs'));
      expect(repository.reads, hasLength(1));
      expect(find.text('matching.errors.consent'.tr()), findsWidgets);
      await _tap(tester, _key('matching-query-location-consent'));
      await _tap(tester, _key('matching-apply-inputs'));
      expect(repository.reads.last.query.parsedLatitude, 30.04);
      expect(repository.reads.last.query.parsedLongitude, 31.20);
      await _type(tester, 'matching-query-longitude', '31.21');
      expect(
        tester
            .widget<CheckboxListTile>(_key('matching-query-location-consent'))
            .value,
        isFalse,
      );
      await _tap(tester, _key('matching-clear-inputs'));
      await _visible(tester, _field('matching-query-latitude'));
      expect(
        tester
            .widget<TextFormField>(_field('matching-query-latitude'))
            .initialValue,
        isEmpty,
      );
      expect(repository.reads.last.query.hasLocation, isFalse);
    },
  );

  testWidgets(
    'missing factors show neutral values, coverage and no fabricated ratings or distance',
    (tester) async {
      await _pumpApp(tester);
      await _explain(tester, uiProviderId);
      final card = _key('matching-provider-$uiProviderId');
      expect(
        find.descendant(
          of: card,
          matching: find.text(
            'matching.total_value'.tr(namedArgs: {'score': '50'}),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(
            'matching.evidence_value'.tr(namedArgs: {'evidence': '0'}),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(
            'matching.factor_neutral'.tr(namedArgs: {'neutral': '50'}),
          ),
        ),
        findsNWidgets(4),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('matching.distance_unavailable'.tr()),
        ),
        findsOneWidget,
      );
      final texts = tester
          .widgetList<Text>(
            find.descendant(of: card, matching: find.byType(Text)),
          )
          .map((text) => text.data ?? '')
          .join(' ');
      expect(RegExp(r'\d+(?:\.\d+)? km').hasMatch(texts), isFalse);
      expect(find.byIcon(Icons.star), findsNothing);
      expect(find.text('matching.not_a_quote'.tr()), findsOneWidget);
    },
  );

  testWidgets(
    'explicit zero experience is measured zero, not unavailable neutral evidence',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MatchingUiRepository(auth)
        ..results = matchingResults(items: [matchingCandidate(years: 0)]);
      await _pumpApp(tester, auth: auth, repository: repository);
      await _explain(tester, uiProviderId);
      final factor = _key('matching-factor-$uiProviderId-experience');
      expect(
        find.descendant(
          of: factor,
          matching: find.text(
            'matching.factor_neutral'.tr(namedArgs: {'neutral': '50'}),
          ),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: factor,
          matching: find.text(
            'matching.experience_value'.tr(namedArgs: {'years': '0'}),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.text('matching.evidence_value'.tr(namedArgs: {'evidence': '20'})),
        findsOneWidget,
      );
      expect(
        find.text('matching.total_value'.tr(namedArgs: {'score': '40'})),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'non100 server weights explain normalized shares and contributions without editing controls',
    (tester) async {
      final auth = DemoAuthRepository();
      const rules = MatchingRules(
        revision: 3,
        distanceWeight: 70,
        ratingWeight: 50,
        availabilityWeight: 40,
        experienceWeight: 40,
      );
      final repository = MatchingUiRepository(auth)
        ..results = matchingResults(rules: rules);
      await _pumpApp(tester, auth: auth, repository: repository);
      await _tap(tester, _storage('matching-rules-explanation'));
      expect(
        find.text(
          'matching.rule_weight'.tr(
            namedArgs: {
              'factor': 'matching.factors.distance'.tr(),
              'weight': '70',
              'total': '200',
              'share': '35',
            },
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _storage('matching-rules-explanation'),
          matching: find.byType(EditableText),
        ),
        findsNothing,
      );
      await _explain(tester, uiProviderId);
      expect(
        find.text(
          'matching.factor_numbers'.tr(
            namedArgs: {
              'score': '50',
              'weight': '70',
              'total': '200',
              'contribution': '17.5',
            },
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'all eligible includes low and missing signals in trusted deterministic order',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MatchingUiRepository(auth);
      repository.onMatches = (query, before) async {
        final items =
            [
              matchingCandidate(
                providerId: 'zero-years',
                name: 'Synthetic Zulu',
                years: 0,
                query: query,
              ),
              matchingCandidate(
                providerId: 'missing-all',
                name: 'Synthetic Alpha',
                query: query,
              ),
              matchingCandidate(
                providerId: 'experienced',
                name: 'Synthetic Middle',
                years: 10,
                query: query,
              ),
            ]..sort(
              (left, right) => compareProviderMatches(left, right, query.mode),
            );
        return right(matchingResults(query: query, items: items));
      };
      await _pumpApp(tester, auth: auth, repository: repository);
      await _tap(tester, _key('matching-mode-all_eligible'));
      final state = _requestCubit(tester).state;
      expect(state.results!.mode, MatchMode.allEligible);
      expect(state.results!.items, hasLength(3));
      expect(state.results!.items.map((item) => item.providerId).toSet(), {
        'zero-years',
        'missing-all',
        'experienced',
      });
      expect(find.text('matching.all_note'.tr()), findsWidgets);
      await _visible(tester, _key('matching-provider-zero-years'));
      expect(find.text('Synthetic Zulu'), findsOneWidget);
      expect(repository.reads.last.before, isNull);
    },
  );

  testWidgets(
    'failed mode query retains old rows and explicit retry applies the requested mode',
    (tester) async {
      final auth = DemoAuthRepository();
      var failAll = true;
      final repository = MatchingUiRepository(auth)
        ..onMatches = (query, before) async =>
            query.mode == MatchMode.allEligible && failAll
            ? left(const ServerFailure('matching.errors.load_failed'))
            : right(matchingResults(query: query));
      await _pumpApp(tester, auth: auth, repository: repository);
      await _tap(tester, _key('matching-mode-all_eligible'));
      expect(_requestCubit(tester).state.results!.mode, MatchMode.recommended);
      expect(_requestCubit(tester).state.showingPrevious, isTrue);
      expect(_requestCubit(tester).state.canLoadMore, isFalse);
      failAll = false;
      await _tap(tester, _key('matching-retry-load'));
      expect(repository.reads.last.query.mode, MatchMode.allEligible);
      expect(repository.reads.last.before, isNull);
      expect(_requestCubit(tester).state.results!.mode, MatchMode.allEligible);
      expect(_requestCubit(tester).state.hasUnappliedChanges, isFalse);
    },
  );

  testWidgets(
    '20-row list loads more with stable IDs and exact query-bound cursor',
    (tester) async {
      final auth = DemoAuthRepository();
      final pool = matchingCandidates(21);
      final repository = MatchingUiRepository(auth)
        ..onMatches = (query, before) async => right(
          matchingResults(
            query: query,
            items: before == null ? pool.take(20).toList() : [pool.last],
            hasMore: before == null,
          ),
        );
      await _pumpApp(tester, auth: auth, repository: repository);
      await _tap(tester, _key('matching-load-more'));
      expect(repository.reads.last.limit, 20);
      expect(
        repository.reads.last.before!.queryKey,
        repository.reads.last.query.cursorKey,
      );
      expect(repository.reads.last.before!.providerId, pool[19].providerId);
      expect(_requestCubit(tester).state.results!.items, pool);
      await _visible(tester, _key('matching-provider-${pool.last.providerId}'));
      expect(_key('matching-provider-${pool.last.providerId}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inline refresh retains scroll and visible rows on a read error',
    (tester) async {
      final repository = await _pumpApp(tester);
      await _visible(tester, _key('matching-provider-$uiProviderId'));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final offset = position.pixels;
      final previous = _requestCubit(tester).state.results;
      repository.pendingMatches = Completer();
      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump();
      expect(position.pixels, offset);
      expect(find.text('Synthetic Matching Provider'), findsOneWidget);
      repository.pendingMatches!.complete(
        left(const NetworkFailure('errors.network')),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, offset);
      expect(_requestCubit(tester).state.results, same(previous));
      expect(find.text('Synthetic Matching Provider'), findsOneWidget);
    },
  );

  testWidgets(
    'changed pagination configuration retains old rows until a clean first-page restart',
    (tester) async {
      final auth = DemoAuthRepository();
      final pool = matchingCandidates(20);
      const rules = MatchingRules(revision: 2);
      final fresh = matchingCandidate(
        providerId: 'fresh-config-provider',
        name: 'Synthetic Fresh Configuration',
        rules: rules,
      );
      final restart = Completer<Either<Failure, MatchResults>>();
      final repository = MatchingUiRepository(auth);
      repository.onMatches = (query, before) async {
        if (repository.reads.length == 1) {
          return right(
            matchingResults(query: query, items: pool, hasMore: true),
          );
        }
        if (before != null) {
          return right(
            matchingResults(query: query, rules: rules, items: [fresh]),
          );
        }
        return restart.future;
      };
      await _pumpApp(tester, auth: auth, repository: repository);
      await _tap(tester, _key('matching-load-more'), settle: false);
      final pending = _requestCubit(tester).state;
      expect(pending.operation, MatchingOperation.loading);
      expect(pending.stale, isTrue);
      expect(pending.results!.items, pool);
      expect(pending.results!.rules.revision, 1);
      expect(pending.canLoadMore, isFalse);
      expect(repository.reads, hasLength(3));
      expect(repository.reads.last.before, isNull);
      restart.complete(right(matchingResults(rules: rules, items: [fresh])));
      await tester.pumpAndSettle();
      expect(_requestCubit(tester).state.results!.rules.revision, 2);
      expect(_requestCubit(tester).state.results!.items, [fresh]);
      await _visible(tester, _key('matching-provider-fresh-config-provider'));
      expect(find.text('Synthetic Fresh Configuration'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'foreground stale-page timer refreshes current server rules automatically',
    (tester) async {
      final repository = await _pumpApp(tester);
      repository.results = matchingResults(
        rules: const MatchingRules(revision: 2),
      );
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(repository.reads, hasLength(2));
      expect(_requestCubit(tester).state.results!.rules.revision, 2);
      expect(_requestCubit(tester).state.stale, isFalse);
    },
  );

  testWidgets(
    'return from quotes and app resume refresh matching configuration',
    (tester) async {
      final repository = await _pumpApp(tester);
      await _tap(tester, _key('matching-open-quotes'));
      expect(find.byType(CustomerQuotesPage), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(repository.reads, hasLength(1));
      await _tap(tester, find.byType(BackButton).first);
      expect(find.byType(RequestMatchesPage), findsOneWidget);
      expect(repository.reads, hasLength(2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(repository.reads, hasLength(3));
    },
  );

  testWidgets(
    'provider settings never render private M5 details and consent is explicit and fresh',
    (tester) async {
      final auth = DemoAuthRepository();
      final providers = MatchingUiPrivateProviders(auth);
      final repository = await _pumpApp(
        tester,
        auth: auth,
        provider: true,
        providers: providers,
      );
      expect(providers.loads, 0);
      expect(find.textContaining('NEVER RENDER PRIVATE M5'), findsNothing);
      expect(find.textContaining('Private home address 55'), findsNothing);
      await _visible(tester, _field('matching-provider-latitude'));
      expect(
        tester
            .widget<TextFormField>(_field('matching-provider-latitude'))
            .initialValue,
        isEmpty,
      );
      expect(_key('matching-provider-consent'), findsNothing);
      await _tap(tester, _key('matching-discoverable'));
      await _tap(tester, _key('matching-save-settings'));
      expect(repository.drafts, isEmpty);
      expect(find.text('matching.errors.consent'.tr()), findsWidgets);
      await _type(tester, 'matching-provider-latitude', '30.04');
      await _type(tester, 'matching-provider-longitude', '31.20');
      await _type(tester, 'matching-experience-demo-plumbing', '4');
      await auth.updateProfile(name: 'Current Matching Name');
      repository.currentName = 'Current Matching Name';
      await tester.pumpAndSettle();
      await _visible(tester, _key('matching-provider-consent'));
      expect(
        find.text(
          'matching.name_to_share'.tr(
            namedArgs: {'name': 'Current Matching Name'},
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('matching.settings_disclosure'.tr()), findsOneWidget);
      await _tap(tester, _key('matching-provider-consent'));
      await _type(tester, 'matching-experience-demo-plumbing', '5');
      await _visible(tester, _key('matching-provider-consent'));
      expect(
        tester
            .widget<CheckboxListTile>(_key('matching-provider-consent'))
            .value,
        isFalse,
      );
      await _tap(tester, _key('matching-provider-consent'));
      await _tap(tester, _key('matching-save-settings'));
      expect(repository.profile.providerName, 'Current Matching Name');
      expect(repository.profile.experienceYears, {'demo-plumbing': 5});
      expect(repository.profile.discoverable, isTrue);
    },
  );

  testWidgets(
    'pending provider cannot enable discovery but may save optional origin privately',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MatchingUiRepository(auth)
        ..eligibility = MatchingEligibility(
          skillIds: const ['demo-plumbing'],
          eligible: false,
        );
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        provider: true,
      );
      await _visible(tester, _key('matching-discoverable'));
      expect(
        tester
            .widget<CheckboxListTile>(_key('matching-discoverable'))
            .onChanged,
        isNull,
      );
      await _type(tester, 'matching-provider-latitude', '30.04');
      await _type(tester, 'matching-provider-longitude', '31.20');
      await _tap(tester, _key('matching-save-settings'));
      expect(repository.drafts.single.consent, isFalse);
      expect(repository.profile.discoverable, isFalse);
      expect(repository.profile.latitude, 30.04);
      expect(_key('matching-provider-consent'), findsNothing);
    },
  );

  testWidgets(
    'settings survive service/catalog failure and retry checks without inventing approval',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MatchingUiRepository(auth)
        ..profile = matchingProfile(
          latitude: 30.04,
          longitude: 31.20,
          revision: 1,
        )
        ..eligibilityFailure = const NetworkFailure('errors.network');
      final catalog = MatchingUiCatalog()
        ..failure = const NetworkFailure('errors.network');
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        catalog: catalog,
        provider: true,
      );
      await _visible(tester, _field('matching-provider-latitude'));
      expect(
        tester
            .widget<TextFormField>(_field('matching-provider-latitude'))
            .initialValue,
        '30.04',
      );
      expect(_settingsCubit(tester).state.canEnableDiscovery, isFalse);
      repository.eligibilityFailure = null;
      catalog.failure = null;
      await _tap(tester, _key('matching-retry-metadata'));
      expect(catalog.loads, 2);
      expect(_settingsCubit(tester).state.canEnableDiscovery, isTrue);
    },
  );

  testWidgets(
    'only current selected service experience is editable and old entries are removable',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MatchingUiRepository(auth)
        ..profile = matchingProfile(
          years: const {'demo-plumbing': 4, 'demo-electrical': 9},
          revision: 1,
        );
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        provider: true,
      );
      await _visible(tester, _field('matching-experience-demo-plumbing'));
      expect(_field('matching-experience-demo-electrical'), findsNothing);
      await _tap(tester, _key('matching-remove-experience-demo-electrical'));
      await _tap(tester, _key('matching-save-settings'));
      expect(repository.profile.experienceYears, {'demo-plumbing': 4});
    },
  );

  testWidgets(
    'dirty exit confirms staying or discard without changing saved preferences',
    (tester) async {
      final repository = await _pumpApp(tester, provider: true);
      final origin = _settingsCubit(tester);
      await _type(tester, 'matching-provider-latitude', '30.04');
      await _tap(tester, find.byType(BackButton).first);
      expect(find.text('matching.discard_title'.tr()), findsOneWidget);
      await _tap(tester, find.text('matching.keep_editing'.tr()));
      expect(find.byType(ProviderMatchingSettingsPage), findsOneWidget);
      expect(origin.state.draft.latitude, '30.04');
      expect(origin.state.hasUnsavedChanges, isTrue);
      await _tap(tester, find.byType(BackButton).first);
      expect(find.text('matching.discard_title'.tr()), findsOneWidget);
      await _tap(tester, find.text('matching.discard'.tr()));
      expect(find.byType(ProviderMatchingSettingsPage), findsNothing);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
        hasLength(3),
      );
      expect(repository.drafts, isEmpty);
      expect(repository.profile.latitude, isNull);
    },
  );

  testWidgets(
    'unresolved save freezes controls and retries its original immutable intent',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MatchingUiRepository(auth)
        ..saveFailure = const ServerFailure('matching.errors.uncertain');
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        provider: true,
      );
      await _type(tester, 'matching-provider-latitude', '30.04');
      await _type(tester, 'matching-provider-longitude', '31.20');
      await _tap(tester, _key('matching-save-settings'));
      final original = repository.drafts.single;
      await _visible(tester, _field('matching-provider-latitude'));
      expect(
        tester
            .widget<TextFormField>(_field('matching-provider-latitude'))
            .enabled,
        isFalse,
      );
      await _tap(tester, find.byType(BackButton).first);
      expect(find.byType(ProviderMatchingSettingsPage), findsOneWidget);
      await _tap(tester, _key('matching-retry-original'));
      expect(repository.retries.single, same(original));
      expect(repository.drafts, hasLength(1));
      expect(repository.profile.latitude, 30.04);
      expect(_settingsCubit(tester).state.uncertain, isFalse);
    },
  );

  testWidgets(
    'reopened unresolved settings retry repository intent rather than fresh blank fields',
    (tester) async {
      final auth = DemoAuthRepository();
      final original = ProviderMatchingDraft(
        providerId: uiProviderId,
        latitude: '30.04',
        longitude: '31.20',
      );
      final repository = MatchingUiRepository(auth)
        ..storedPending = true
        ..retainedDraft = original;
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        provider: true,
      );
      expect(_settingsCubit(tester).state.canEdit, isFalse);
      expect(_settingsCubit(tester).state.draft.latitude, isEmpty);
      await _tap(tester, _key('matching-retry-original'));
      expect(repository.drafts, isEmpty);
      expect(repository.retries.single, same(original));
      expect(repository.profile.latitude, 30.04);
    },
  );

  testWidgets(
    'same-account session replacement hides an open discovery dialog permanently',
    (tester) async {
      final auth = DemoAuthRepository();
      await _pumpApp(tester, auth: auth, provider: true);
      final origin = _settingsCubit(tester);
      await _type(tester, 'matching-provider-latitude', '30.04');
      await _tap(tester, find.byType(BackButton).first);
      expect(find.text('matching.discard_title'.tr()), findsOneWidget);
      await auth.logout();
      await tester.pump();
      await auth.login(
        email: DemoAuthRepository.marketplaceProviderEmail,
        password: DemoAuthRepository.demoPassword,
      );
      await tester.pumpAndSettle();
      expect(find.text('matching.discard_title'.tr()), findsNothing);
      expect(origin.state.revoked, isTrue);
      expect(_key('matching-provider-latitude'), findsNothing);
      expect(_key('matching-discoverable'), findsNothing);
      expect(find.text('30.04'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late customer response cannot revive matching after same-account replacement',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = await _pumpApp(tester, auth: auth);
      final late = Completer<Either<Failure, MatchResults>>();
      repository.pendingMatches = late;
      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump();
      await auth.logout();
      await tester.pumpAndSettle();
      late.complete(right(matchingResults()));
      await tester.pumpAndSettle();
      await auth.login(
        email: DemoAuthRepository.customerEmail,
        password: DemoAuthRepository.demoPassword,
      );
      await tester.pumpAndSettle();
      expect(find.byType(RequestMatchesPage), findsNothing);
      expect(find.text('Synthetic Matching Provider'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late provider save cannot revive a closed session or show a success message',
    (tester) async {
      final auth = DemoAuthRepository();
      final repository = MatchingUiRepository(auth)..pendingSave = Completer();
      await _pumpApp(
        tester,
        auth: auth,
        repository: repository,
        provider: true,
      );
      await _type(tester, 'matching-provider-latitude', '30.04');
      await _type(tester, 'matching-provider-longitude', '31.20');
      await _tap(tester, _key('matching-save-settings'), settle: false);
      final original = repository.drafts.single;
      await auth.logout();
      await tester.pumpAndSettle();
      repository.pendingSave!.complete(right(repository.saved(original)));
      await tester.pumpAndSettle();
      await auth.login(
        email: DemoAuthRepository.marketplaceProviderEmail,
        password: DemoAuthRepository.demoPassword,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProviderMatchingSettingsPage), findsNothing);
      expect(find.text('matching.settings_saved_private'.tr()), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final provider in [false, true]) {
    for (final width in [320.0, 1200.0]) {
      testWidgets(
        'Arabic dark large text, keyboard and max-width layout, provider=$provider width=$width',
        (tester) async {
          final repository = await _pumpApp(
            tester,
            provider: provider,
            locale: const Locale('ar'),
            brightness: Brightness.dark,
            textScale: 2,
            size: Size(width, 1000),
          );
          expect(
            tester.getSize(find.byType(ListView).first).width,
            lessThanOrEqualTo(760),
          );
          expect(
            Theme.of(tester.element(find.byType(RefreshIndicator).first))
                .brightness,
            Brightness.dark,
          );
          if (provider) {
            await _type(
              tester,
              'matching-provider-latitude',
              '\u0663\u0660\u066b\u0660\u0664',
            );
            await _type(
              tester,
              'matching-provider-longitude',
              '\u0663\u0661\u066b\u0662\u0660',
            );
            await _type(tester, 'matching-experience-demo-plumbing', '\u0660');
            tester.view.viewInsets = const FakeViewPadding(bottom: 240);
            await tester.pump();
            await _tap(tester, _key('matching-discoverable'));
            await _tap(tester, _key('matching-provider-consent'));
            await _tap(tester, _key('matching-save-settings'));
            expect(repository.profile.latitude, 30.04);
            expect(repository.profile.longitude, 31.20);
            expect(repository.profile.experienceYears, {'demo-plumbing': 0});
          } else {
            await _inputs(tester);
            await _type(
              tester,
              'matching-query-latitude',
              '\u0663\u0660\u066b\u0660\u0664',
            );
            await _type(
              tester,
              'matching-query-longitude',
              '\u0663\u0661\u066b\u0662\u0660',
            );
            await _tap(tester, _key('matching-query-location-consent'));
            await _tap(tester, _key('matching-query-weekday'));
            await _tap(tester, find.text('provider.days.1'.tr()).last);
            await _type(
              tester,
              'matching-query-time',
              '\u0661\u0664:\u0663\u0660',
            );
            tester.view.viewInsets = const FakeViewPadding(bottom: 240);
            await tester.pump();
            await _tap(tester, _key('matching-apply-inputs'));
            expect(repository.reads.last.query.parsedLatitude, 30.04);
            expect(repository.reads.last.query.parsedLongitude, 31.20);
            expect(repository.reads.last.query.minute, 870);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  test(
    'matching localization has English/Arabic key and placeholder parity',
    () {
      final en =
          (jsonDecode(File('assets/translations/en.json').readAsStringSync())
                  as Map<String, dynamic>)['matching']
              as Map<String, dynamic>;
      final ar =
          (jsonDecode(File('assets/translations/ar.json').readAsStringSync())
                  as Map<String, dynamic>)['matching']
              as Map<String, dynamic>;
      Map<String, String> flatten(
        Map<String, dynamic> values, [
        String prefix = '',
      ]) => {
        for (final entry in values.entries)
          if (entry.value is Map<String, dynamic>)
            ...flatten(
              entry.value as Map<String, dynamic>,
              '$prefix${entry.key}.',
            )
          else
            '$prefix${entry.key}': entry.value as String,
      };
      final english = flatten(en);
      final arabic = flatten(ar);
      expect(english.keys.toSet(), arabic.keys.toSet());
      for (final key in english.keys) {
        final placeholder = RegExp(r'\{\w+\}');
        expect(
          placeholder
              .allMatches(english[key]!)
              .map((match) => match.group(0))
              .toSet(),
          placeholder
              .allMatches(arabic[key]!)
              .map((match) => match.group(0))
              .toSet(),
          reason: key,
        );
        expect(arabic[key]!.trim(), isNotEmpty);
      }
    },
  );
}
