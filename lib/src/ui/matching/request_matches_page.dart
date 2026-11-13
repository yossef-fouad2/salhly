import '../../data/models/matching.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/matching_repository.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import '../marketplace/marketplace_widgets.dart';
import 'matching_widgets.dart';
import 'request_matching_cubit.dart';

class RequestMatchesPage extends StatelessWidget {
  const RequestMatchesPage({
    super.key,
    required this.userId,
    required this.requestId,
  });
  final String userId;
  final String requestId;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => RequestMatchingCubit(
      userId: userId,
      requestId: requestId,
      repository: context.read<MatchingRepository>(),
      session: context.read<SessionBloc>(),
    )..refresh(),
    child: _RequestMatchesView(userId: userId, requestId: requestId),
  );
}

class _RequestMatchesView extends StatefulWidget {
  const _RequestMatchesView({required this.userId, required this.requestId});
  final String userId;
  final String requestId;

  @override
  State<_RequestMatchesView> createState() => _RequestMatchesViewState();
}

class _RequestMatchesViewState extends State<_RequestMatchesView>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  bool? _wasCurrent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    context.read<RequestMatchingCubit>().pageVisible = current;
    if (current && _wasCurrent == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.read<RequestMatchingCubit>().refreshIfStale(force: true);
        }
      });
    }
    _wasCurrent = current;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      context.read<RequestMatchingCubit>().pageVisible =
          state == AppLifecycleState.resumed && _wasCurrent != false;
    }
    if (state == AppLifecycleState.resumed && _wasCurrent != false && mounted) {
      context.read<RequestMatchingCubit>().refreshIfStale(force: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  void _back() => context.canPop()
      ? context.pop()
      : context.goNamed(
          AppRouteNames.requestQuotes,
          pathParameters: {'requestId': widget.requestId},
        );

  Future<void> _quotes() async {
    final cubit = context.read<RequestMatchingCubit>();
    if (!cubit.active) return;
    await context.pushNamed(
      AppRouteNames.requestQuotes,
      pathParameters: {'requestId': widget.requestId},
    );
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<RequestMatchingCubit>();
    return BlocConsumer<RequestMatchingCubit, RequestMatchingState>(
      listenWhen: (previous, current) =>
          previous.errorMessage != current.errorMessage,
      listener: (context, state) {
        if (state.errorMessage != null && cubit.active) {
          context.showErrorSnackBar(state.errorMessage!.tr());
        }
      },
      buildWhen: (previous, current) =>
          previous.results != current.results ||
          previous.appliedQuery != current.appliedQuery ||
          previous.operation != current.operation ||
          previous.stale != current.stale ||
          previous.revoked != current.revoked ||
          previous.errorMessage != current.errorMessage ||
          previous.formVersion != current.formVersion ||
          previous.hasUnappliedChanges != current.hasUnappliedChanges,
      builder: (context, state) {
        if (state.revoked) return const SizedBox.shrink();
        final results = state.results;
        return MarketplaceScaffold(
          userId: widget.userId,
          role: UserRole.customer,
          titleKey: 'matching.title',
          onBack: _back,
          onRefresh: state.busy ? null : cubit.refresh,
          child: RefreshIndicator(
            onRefresh: cubit.refresh,
            child: ListView.builder(
              controller: _scrollController,
              key: PageStorageKey(
                'matching-list-${widget.userId}-${widget.requestId}',
              ),
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.all(AppSpacing.pagePadding),
              itemCount: (results?.items.length ?? 0) + 2,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String> ||
                    !key.value.startsWith('matching-provider-')) {
                  return null;
                }
                final providerId = key.value.substring(
                  'matching-provider-'.length,
                );
                final index =
                    results?.items.indexWhere(
                      (item) => item.providerId == providerId,
                    ) ??
                    -1;
                return index < 0 ? null : index + 1;
              },
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      MatchingFeedback(
                        loading: state.operation == MatchingOperation.loading,
                        loadingKey: results == null
                            ? 'matching.loading'
                            : 'matching.refreshing',
                        errorMessage: state.errorMessage,
                        onRetry: state.busy
                            ? null
                            : state.hasUnappliedChanges
                            ? cubit.apply
                            : cubit.refresh,
                      ),
                      if (context.read<MatchingRepository>().isDemo)
                        const MatchingDemoNotice(),
                      Text(
                        'matching.heading'.tr(),
                        style: context.textTheme.headlineSmall,
                      ),
                      SizedBox(height: AppSpacing.sm),
                      Text('matching.intro'.tr()),
                      SizedBox(height: AppSpacing.md),
                      Text(
                        'matching.no_action'.tr(),
                        style: context.textTheme.bodySmall,
                      ),
                      SizedBox(height: AppSpacing.md),
                      AppButton(
                        key: const ValueKey('matching-open-quotes'),
                        label: 'matching.compare_quotes'.tr(),
                        variant: ButtonVariant.outline,
                        onPressed: _quotes,
                      ),
                      SizedBox(height: AppSpacing.lg),
                      if (results != null) ...[
                        MarketplaceListingCard(listing: results.listing),
                        SizedBox(height: AppSpacing.md),
                      ],
                      _MatchingInputs(
                        key: ValueKey('matching-form-${state.formVersion}'),
                      ),
                      SizedBox(height: AppSpacing.md),
                      const _MatchingModeControl(),
                      SizedBox(height: AppSpacing.md),
                      if (state.showingPrevious) ...[
                        Semantics(
                          liveRegion: true,
                          child: Text('matching.previous_results'.tr()),
                        ),
                        SizedBox(height: AppSpacing.md),
                      ],
                      if (results != null) ...[
                        MatchingRulesCard(rules: results.rules),
                        SizedBox(height: AppSpacing.lg),
                        Text(
                          (results.mode == MatchMode.recommended
                                  ? 'matching.recommended'
                                  : 'matching.all_eligible')
                              .tr(),
                          style: context.textTheme.titleLarge,
                        ),
                        SizedBox(height: AppSpacing.sm),
                        Text(
                          (results.mode == MatchMode.recommended
                                  ? 'matching.recommended_note'
                                  : 'matching.all_note')
                              .tr(),
                        ),
                        SizedBox(height: AppSpacing.lg),
                      ],
                    ],
                  );
                }
                if (index == (results?.items.length ?? 0) + 1) {
                  if (results?.hasMore == true) {
                    return AppButton(
                      key: const ValueKey('matching-load-more'),
                      label: 'matching.load_more'.tr(),
                      variant: ButtonVariant.outline,
                      isLoading: state.busy,
                      onPressed: state.canLoadMore ? cubit.loadMore : null,
                    );
                  }
                  if (results != null && results.items.isEmpty) {
                    return AppEmptyState(
                      icon: Icons.people_outline_rounded,
                      title: 'matching.empty_title'.tr(),
                      subtitle: 'matching.empty_body'.tr(),
                    );
                  }
                  return const SizedBox.shrink();
                }
                final match = results!.items[index - 1];
                return Padding(
                  key: ValueKey('matching-provider-${match.providerId}'),
                  padding: EdgeInsets.only(bottom: AppSpacing.md),
                  child: ProviderMatchCard(
                    match: match,
                    rules: results.rules,
                    userId: widget.userId,
                    requestId: widget.requestId,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _MatchingModeControl extends StatelessWidget {
  const _MatchingModeControl();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<RequestMatchingCubit>();
    final mode = context.select(
      (RequestMatchingCubit cubit) => cubit.state.query.mode,
    );
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final value in MatchMode.values)
          ChoiceChip(
            key: ValueKey('matching-mode-${value.wireName}'),
            label: Text(
              (value == MatchMode.recommended
                      ? 'matching.recommended'
                      : 'matching.all_eligible')
                  .tr(),
            ),
            selected: mode == value,
            onSelected: (selected) {
              if (selected) cubit.setMode(value);
            },
          ),
      ],
    );
  }
}

class _MatchingInputs extends StatelessWidget {
  const _MatchingInputs({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<RequestMatchingCubit>();
    final query = cubit.state.query;
    return AppCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        key: const PageStorageKey('matching-optional-inputs'),
        title: Text('matching.inputs_title'.tr()),
        subtitle: Text('matching.inputs_optional'.tr()),
        tilePadding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
        childrenPadding: EdgeInsets.all(AppSpacing.md),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('matching.location_guidance'.tr()),
              SizedBox(height: AppSpacing.md),
              AppTextField(
                key: const PageStorageKey('matching-query-latitude'),
                label: 'matching.query_latitude'.tr(),
                hint: 'matching.latitude_example'.tr(),
                initialValue: query.latitude,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: cubit.updateLatitude,
              ),
              SizedBox(height: AppSpacing.formFieldGap),
              AppTextField(
                key: const PageStorageKey('matching-query-longitude'),
                label: 'matching.query_longitude'.tr(),
                hint: 'matching.longitude_example'.tr(),
                initialValue: query.longitude,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: cubit.updateLongitude,
              ),
              SizedBox(height: AppSpacing.md),
              BlocSelector<RequestMatchingCubit, RequestMatchingState, bool>(
                selector: (state) => state.query.locationConsent,
                builder: (context, consent) => CheckboxListTile(
                  key: const ValueKey('matching-query-location-consent'),
                  value: consent,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('matching.query_consent'.tr()),
                  onChanged: (value) =>
                      cubit.setLocationConsent(value ?? false),
                ),
              ),
              SizedBox(height: AppSpacing.lg),
              Text('matching.time_guidance'.tr()),
              SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<int>(
                key: const ValueKey('matching-query-weekday'),
                initialValue: query.weekday,
                isExpanded: true,
                decoration: InputDecoration(labelText: 'matching.weekday'.tr()),
                hint: Text('matching.no_day'.tr()),
                items: [
                  DropdownMenuItem<int>(
                    value: null,
                    child: Text('matching.no_day'.tr()),
                  ),
                  for (var day = 1; day <= 7; day++)
                    DropdownMenuItem(
                      value: day,
                      child: Text('provider.days.$day'.tr()),
                    ),
                ],
                onChanged: cubit.setWeekday,
              ),
              SizedBox(height: AppSpacing.formFieldGap),
              AppTextField(
                key: const PageStorageKey('matching-query-time'),
                label: 'matching.wall_time'.tr(),
                hint: 'matching.time_example'.tr(),
                initialValue: query.time,
                keyboardType: TextInputType.datetime,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: cubit.updateTime,
                onFieldSubmitted: (_) => cubit.apply(),
              ),
              SizedBox(height: AppSpacing.md),
              AppButton(
                key: const ValueKey('matching-apply-inputs'),
                label: 'matching.apply_inputs'.tr(),
                onPressed: () {
                  context.hideKeyboard();
                  cubit.apply();
                },
              ),
              SizedBox(height: AppSpacing.sm),
              AppButton(
                key: const ValueKey('matching-clear-inputs'),
                label: 'matching.clear_inputs'.tr(),
                variant: ButtonVariant.ghost,
                onPressed: cubit.clearInputs,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
