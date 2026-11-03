import '../../data/models/service_request.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/service_request_repository.dart';
import '../../imports/imports.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/widgets/demo_banner.dart';
import '../auth/bloc/session_bloc.dart';
import 'request_photo_image.dart';
import 'service_request_detail_cubit.dart';
import 'service_request_location_step.dart';

class ServiceRequestDetailPage extends StatelessWidget {
  const ServiceRequestDetailPage({
    super.key,
    required this.userId,
    required this.requestId,
  });
  final String userId;
  final String requestId;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => ServiceRequestDetailCubit(
      userId: userId,
      requestId: requestId,
      repository: context.read<ServiceRequestRepository>(),
    )..load(),
    child: _DetailView(userId: userId),
  );
}

class _DetailView extends StatelessWidget {
  const _DetailView({required this.userId});
  final String userId;

  bool _authorized(SessionState state) =>
      state.status == SessionStatus.authenticated &&
      state.user?.id == userId &&
      state.user?.role == UserRole.customer;

  Future<void> _cancel(BuildContext context) async {
    final cubit = context.read<ServiceRequestDetailCubit>();
    final cancel = await context.showAppDialog<bool>(
      builder: (context) => AlertDialog(
        title: Text('requests.cancel_title'.tr()),
        content: Text('requests.cancel_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('requests.keep_request'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('requests.cancel_request'.tr()),
          ),
        ],
      ),
    );
    if (!context.mounted ||
        cubit.isClosed ||
        cancel != true ||
        !_authorized(context.read<SessionBloc>().state)) {
      return;
    }
    await cubit.cancel();
  }

  Future<void> _photo(BuildContext context, ServiceRequestPhoto photo) async {
    final cubit = context.read<ServiceRequestDetailCubit>();
    final bytes = await cubit.readPhoto(photo.id);
    if (!context.mounted ||
        bytes == null ||
        !_authorized(context.read<SessionBloc>().state)) {
      return;
    }
    await context.showAppDialog<void>(
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 640,
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: RequestPhotoImage(
                    userId: userId,
                    bytes: bytes,
                    semanticLabel: 'requests.photo_label'.tr(
                      namedArgs: {'number': '${photo.position}'},
                    ),
                  ),
                ),
                SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: 'common.close'.tr(),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!context.select((SessionBloc bloc) => _authorized(bloc.state))) {
      return const SizedBox.shrink();
    }
    final cubit = context.read<ServiceRequestDetailCubit>();
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => context.canPop()
              ? context.pop()
              : context.goNamed(AppRouteNames.serviceRequests),
        ),
        title: Text('requests.detail_title'.tr()),
        actions: [
          IconButton(
            tooltip: 'requests.refresh'.tr(),
            onPressed: cubit.load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: BlocBuilder<ServiceRequestDetailCubit, ServiceRequestDetailState>(
          builder: (context, state) {
            final request = state.request;
            if (request == null) {
              return state.loading
                  ? AppLoading(message: 'common.loading'.tr())
                  : AppEmptyState(
                      title: 'common.error'.tr(),
                      subtitle: state.errorMessage?.tr(),
                      actionLabel: 'common.retry'.tr(),
                      onAction: cubit.load,
                    );
            }
            return RefreshIndicator(
              onRefresh: cubit.load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Padding(
                      padding: EdgeInsets.all(AppSpacing.pagePadding),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (context
                              .read<ServiceRequestRepository>()
                              .isDemo) ...[
                            const DemoBanner(),
                            SizedBox(height: AppSpacing.md),
                          ],
                          if (state.loading)
                            LinearProgressIndicator(
                              semanticsLabel: 'common.loading'.tr(),
                            ),
                          if (state.errorMessage != null) ...[
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                state.errorMessage!.tr(),
                                style: TextStyle(color: context.colors.error),
                              ),
                            ),
                            SizedBox(height: AppSpacing.md),
                          ],
                          AppCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  liveRegion: true,
                                  child: AnimatedSwitcher(
                                    duration: AppMotion.durationOf(
                                      context,
                                      AppDurations.fast,
                                    ),
                                    child: Container(
                                      key: ValueKey(request.status),
                                      padding: EdgeInsets.symmetric(
                                        horizontal: AppSpacing.ms,
                                        vertical: AppSpacing.xs,
                                      ),
                                      decoration: BoxDecoration(
                                        color:
                                            request.status ==
                                                ServiceRequestStatus.open
                                            ? context.appColors.warningContainer
                                            : context.colors.surfaceContainer,
                                        borderRadius: AppBorders.full,
                                      ),
                                      child: Text(
                                        'requests.status_${request.status.name}'
                                            .tr(),
                                        style: context.textTheme.labelMedium
                                            ?.copyWith(
                                              color:
                                                  request.status ==
                                                      ServiceRequestStatus.open
                                                  ? context
                                                        .appColors
                                                        .onWarningContainer
                                                  : context
                                                        .colors
                                                        .onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(height: AppSpacing.md),
                                Text(
                                  request.title,
                                  style: context.textTheme.headlineSmall,
                                ),
                                SizedBox(height: AppSpacing.sm),
                                Text(
                                  request.categoryName(
                                    context.locale.languageCode,
                                  ),
                                  style: context.textTheme.bodyLarge,
                                ),
                                SizedBox(height: AppSpacing.md),
                                Text(
                                  'requests.created_at'.tr(
                                    namedArgs: {
                                      'date': MaterialLocalizations.of(context)
                                          .formatMediumDate(
                                            request.createdAt.toLocal(),
                                          ),
                                    },
                                  ),
                                  style: context.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: AppSpacing.md),
                          AppCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'requests.description'.tr(),
                                  style: context.textTheme.titleMedium,
                                ),
                                SizedBox(height: AppSpacing.sm),
                                Text(
                                  request.description,
                                  style: context.textTheme.bodyLarge,
                                ),
                                SizedBox(height: AppSpacing.lg),
                                Text(
                                  'requests.location'.tr(),
                                  style: context.textTheme.titleMedium,
                                ),
                                SizedBox(height: AppSpacing.sm),
                                Text(
                                  request.city,
                                  style: context.textTheme.bodyLarge,
                                ),
                                Text(
                                  request.address,
                                  style: context.textTheme.bodyLarge,
                                ),
                                SizedBox(height: AppSpacing.lg),
                                Text(
                                  'requests.preferred_time'.tr(),
                                  style: context.textTheme.titleMedium,
                                ),
                                SizedBox(height: AppSpacing.sm),
                                Text(
                                  formatRequestPreferredTime(
                                    context,
                                    request.preferredAt,
                                  ),
                                  style: context.textTheme.bodyLarge,
                                ),
                                SizedBox(height: AppSpacing.sm),
                                Text(
                                  'requests.time_note'.tr(),
                                  style: context.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: AppSpacing.md),
                          AppCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'requests.photos'.tr(),
                                  style: context.textTheme.titleLarge,
                                ),
                                SizedBox(height: AppSpacing.sm),
                                Text(
                                  'requests.private_photos_note'.tr(),
                                  style: context.textTheme.bodyMedium,
                                ),
                                if (request.photos.isEmpty) ...[
                                  SizedBox(height: AppSpacing.sm),
                                  Text('requests.no_photos'.tr()),
                                ],
                                for (final photo in request.photos) ...[
                                  SizedBox(height: AppSpacing.ms),
                                  AppButton(
                                    key: ValueKey(
                                      'view-request-photo-${photo.id}',
                                    ),
                                    label: 'requests.view_photo'.tr(
                                      namedArgs: {
                                        'number': '${photo.position}',
                                      },
                                    ),
                                    prefixIcon: const Icon(
                                      Icons.photo_outlined,
                                    ),
                                    variant: ButtonVariant.outline,
                                    isLoading: state.readingPhotoId == photo.id,
                                    onPressed: state.busy
                                        ? null
                                        : () => _photo(context, photo),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          SizedBox(height: AppSpacing.md),
                          Text(
                            'requests.next_steps_note'.tr(),
                            style: context.textTheme.bodyMedium?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                          if (request.status == ServiceRequestStatus.open) ...[
                            SizedBox(height: AppSpacing.lg),
                            AppButton(
                              key: const ValueKey('cancel-service-request'),
                              label: 'requests.cancel_request'.tr(),
                              variant: ButtonVariant.outline,
                              isLoading: state.cancelling,
                              onPressed: state.busy
                                  ? null
                                  : () => _cancel(context),
                            ),
                          ],
                          SizedBox(height: AppSpacing.md),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
