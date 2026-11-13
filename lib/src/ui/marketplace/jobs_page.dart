import '../../data/models/marketplace.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import 'jobs_cubit.dart';
import 'marketplace_widgets.dart';

class JobsPage extends StatelessWidget {
  const JobsPage({super.key, required this.userId});
  final String userId;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => JobsCubit(
      userId: userId,
      repository: context.read<MarketplaceRepository>(),
      session: context.read<SessionBloc>(),
    )..refresh(),
    child: _JobsView(userId: userId),
  );
}

class _JobsView extends StatelessWidget {
  const _JobsView({required this.userId});
  final String userId;

  Future<void> _open(BuildContext context, ServiceJob job) async {
    final cubit = context.read<JobsCubit>();
    await context.pushNamed(
      AppRouteNames.jobDetail,
      pathParameters: {'jobId': job.id},
    );
    if (!cubit.isClosed) await cubit.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<JobsCubit>();
    return BlocBuilder<JobsCubit, JobsState>(
      builder: (context, state) => MarketplaceScaffold(
        userId: userId,
        titleKey: 'marketplace.jobs',
        onRefresh: state.busy || state.revoked ? null : cubit.refresh,
        child: RefreshIndicator(
          onRefresh: cubit.refresh,
          child: ListView.builder(
            key: PageStorageKey('marketplace-jobs-$userId'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.all(AppSpacing.pagePadding),
            itemCount: state.items.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (context.read<MarketplaceRepository>().isDemo)
                      const MarketplaceDemoNotice(),
                    Text(
                      'marketplace.jobs_intro'.tr(),
                      style: context.textTheme.bodyLarge,
                    ),
                    SizedBox(height: AppSpacing.lg),
                    MarketplaceFeedback(
                      loading: state.loading,
                      errorMessage: state.errorMessage,
                      onRetry: state.busy || state.revoked
                          ? null
                          : cubit.refresh,
                    ),
                  ],
                );
              }
              if (index == state.items.length + 1) {
                if (state.items.isEmpty && state.loaded) {
                  return AppEmptyState(
                    icon: Icons.home_repair_service_outlined,
                    title: 'marketplace.jobs_empty_title'.tr(),
                    subtitle: 'marketplace.jobs_empty_body'.tr(),
                  );
                }
                if (state.hasMore) {
                  return AppButton(
                    label: 'marketplace.load_more'.tr(),
                    variant: ButtonVariant.outline,
                    isLoading: state.loadingMore,
                    onPressed: state.busy ? null : cubit.loadMore,
                  );
                }
                return const SizedBox.shrink();
              }
              final job = state.items[index - 1];
              return Padding(
                key: ValueKey(job.id),
                padding: EdgeInsets.only(bottom: AppSpacing.md),
                child: AppCard(
                  onTap: () => _open(context, job),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'marketplace.job_status.${job.status.wireName}'.tr(),
                        style: context.textTheme.labelLarge?.copyWith(
                          color: context.colors.secondary,
                        ),
                      ),
                      SizedBox(height: AppSpacing.sm),
                      Text(
                        job.requestTitle,
                        style: context.textTheme.titleLarge,
                      ),
                      SizedBox(height: AppSpacing.sm),
                      Text(
                        'marketplace.provider_value'.tr(
                          namedArgs: {'name': job.providerName},
                        ),
                      ),
                      SizedBox(height: AppSpacing.md),
                      Text(
                        marketplaceMoney(context, job.amountMinor),
                        style: context.textTheme.titleMedium,
                      ),
                      SizedBox(height: AppSpacing.sm),
                      Text(
                        'marketplace.job_created'.tr(
                          namedArgs: {
                            'date': marketplaceDate(context, job.createdAt),
                          },
                        ),
                        style: context.textTheme.bodySmall,
                      ),
                      SizedBox(height: AppSpacing.md),
                      AppButton(
                        label: 'marketplace.view_job'.tr(),
                        variant: ButtonVariant.outline,
                        onPressed: () => _open(context, job),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
