import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:salahly/src/data/models/app_notification.dart';
import 'package:salahly/src/data/repositories/notifications_repository.dart';

void main() {
  late NotificationsRepository repository;

  setUp(() => repository = NotificationsRepository());

  test('demo inbox is bilingual, owned and newest first', () async {
    final notifications = await _load(repository, 'alice');
    expect(repository.isDemo, isTrue);
    expect(notifications, isNotEmpty);
    expect(
      notifications.map((item) => item.id).toSet(),
      hasLength(notifications.length),
    );
    for (final item in notifications) {
      expect(item.userId, 'alice');
      expect(item.id, startsWith('demo-'));
      expect(item.title('en'), isNotEmpty);
      expect(item.title('ar'), isNot(item.title('en')));
      expect(item.body('en'), isNotEmpty);
      expect(item.body('ar'), isNotEmpty);
      expect(item.body('ar'), isNot(item.body('en')));
      expect(item.createdAt.isUtc, isTrue);
      expect(item.isRead, isFalse);
    }
    for (var index = 1; index < notifications.length; index++) {
      expect(
        notifications[index - 1].createdAt.isAfter(
          notifications[index].createdAt,
        ),
        isTrue,
      );
    }
  });

  test(
    'marking read changes only the selected item, not old snapshots',
    () async {
      final before = await _load(repository, 'alice');
      final start = DateTime.now().toUtc();
      final result = await repository.markRead(
        userId: 'alice',
        notificationId: before.first.id,
      );
      final after = await _load(repository, 'alice');

      expect(result.isRight(), isTrue);
      expect(before.first.isRead, isFalse);
      expect(after.first.isRead, isTrue);
      expect(after.first.readAt!.isUtc, isTrue);
      expect(after.first.readAt!.isBefore(start), isFalse);
      expect(after.first.readAt!.isAfter(DateTime.now().toUtc()), isFalse);
      expect(after.skip(1), orderedEquals(before.skip(1)));
      expect(() => after.clear(), throwsUnsupportedError);
    },
  );

  test('read state remains isolated across users on one repository', () async {
    final alice = await _load(repository, 'alice');
    final bob = await _load(repository, 'bob');
    await repository.markRead(userId: 'alice', notificationId: alice.first.id);

    expect((await _load(repository, 'alice')).first.isRead, isTrue);
    expect(await _load(repository, 'bob'), orderedEquals(bob));
    expect(bob.every((item) => item.userId == 'bob' && !item.isRead), isTrue);
    expect(
      alice
          .map((item) => item.id)
          .toSet()
          .intersection(bob.map((item) => item.id).toSet()),
      isEmpty,
    );
  });

  test(
    'foreign and missing notification IDs fail without changing inboxes',
    () async {
      final alice = await _load(repository, 'alice');
      final bob = await _load(repository, 'bob');

      for (final id in [alice.first.id, 'missing-notification', '']) {
        final result = await repository.markRead(
          userId: 'bob',
          notificationId: id,
        );
        result.fold(
          (failure) => expect(failure.message, 'notifications.not_found'),
          (_) => fail(
            'A foreign or missing notification must not be marked read.',
          ),
        );
      }
      expect(await _load(repository, 'alice'), orderedEquals(alice));
      expect(await _load(repository, 'bob'), orderedEquals(bob));
    },
  );

  test(
    'marking an already-read notification preserves its first timestamp',
    () async {
      final id = (await _load(repository, 'alice')).first.id;
      await repository.markRead(userId: 'alice', notificationId: id);
      final firstRead = (await _load(repository, 'alice')).first;
      final repeated = await repository.markRead(
        userId: 'alice',
        notificationId: id,
      );
      final secondRead = (await _load(repository, 'alice')).first;

      expect(repeated.isRight(), isTrue);
      expect(secondRead.readAt, firstRead.readAt);
      expect(
        secondRead.withReadAt(DateTime.utc(2030)).readAt,
        firstRead.readAt,
      );
    },
  );

  test(
    'reloading does not duplicate demo items; repository instances are local',
    () async {
      final first = await _load(repository, 'alice');
      expect(await _load(repository, 'alice'), orderedEquals(first));
      await repository.markRead(
        userId: 'alice',
        notificationId: first.first.id,
      );

      final fresh = await _load(NotificationsRepository(), 'alice');
      expect(fresh.every((item) => !item.isRead), isTrue);
      expect(
        fresh.map((item) => item.id),
        orderedEquals(first.map((item) => item.id)),
      );
    },
  );

  test(
    'blank user IDs are rejected instead of sharing an anonymous inbox',
    () async {
      for (final userId in ['', '   ']) {
        expect((await repository.loadNotifications(userId)).isLeft(), isTrue);
        expect(
          (await repository.markRead(
            userId: userId,
            notificationId: 'demo',
          )).isLeft(),
          isTrue,
        );
      }
    },
  );

  test('configured client failures never return or modify demo data', () async {
    final client = _FailingClient();
    addTearDown(client.dispose);
    final liveRepository = NotificationsRepository(client: client);

    expect(liveRepository.isDemo, isFalse);
    expect((await liveRepository.loadNotifications('alice')).isLeft(), isTrue);
    expect(
      (await liveRepository.markRead(
        userId: 'alice',
        notificationId: 'id',
      )).isLeft(),
      isTrue,
    );
  });

  test(
    'SQL mapping parses nullable timestamps and preserves localized content',
    () {
      final json = <String, dynamic>{
        'id': '00000000-0000-0000-0000-000000000001',
        'user_id': '00000000-0000-0000-0000-000000000002',
        'title_en': 'Welcome',
        'title_ar': 'مرحباً',
        'body_en': 'Explore services.',
        'body_ar': 'استكشف الخدمات.',
        'created_at': '2026-10-15T14:00:00+02:00',
        'read_at': null,
      };
      final unread = AppNotification.fromJson(json);
      final read = AppNotification.fromJson({
        ...json,
        'read_at': '2026-10-15T15:00:00+02:00',
      });

      expect(unread.createdAt, DateTime.utc(2026, 10, 15, 12));
      expect(unread.isRead, isFalse);
      expect(unread.title('ar'), 'مرحباً');
      expect(unread.body('ar'), 'استكشف الخدمات.');
      expect(unread.title('unknown'), 'Welcome');
      expect(read.readAt, DateTime.utc(2026, 10, 15, 13));
      expect(read.userId, unread.userId);
      expect(read.createdAt, unread.createdAt);
    },
  );
}

Future<List<AppNotification>> _load(
  NotificationsRepository repository,
  String userId,
) async {
  return (await repository.loadNotifications(userId))
      .fold((failure) => throw TestFailure(failure.message), (value) => value);
}

class _FailingClient extends SupabaseClient {
  _FailingClient() : super('https://example.invalid', 'test-anon-key');

  @override
  SupabaseQueryBuilder from(String table) {
    throw const PostgrestException(message: 'Simulated failure', code: '503');
  }
}
