import '../../data/models/service_request.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/service_request_repository.dart';
import '../../imports/imports.dart';
import '../../shared/motion/pressable_scale.dart';
import '../../shared/widgets/demo_banner.dart';
import '../auth/bloc/session_bloc.dart';
import 'service_request_history_cubit.dart';
import 'service_request_location_step.dart';

class ServiceRequestHistoryPage extends StatelessWidget {
  const ServiceRequestHistoryPage({super.key, required this.userId});
  final String userId;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => ServiceRequestHistoryCubit(
      userId: userId,
      repository: context.read<ServiceRequestRepository>(),
    )..refresh(),
    child: _HistoryView(userId: userId),
  );
}

class _HistoryView extends StatefulWidget {
  const _HistoryView({required this.userId});
  final String userId;
  @override
  State<_HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<_HistoryView> {
  bool? _wasCurrent;

  bool _authorized(SessionState state) =>
      state.status == SessionStatus.authenticated &&
      state.user?.id == widget.userId &&
      state.user?.role == UserRole.customer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current && _wasCurrent == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _authorized(context.read<SessionBloc>().state)) {
          context.read<ServiceRequestHistoryCubit>().refresh();
        }
      });
    }
    _wasCurrent = current;
  }

  void _newRequest() => context.pushNamed(AppRouteNames.createServiceRequest);

  @override
  Widget build(BuildContext context) {
    if (!context.select((SessionBloc bloc) => _authorized(bloc.state))) {
      return const SizedBox.shrink();
    }
    final cubit = context.read<ServiceRequestHistoryCubit>();
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => context.canPop()
              ? context.pop()
              : context.goNamed(AppRouteNames.home),
        ),
        title: Text('requests.history_title'.tr()),
        actions: [
          IconButton(
            tooltip: 'requests.new_request'.tr(),
            onPressed: _newRequest,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child:
                BlocBuilder<
                  ServiceRequestHistoryCubit,
                  ServiceRequestHistoryState
                >(
                  builder: (context, state) => RefreshIndicator(
                    onRefresh: cubit.refresh,
                    child: ListView.builder(
                      key: PageStorageKey('request-history-${widget.userId}'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.all(AppSpacing.pagePadding),
                      itemCount: state.items.length + 2,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (context
                                  .read<ServiceRequestRepository>()
                                  .isDemo) ...[
                                const DemoBanner(),
                                SizedBox(height: AppSpacing.md),
                              ],
                              Text(
                                'requests.history_intro'.tr(),
                                style: context.textTheme.bodyLarge?.copyWith(
                                  color: context.colors.onSurfaceVariant,
                                ),
                              ),
                              SizedBox(height: AppSpacing.lg),
                              if (state.loading)
                                LinearProgressIndicator(
                                  semanticsLabel: 'common.loading'.tr(),
                                ),
                              if (state.errorMessage != null) ...[
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    state.errorMessage!.tr(),
                                    style: TextStyle(
                                      color: context.colors.error,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: state.busy ? null : cubit.refresh,
                                  child: Text('common.retry'.tr()),
                                ),
                              ],
                            ],
                          );
                        }
                        if (index == state.items.length + 1) {
                          if (state.items.isEmpty && state.loaded) {
                            return AppEmptyState(
                              icon: Icons.receipt_long_outlined,
                              title: 'requests.empty_title'.tr(),
                              subtitle: 'requests.empty_body'.tr(),
                              actionLabel: 'requests.new_request'.tr(),
                              onAction: _newRequest,
                            );
                          }
                          if (state.hasMore) {
                            return Padding(
                              padding: EdgeInsets.only(top: AppSpacing.md),
                              child: AppButton(
                                label: 'requests.load_more'.tr(),
                                variant: ButtonVariant.outline,
                                isLoading: state.loadingMore,
                                onPressed: state.busy ? null : cubit.loadMore,
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }
                        return _RequestHistoryCard(
                          key: ValueKey(state.items[index - 1].id),
                          request: state.items[index - 1],
                        );
                      },
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
  }
}

class _RequestHistoryCard extends StatelessWidget {
  const _RequestHistoryCard({super.key, required this.request});
  final ServiceRequest request;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: AppSpacing.md),
    child: PressableScale(
      builder: (states) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          statesController: states,
          onTap: () => context.pushNamed(
            AppRouteNames.serviceRequestDetail,
            pathParameters: {'requestId': request.id},
          ),
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'requests.status_${request.status.name}'.tr(),
                  style: context.textTheme.labelMedium?.copyWith(
                    color: request.status == ServiceRequestStatus.open
                        ? context.colors.secondary
                        : context.colors.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: AppSpacing.sm),
                Text(
                  request.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.titleLarge,
                ),
                SizedBox(height: AppSpacing.sm),
                Text(
                  request.categoryName(context.locale.languageCode),
                  style: context.textTheme.bodyMedium,
                ),
                SizedBox(height: AppSpacing.ms),
                Row(
                  children: [
                    const Icon(Icons.event_outlined, size: 18),
                    SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        formatRequestPreferredTime(
                          context,
                          request.preferredAt,
                        ),
                        style: context.textTheme.bodySmall,
                      ),
                    ),
                    const Icon(Icons.arrow_forward_rounded, size: 18),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
