import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:salahly/src/data/models/app_notification.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/task_runner.dart';
import 'package:salahly/src/utils/typedefs.dart';

class NotificationsRepository {
  NotificationsRepository({this._client});

  final SupabaseClient? _client;
  final _demoByUser = <String, List<AppNotification>>{};

  bool get isDemo => _client == null;

  FutureEither<List<AppNotification>> loadNotifications(String userId) {
    return runTask(() async {
      if (userId.trim().isEmpty) {
        throw const ServerFailure('errors.auth_failed');
      }
      final client = _client;
      if (client == null) return _demoNotificationsFor(userId);

      final rows = await client
          .from('notifications')
          .select(
            'id,user_id,title_en,title_ar,body_en,body_ar,created_at,read_at',
          )
          .eq('user_id', userId)
          .order('created_at', ascending: false);
      return List<AppNotification>.unmodifiable(
        rows.map(AppNotification.fromJson),
      );
    });
  }

  FutureEither<void> markRead({
    required String userId,
    required String notificationId,
  }) {
    return runTask(() async {
      if (userId.trim().isEmpty) {
        throw const ServerFailure('errors.auth_failed');
      }
      if (notificationId.trim().isEmpty) {
        throw const ServerFailure('notifications.not_found');
      }
      final timestamp = DateTime.now().toUtc();
      final client = _client;
      if (client == null) {
        final notifications = _demoNotificationsFor(userId);
        if (!notifications.any((item) => item.id == notificationId)) {
          throw const ServerFailure('notifications.not_found');
        }
        _demoByUser[userId] = List<AppNotification>.unmodifiable([
          for (final item in notifications)
            if (item.id == notificationId) item.withReadAt(timestamp) else item,
        ]);
        return;
      }

      final updated = await client
          .from('notifications')
          .update({'read_at': timestamp.toIso8601String()})
          .eq('user_id', userId)
          .eq('id', notificationId)
          .isFilter('read_at', null)
          .select('id');
      if (updated.isNotEmpty) return;

      // A repeated read is successful; an inaccessible or missing row is not.
      final existing = await client
          .from('notifications')
          .select('read_at')
          .eq('user_id', userId)
          .eq('id', notificationId)
          .maybeSingle();
      if (existing == null) {
        throw const ServerFailure('notifications.not_found');
      }
      if (existing['read_at'] == null) {
        throw const ServerFailure('errors.request_failed');
      }
    });
  }

  List<AppNotification> _demoNotificationsFor(String userId) {
    return _demoByUser.putIfAbsent(
      userId,
      () => List<AppNotification>.unmodifiable([
        AppNotification(
          id: 'demo-welcome-$userId',
          userId: userId,
          titleEn: 'Welcome to the Salhly demo',
          titleAr: 'مرحباً بك في تجربة صلحلي',
          bodyEn: 'Explore service categories and edit your profile. This is a local sample notification.',
          bodyAr:
              'استكشف فئات الخدمات وعدّل ملفك الشخصي. هذا إشعار تجريبي محلي.',
          createdAt: DateTime.utc(2026, 10, 15, 12),
        ),
        AppNotification(
          id: 'demo-guide-$userId',
          userId: userId,
          titleEn: 'Demo: what comes next',
          titleAr: 'تجربة توضيحية: الخطوات القادمة',
          bodyEn: 'Service requests, quotes and live alerts are future features, not available in this version.',
          bodyAr: 'طلبات الخدمات وعروض الأسعار والتنبيهات المباشرة ميزات مستقبلية غير متاحة في هذا الإصدار.',
          createdAt: DateTime.utc(2026, 10, 15, 11),
        ),
      ]),
    );
  }
}
