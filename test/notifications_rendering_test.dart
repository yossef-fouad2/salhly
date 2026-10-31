import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:salahly/src/data/models/app_notification.dart';
import 'package:salahly/src/data/models/auth_session.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/notifications_repository.dart';
import 'package:salahly/src/shared/widgets/app_button.dart';
import 'package:salahly/src/shared/widgets/app_empty_state.dart';
import 'package:salahly/src/shared/widgets/app_loading.dart';
import 'package:salahly/src/shared/wrappers/screen_util_wrapper.dart';
import 'package:salahly/src/theme/theme.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';
import 'package:salahly/src/ui/notifications/notifications_cubit.dart';
import 'package:salahly/src/ui/notifications/notifications_page.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alice = AppUser(id: 'alice', email: 'alice@example.com', name: 'Alice');
const _bob = AppUser(id: 'bob', email: 'bob@example.com', name: 'Bob');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('1000 keyed rows are constructed lazily and scroll on demand', (
    tester,
  ) async {
    final builds = <String, int>{};
    final repository = _InboxRepository(_inbox(builds: builds));
    await _pumpInbox(tester, repository);

    // Counting mounted cards alone also passes with ListView(children: ...).
    // The builder delegate verifies that row widget construction is lazy too.
    final delegate = tester
        .widget<ListView>(find.byType(ListView))
        .childrenDelegate;
    expect(delegate, isA<SliverChildBuilderDelegate>());
    expect((delegate as SliverChildBuilderDelegate).childCount, 1000);
    expect(builds.length, inInclusiveRange(1, 12));
    expect(find.byType(Card).evaluate().length, inInclusiveRange(1, 12));
    expect(tester.widget(_row(0)), isA<Padding>());
    expect(_row(999), findsNothing);

    await tester.scrollUntilVisible(
      find.text('alice notification 30'),
      600,
      scrollable: find.byType(Scrollable),
      maxScrolls: 30,
    );
    await tester.pumpAndSettle();

    expect(_row(30), findsOneWidget);
    expect(_row(0), findsNothing);
    expect(_row(999), findsNothing);
    expect(builds, contains('alice-30'));
    expect(builds.length, lessThan(50));
    expect(find.byType(Card).evaluate().length, inInclusiveRange(1, 12));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'delayed refresh and failure retain rows, keys and scroll position',
    (tester) async {
      final repository = _InboxRepository(_inbox());
      await _pumpInbox(tester, repository);
      await tester.scrollUntilVisible(
        find.text('alice notification 15'),
        600,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      final offset = scrollable.position.pixels;
      final row = tester.element(_row(15));
      expect(offset, greaterThan(0));

      for (final failRefresh in [false, true]) {
        final pending = Completer<Either<Failure, List<AppNotification>>>();
        repository.nextLoad = pending.future;
        final refresh = tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        expect(repository.loadedUserIds.length, failRefresh ? 3 : 2);
        expect(find.byType(AppLoading), findsNothing);
        expect(find.byType(AppEmptyState), findsNothing);
        expect(tester.element(_row(15)), same(row));
        expect(scrollable.position.pixels, offset);

        pending.complete(
          failRefresh
              ? const Left(ServerFailure('errors.request_failed'))
              : Right(repository.items),
        );
        await tester.pumpAndSettle();
        await refresh;

        expect(
          tester.state<ScrollableState>(find.byType(Scrollable)),
          same(scrollable),
        );
        expect(tester.element(_row(15)), same(row));
        expect(scrollable.position.pixels, offset);
        expect(find.byType(AppEmptyState), findsNothing);
      }

      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('errors.request_failed'.tr()),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mark read changes only its item with bounded nearby rebuilds', (
    tester,
  ) async {
    final builds = <String, int>{};
    final repository = _InboxRepository(_inbox(builds: builds));
    await _pumpInbox(tester, repository);
    final row = tester.element(_row(0));
    final beforeBuilds = builds.values.fold(0, (sum, count) => sum + count);
    final pending = Completer<Either<Failure, void>>();
    repository.nextRead = pending.future;

    await tester.tap(_button(0));
    await tester.pump();
    expect(repository.markedIds, [('alice', 'alice-0')]);
    expect(tester.widget<AppButton>(_button(0)).isLoading, isTrue);
    expect(tester.widget<AppButton>(_button(1)).isLoading, isFalse);
    expect(
      find.descendant(of: _row(1), matching: find.text('Unread')),
      findsOneWidget,
    );

    pending.complete(const Right(null));
    await tester.pumpAndSettle();

    expect(tester.element(_row(0)), same(row));
    expect(_button(0), findsNothing);
    expect(
      find.descendant(of: _row(0), matching: find.text('Read')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row(1), matching: find.text('Unread')),
      findsOneWidget,
    );
    expect(repository.items.first.isRead, isTrue);
    expect(repository.items.skip(1).every((item) => !item.isRead), isTrue);
    expect(builds.length, lessThanOrEqualTo(12));
    final afterBuilds = builds.values.fold(0, (sum, count) => sum + count);
    expect(afterBuilds - beforeBuilds, lessThan(30));

    await tester.scrollUntilVisible(
      find.text('alice notification 20'),
      600,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    expect(_row(0), findsNothing);
    await tester.scrollUntilVisible(
      find.text('alice notification 0'),
      -600,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _row(0), matching: find.text('Read')),
      findsOneWidget,
    );
    expect(_button(0), findsNothing);

    tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(repository.loadedUserIds, ['alice', 'alice']);
    expect(
      find.descendant(of: _row(0), matching: find.text('Read')),
      findsOneWidget,
    );
    expect(repository.markedIds, [('alice', 'alice-0')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mark read failure keeps unread data and existing error feedback',
    (tester) async {
      final repository = _InboxRepository(_inbox());
      await _pumpInbox(tester, repository);
      repository.nextRead = Future.value(
        const Left(ServerFailure('errors.request_failed')),
      );
      await tester.tap(_button(0));
      await tester.pumpAndSettle();

      expect(tester.widget<AppButton>(_button(0)).isLoading, isFalse);
      expect(
        find.descendant(of: _row(0), matching: find.text('Unread')),
        findsOneWidget,
      );
      expect(repository.items.every((item) => !item.isRead), isTrue);
      expect(find.byType(AppEmptyState), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('errors.request_failed'.tr()),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'initial loading, failure, retry and empty pull-to-refresh remain',
    (tester) async {
      final pending = Completer<Either<Failure, List<AppNotification>>>();
      final repository = _InboxRepository([])..nextLoad = pending.future;
      await _pumpInbox(tester, repository, settle: false);
      expect(find.byType(AppLoading), findsOneWidget);

      pending.complete(const Left(ServerFailure('errors.request_failed')));
      await tester.pumpAndSettle();
      expect(find.byType(AppEmptyState), findsOneWidget);
      expect(find.text('common.retry'.tr()), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.text('common.retry'.tr()));
      await tester.pumpAndSettle();
      expect(find.text('notifications.empty_title'.tr()), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(repository.loadedUserIds, ['alice', 'alice', 'alice']);
      expect(find.text('notifications.empty_title'.tr()), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching users replaces the inbox and ignores an old refresh', (
    tester,
  ) async {
    final repository = _InboxRepository([
      ..._inbox(),
      ..._inbox(userId: 'bob', count: 2),
    ]);
    final session = await _pumpInbox(tester, repository);
    final oldCubit = tester
        .element(find.byType(RefreshIndicator))
        .read<NotificationsCubit>();
    final pending = Completer<Either<Failure, List<AppNotification>>>();
    repository.nextLoad = pending.future;
    final refresh = oldCubit.load();
    await tester.pump();

    session.add(const SessionUserChanged(AuthSession(user: _bob)));
    await tester.pumpAndSettle();
    expect(oldCubit.isClosed, isTrue);
    expect(find.text('bob notification 0'), findsOneWidget);
    expect(find.text('alice notification 0'), findsNothing);

    pending.complete(Right(_inbox()));
    await refresh;
    await tester.pumpAndSettle();
    expect(repository.loadedUserIds, ['alice', 'alice', 'bob']);
    expect(find.text('bob notification 0'), findsOneWidget);
    expect(find.text('alice notification 0'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Finder _row(int index) => find.byKey(ValueKey('alice-$index'));

Finder _button(int index) =>
    find.descendant(of: _row(index), matching: find.byType(AppButton));

Future<SessionBloc> _pumpInbox(
  WidgetTester tester,
  _InboxRepository repository, {
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = DemoAuthRepository();
  final session = SessionBloc(repository: auth)
    ..add(const SessionUserChanged(AuthSession(user: _alice)));
  addTearDown(() async {
    await session.close();
    await auth.dispose();
  });

  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ar')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      assetLoader: const _TestTranslations(),
      child: RepositoryProvider<NotificationsRepository>.value(
        value: repository,
        child: BlocProvider<SessionBloc>.value(
          value: session,
          child: ScreenUtilWrapper(
            builder: (context) => MaterialApp(
              theme: buildLightTheme(primaryColorHex: '#FFFFFF'),
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
              home: const Scaffold(body: NotificationsPage()),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  return session;
}

class _TestTranslations extends AssetLoader {
  const _TestTranslations();

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return jsonDecode(
      File('$path/${locale.languageCode}.json').readAsStringSync(),
    ) as Map<String, dynamic>;
  }
}

List<AppNotification> _inbox({
  String userId = 'alice',
  int count = 1000,
  Map<String, int>? builds,
}) => List<AppNotification>.unmodifiable([
  for (var index = 0; index < count; index++)
    _TrackedNotification(index, userId: userId, builds: builds),
]);

class _TrackedNotification extends AppNotification {
  _TrackedNotification(int index, {required super.userId, this.builds})
    : super(
        id: '$userId-$index',
        titleEn: '$userId notification $index',
        titleAr: '$userId notification $index (ar)',
        bodyEn: 'Synthetic inbox message.',
        bodyAr: 'Synthetic inbox message (ar).',
        createdAt: DateTime.utc(
          2026,
          10,
          17,
        ).subtract(Duration(minutes: index)),
      );

  final Map<String, int>? builds;

  @override
  String title(String languageCode) {
    builds?.update(id, (count) => count + 1, ifAbsent: () => 1);
    return super.title(languageCode);
  }
}

class _InboxRepository extends NotificationsRepository {
  _InboxRepository(this.items);

  List<AppNotification> items;
  final loadedUserIds = <String>[];
  final markedIds = <(String, String)>[];
  FutureEither<List<AppNotification>>? nextLoad;
  FutureEither<void>? nextRead;

  @override
  FutureEither<List<AppNotification>> loadNotifications(String userId) async {
    loadedUserIds.add(userId);
    final pending = nextLoad;
    nextLoad = null;
    if (pending != null) return pending;
    return Right(
      List.unmodifiable(items.where((item) => item.userId == userId)),
    );
  }

  @override
  FutureEither<void> markRead({
    required String userId,
    required String notificationId,
  }) async {
    markedIds.add((userId, notificationId));
    final pending = nextRead;
    nextRead = null;
    final result = pending == null
        ? const Right<Failure, void>(null)
        : await pending;
    if (result.isRight()) {
      items = List.unmodifiable([
        for (final item in items)
          if (item.userId == userId && item.id == notificationId)
            item.withReadAt(DateTime.utc(2026, 10, 17, 12))
          else
            item,
      ]);
    }
    return result;
  }
}
