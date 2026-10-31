import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:salahly/src/data/models/app_notification.dart';
import 'package:salahly/src/data/repositories/notifications_repository.dart';

class NotificationsState extends Equatable {
  const NotificationsState({
    this.notifications = const [],
    this.markingIds = const {},
    this.isLoading = false,
    this.errorMessage,
    this.readErrorMessage,
  });

  final List<AppNotification> notifications;
  final Set<String> markingIds;
  final bool isLoading;
  final String? errorMessage;
  final String? readErrorMessage;

  @override
  List<Object?> get props => [
    notifications,
    markingIds,
    isLoading,
    errorMessage,
    readErrorMessage,
  ];
}

class NotificationsCubit extends Cubit<NotificationsState> {
  NotificationsCubit(this._repository, {required this._userId})
    : super(const NotificationsState());

  final NotificationsRepository _repository;
  final String _userId;

  Future<void> load() async {
    // Serialize refresh against writes so an old snapshot cannot undo a read.
    if (state.isLoading || state.markingIds.isNotEmpty) return;
    emit(
      NotificationsState(notifications: state.notifications, isLoading: true),
    );
    final result = await _repository.loadNotifications(_userId);
    if (isClosed) return;
    result.fold(
      (failure) => emit(
        NotificationsState(
          notifications: state.notifications,
          errorMessage: failure.message,
        ),
      ),
      (notifications) => emit(NotificationsState(notifications: notifications)),
    );
  }

  Future<void> markRead(AppNotification notification) async {
    if (state.isLoading ||
        notification.isRead ||
        notification.userId != _userId ||
        state.markingIds.contains(notification.id)) {
      return;
    }
    emit(
      NotificationsState(
        notifications: state.notifications,
        markingIds: Set.unmodifiable({...state.markingIds, notification.id}),
      ),
    );
    final result = await _repository.markRead(
      userId: _userId,
      notificationId: notification.id,
    );
    if (isClosed) return;
    final pending = Set<String>.unmodifiable(
      state.markingIds.where((id) => id != notification.id),
    );
    result.fold(
      (failure) => emit(
        NotificationsState(
          notifications: state.notifications,
          markingIds: pending,
          readErrorMessage: failure.message,
        ),
      ),
      (_) => emit(
        NotificationsState(
          notifications: List.unmodifiable([
            for (final item in state.notifications)
              if (item.id == notification.id)
                item.withReadAt(DateTime.now())
              else
                item,
          ]),
          markingIds: pending,
        ),
      ),
    );
  }
}
