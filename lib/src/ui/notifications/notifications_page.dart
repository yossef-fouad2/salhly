import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:salahly/src/data/models/app_notification.dart';
import 'package:salahly/src/data/repositories/notifications_repository.dart';
import 'package:salahly/src/extensions/context_extension.dart';
import 'package:salahly/src/shared/enums/button_enums.dart';
import 'package:salahly/src/shared/widgets/app_button.dart';
import 'package:salahly/src/shared/widgets/app_empty_state.dart';
import 'package:salahly/src/shared/widgets/app_loading.dart';
import 'package:salahly/src/theme/theme_constants.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';
import 'package:salahly/src/ui/notifications/notifications_cubit.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final userId = context.select((SessionBloc bloc) => bloc.state.user?.id);
    if (userId == null) return const SizedBox.shrink();

    return BlocProvider(
      key: ValueKey(userId),
      create: (context) => NotificationsCubit(
        context.read<NotificationsRepository>(),
        userId: userId,
      )..load(),
      child: const _NotificationsView(),
    );
  }
}

class _NotificationsView extends StatelessWidget {
  const _NotificationsView();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<NotificationsCubit, NotificationsState>(
      listenWhen: (previous, current) =>
          current.readErrorMessage != null ||
          (current.notifications.isNotEmpty && current.errorMessage != null),
      listener: (context, state) {
        context.showErrorSnackBar(
          (state.readErrorMessage ?? state.errorMessage)!.tr(),
        );
      },
      builder: (context, state) {
        return RefreshIndicator(
          onRefresh: context.read<NotificationsCubit>().load,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(AppSpacing.pagePadding),
                itemCount: state.notifications.isEmpty
                    ? 1
                    : state.notifications.length,
                itemBuilder: (context, index) {
                  // Refresh feedback must not replace an already loaded inbox.
                  if (state.notifications.isNotEmpty) {
                    final notification = state.notifications[index];
                    return Padding(
                      key: ValueKey(notification.id),
                      padding: EdgeInsets.only(bottom: AppSpacing.itemGap),
                      child: _NotificationCard(
                        notification: notification,
                        isMarking: state.markingIds.contains(notification.id),
                      ),
                    );
                  }
                  if (state.isLoading) {
                    return Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: AppLoading(
                        message: 'common.loading'.tr(context: context),
                      ),
                    );
                  }
                  if (state.errorMessage != null) {
                    return AppEmptyState(
                      icon: Icons.error_outline,
                      title: 'common.error'.tr(context: context),
                      subtitle: state.errorMessage!.tr(context: context),
                      actionLabel: 'common.retry'.tr(context: context),
                      onAction: context.read<NotificationsCubit>().load,
                    );
                  }
                  return AppEmptyState(
                    icon: Icons.notifications_none,
                    title: 'notifications.empty_title'.tr(context: context),
                    subtitle: 'notifications.empty_message'.tr(
                      context: context,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.isMarking,
  });

  final AppNotification notification;
  final bool isMarking;

  @override
  Widget build(BuildContext context) {
    final language = context.locale.languageCode;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  notification.isRead
                      ? Icons.notifications_none
                      : Icons.notifications_active_outlined,
                  color: notification.isRead
                      ? context.colors.onSurfaceVariant
                      : context.colors.primary,
                ),
                SizedBox(width: AppSpacing.ms),
                Expanded(
                  child: Text(
                    notification.title(language),
                    style: context.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            SizedBox(height: AppSpacing.ms),
            Text(
              notification.body(language),
              style: context.textTheme.bodyMedium,
            ),
            SizedBox(height: AppSpacing.ms),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                Text(
                  DateFormat.yMMMd(language)
                      .add_jm()
                      .format(notification.createdAt.toLocal()),
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                Text(
                  (notification.isRead
                          ? 'notifications.read'
                          : 'notifications.unread')
                      .tr(),
                  style: context.textTheme.labelMedium?.copyWith(
                    color: notification.isRead
                        ? context.colors.onSurfaceVariant
                        : context.colors.primary,
                  ),
                ),
              ],
            ),
            if (!notification.isRead) ...[
              SizedBox(height: AppSpacing.md),
              AppButton(
                label: 'notifications.mark_read'.tr(),
                variant: ButtonVariant.secondary,
                isLoading: isMarking,
                onPressed: () =>
                    context.read<NotificationsCubit>().markRead(notification),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
