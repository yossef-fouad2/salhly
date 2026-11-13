import '../../data/models/marketplace.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import '../requests/service_request_location_step.dart';
import 'job_detail_cubit.dart';
import 'marketplace_widgets.dart';

class JobDetailPage extends StatelessWidget {
  const JobDetailPage({super.key, required this.userId, required this.jobId});
  final String userId;
  final String jobId;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => JobDetailCubit(
      userId: userId,
      jobId: jobId,
      repository: context.read<MarketplaceRepository>(),
      session: context.read<SessionBloc>(),
    )..load(),
    child: _JobDetailView(userId: userId),
  );
}

class _JobDetailView extends StatelessWidget {
  const _JobDetailView({required this.userId});
  final String userId;

  Future<void> _transition(BuildContext context, JobStatus target) async {
    final cubit = context.read<JobDetailCubit>();
    if (cubit.state.busy || cubit.state.uncertain) return;
    final confirmed = await marketplaceConfirm(
      context,
      titleKey: 'marketplace.job_action.${target.wireName}',
      bodyKey: 'marketplace.job_confirm.${target.wireName}',
      confirmKey: 'marketplace.job_action.${target.wireName}',
    );
    if (context.mounted && confirmed && !cubit.isClosed) {
      await cubit.transition(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<JobDetailCubit>();
    return BlocBuilder<JobDetailCubit, JobDetailState>(
      builder: (context, state) {
        final job = state.job;
        return MarketplaceExitScope(
          userId: userId,
          busy: state.transitioning,
          uncertain: state.uncertain,
          dirty: false,
          fallbackRoute: AppRouteNames.jobs,
          builder: (back) => MarketplaceScaffold(
            userId: userId,
            titleKey: 'marketplace.job_title',
            onBack: back,
            onRefresh: state.busy || state.uncertain || state.revoked
                ? null
                : cubit.load,
            child: job == null
                ? state.loading || state.transitioning
                      ? AppLoading(message: 'common.loading'.tr())
                      : state.uncertain
                      ? Padding(
                          padding: EdgeInsets.all(AppSpacing.pagePadding),
                          child: MarketplaceFeedback(
                            uncertain: true,
                            errorMessage: state.errorMessage,
                            onRetry: cubit.retryPending,
                          ),
                        )
                      : AppEmptyState(
                          title: 'common.error'.tr(),
                          subtitle: state.errorMessage?.tr(),
                          actionLabel: state.revoked
                              ? null
                              : 'common.retry'.tr(),
                          onAction: state.revoked ? null : cubit.load,
                        )
                : RefreshIndicator(
                    onRefresh: cubit.load,
                    child: ListView.builder(
                      key: PageStorageKey('marketplace-job-$userId-${job.id}'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.all(AppSpacing.pagePadding),
                      itemCount: job.history.length + 1,
                      itemBuilder: (context, index) {
                        if (index > 0) {
                          return _HistoryCard(
                            key: ValueKey(job.history[index - 1].id),
                            entry: job.history[index - 1],
                            job: job,
                            userId: userId,
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (context.read<MarketplaceRepository>().isDemo)
                              const MarketplaceDemoNotice(),
                            MarketplaceFeedback(
                              loading: state.loading,
                              errorMessage: state.errorMessage,
                              uncertain: state.uncertain,
                              onRetry: state.busy
                                  ? null
                                  : state.uncertain
                                  ? cubit.retryPending
                                  : cubit.load,
                            ),
                            AppCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      'marketplace.job_status.${job.status.wireName}'
                                          .tr(),
                                      style: context.textTheme.labelLarge
                                          ?.copyWith(
                                            color: context.colors.secondary,
                                          ),
                                    ),
                                  ),
                                  SizedBox(height: AppSpacing.md),
                                  Text(
                                    job.requestTitle,
                                    style: context.textTheme.headlineSmall,
                                  ),
                                  SizedBox(height: AppSpacing.sm),
                                  Text(
                                    'marketplace.provider_value'.tr(
                                      namedArgs: {'name': job.providerName},
                                    ),
                                  ),
                                  SizedBox(height: AppSpacing.md),
                                  Text(
                                    'marketplace.job_hint.${job.status.wireName}'
                                        .tr(),
                                  ),
                                  for (final target in state.actions) ...[
                                    SizedBox(height: AppSpacing.md),
                                    AppButton(
                                      key: ValueKey(
                                        'job-action-${target.wireName}',
                                      ),
                                      label:
                                          'marketplace.job_action.${target.wireName}'
                                              .tr(),
                                      variant: target == JobStatus.cancelled
                                          ? ButtonVariant.outline
                                          : ButtonVariant.primary,
                                      isLoading:
                                          state.transitioning &&
                                          state.pendingTarget == target,
                                      onPressed: state.busy || state.uncertain
                                          ? null
                                          : () => _transition(context, target),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            SizedBox(height: AppSpacing.md),
                            AppCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'marketplace.accepted_terms'.tr(),
                                    style: context.textTheme.titleLarge,
                                  ),
                                  SizedBox(height: AppSpacing.md),
                                  MarketplaceTerms(
                                    amountMinor: job.amountMinor,
                                    durationMinutes: job.durationMinutes,
                                    notes: job.notes,
                                  ),
                                  SizedBox(height: AppSpacing.md),
                                  Text(
                                    'marketplace.frozen_terms'.tr(),
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
                                    'marketplace.shared_job_details'.tr(),
                                    style: context.textTheme.titleLarge,
                                  ),
                                  SizedBox(height: AppSpacing.sm),
                                  Text(
                                    'marketplace.job_privacy'.tr(),
                                    style: context.textTheme.bodySmall,
                                  ),
                                  SizedBox(height: AppSpacing.lg),
                                  Text(
                                    'requests.description'.tr(),
                                    style: context.textTheme.labelLarge,
                                  ),
                                  SizedBox(height: AppSpacing.sm),
                                  Text(job.requestDescription),
                                  SizedBox(height: AppSpacing.lg),
                                  Text(
                                    'requests.location'.tr(),
                                    style: context.textTheme.labelLarge,
                                  ),
                                  SizedBox(height: AppSpacing.sm),
                                  Text(job.city),
                                  Text(
                                    job.address,
                                    key: const ValueKey(
                                      'marketplace-job-address',
                                    ),
                                  ),
                                  SizedBox(height: AppSpacing.lg),
                                  Text(
                                    'requests.preferred_time'.tr(),
                                    style: context.textTheme.labelLarge,
                                  ),
                                  SizedBox(height: AppSpacing.sm),
                                  Text(
                                    formatRequestPreferredTime(
                                      context,
                                      job.preferredAt,
                                    ),
                                  ),
                                  SizedBox(height: AppSpacing.sm),
                                  Text(
                                    'requests.time_note'.tr(),
                                    style: context.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: AppSpacing.lg),
                            Text(
                              'marketplace.history_title'.tr(),
                              style: context.textTheme.titleLarge,
                            ),
                            SizedBox(height: AppSpacing.sm),
                            Text(
                              'marketplace.history_note'.tr(),
                              style: context.textTheme.bodySmall,
                            ),
                            SizedBox(height: AppSpacing.md),
                            if (job.history.isEmpty)
                              Text('marketplace.history_empty'.tr()),
                          ],
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

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    super.key,
    required this.entry,
    required this.job,
    required this.userId,
  });
  final JobHistoryEntry entry;
  final ServiceJob job;
  final String userId;

  String _actor(BuildContext context) => entry.actorId == userId
      ? 'marketplace.you'.tr()
      : entry.actorId == job.providerId
      ? job.providerName
      : 'roles.customer'.tr();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: AppSpacing.md),
    child: AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'marketplace.job_status.${entry.status.wireName}'.tr(),
            style: context.textTheme.titleMedium,
          ),
          SizedBox(height: AppSpacing.sm),
          Text(
            'marketplace.history_entry'.tr(
              namedArgs: {
                'actor': _actor(context),
                'date': marketplaceDate(context, entry.createdAt),
              },
            ),
            style: context.textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
