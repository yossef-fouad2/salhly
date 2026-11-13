import '../../data/models/marketplace.dart';
import '../../data/models/service_request.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import 'marketplace_widgets.dart';
import 'provider_quote_cubit.dart';

class ProviderQuotePage extends StatelessWidget {
  const ProviderQuotePage({
    super.key,
    required this.userId,
    required this.requestId,
  });
  final String userId;
  final String requestId;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => ProviderQuoteCubit(
      userId: userId,
      requestId: requestId,
      repository: context.read<MarketplaceRepository>(),
      session: context.read<SessionBloc>(),
    )..load(),
    child: _ProviderQuoteView(userId: userId),
  );
}

class _ProviderQuoteView extends StatefulWidget {
  const _ProviderQuoteView({required this.userId});
  final String userId;
  @override
  State<_ProviderQuoteView> createState() => _ProviderQuoteViewState();
}

class _ProviderQuoteViewState extends State<_ProviderQuoteView> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final cubit = context.read<ProviderQuoteCubit>();
    if (cubit.state.busy || cubit.state.uncertain) return;
    if (cubit.state.hasUnsavedChanges) {
      final reload = await marketplaceConfirm(
        context,
        titleKey: 'marketplace.reload_title',
        bodyKey: 'marketplace.reload_body',
        confirmKey: 'marketplace.reload',
        cancelKey: 'marketplace.keep_editing',
      );
      if (!mounted || !reload || cubit.isClosed) return;
    }
    await cubit.load(discardEdits: true);
  }

  Future<void> _withdraw() async {
    final cubit = context.read<ProviderQuoteCubit>();
    if (!cubit.state.canWithdraw) return;
    final withdraw = await marketplaceConfirm(
      context,
      titleKey: 'marketplace.withdraw_title',
      bodyKey: 'marketplace.withdraw_body',
      confirmKey: 'marketplace.withdraw',
    );
    if (mounted && withdraw && !cubit.isClosed) await cubit.withdraw();
  }

  void _listen(BuildContext context, ProviderQuoteState state) {
    if (state.notice != null) context.showSuccessSnackBar(state.notice!.tr());
    if (state.errorMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProviderQuoteCubit>();
    return BlocConsumer<ProviderQuoteCubit, ProviderQuoteState>(
      listenWhen: (previous, current) =>
          previous.notice != current.notice ||
          previous.errorMessage != current.errorMessage,
      listener: _listen,
      buildWhen: (previous, current) =>
          previous.opportunity != current.opportunity ||
          previous.operation != current.operation ||
          previous.uncertain != current.uncertain ||
          previous.formVersion != current.formVersion ||
          previous.revoked != current.revoked ||
          previous.errorMessage != current.errorMessage ||
          previous.hasUnsavedChanges != current.hasUnsavedChanges,
      builder: (context, state) {
        final opportunity = state.opportunity;
        final quote = opportunity?.quote;
        return MarketplaceExitScope(
          userId: widget.userId,
          busy:
              state.operation == ProviderQuoteOperation.saving ||
              state.operation == ProviderQuoteOperation.withdrawing,
          uncertain: state.uncertain,
          dirty: state.hasUnsavedChanges,
          fallbackRoute: AppRouteNames.providerRequestFeed,
          builder: (back) => MarketplaceScaffold(
            userId: widget.userId,
            role: UserRole.provider,
            titleKey: 'marketplace.quote_title',
            onBack: back,
            onRefresh: state.busy || state.uncertain || state.revoked
                ? null
                : _refresh,
            child: opportunity == null
                ? state.busy
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
                          onAction: state.revoked ? null : _refresh,
                        )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      controller: _scrollController,
                      key: PageStorageKey(
                        'marketplace-quote-${widget.userId}-${opportunity.listing.requestId}',
                      ),
                      physics: const AlwaysScrollableScrollPhysics(),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: EdgeInsets.all(AppSpacing.pagePadding),
                      children: [
                        MarketplaceFeedback(
                          loading:
                              state.operation == ProviderQuoteOperation.loading,
                          errorMessage: state.errorMessage,
                          uncertain: state.uncertain,
                          onRetry: state.busy
                              ? null
                              : state.uncertain
                              ? cubit.retryPending
                              : _refresh,
                        ),
                        if (context.read<MarketplaceRepository>().isDemo)
                          const MarketplaceDemoNotice(),
                        MarketplaceListingCard(listing: opportunity.listing),
                        SizedBox(height: AppSpacing.md),
                        Text(
                          'marketplace.feed_privacy'.tr(),
                          style: context.textTheme.bodySmall,
                        ),
                        if (quote != null) ...[
                          SizedBox(height: AppSpacing.lg),
                          Text(
                            'marketplace.submitted_terms'.tr(),
                            style: context.textTheme.titleLarge,
                          ),
                          SizedBox(height: AppSpacing.md),
                          MarketplaceQuoteCard(quote: quote),
                        ],
                        SizedBox(height: AppSpacing.lg),
                        if (opportunity.canQuote && state.mutableTerms) ...[
                          AppCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  (quote == null
                                          ? 'marketplace.new_quote'
                                          : 'marketplace.edit_quote')
                                      .tr(),
                                  style: context.textTheme.titleLarge,
                                ),
                                SizedBox(height: AppSpacing.sm),
                                Text('marketplace.quote_rules'.tr()),
                                SizedBox(height: AppSpacing.lg),
                                _QuoteFields(key: ValueKey(state.formVersion)),
                                SizedBox(height: AppSpacing.md),
                                Text(
                                  'marketplace.quote_disclosure'.tr(),
                                  style: context.textTheme.bodyMedium,
                                ),
                                SizedBox(height: AppSpacing.lg),
                                AppButton(
                                  key: const ValueKey('marketplace-save-quote'),
                                  label:
                                      (quote?.status == QuoteStatus.withdrawn
                                              ? 'marketplace.reactivate'
                                              : quote == null
                                              ? 'marketplace.send_quote'
                                              : 'marketplace.update_quote')
                                          .tr(),
                                  isLoading:
                                      state.operation ==
                                      ProviderQuoteOperation.saving,
                                  onPressed: state.canEdit
                                      ? () {
                                          context.hideKeyboard();
                                          cubit.save();
                                        }
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        ] else ...[
                          AppCard(
                            child: Text(
                              (opportunity.listing.requestStatus ==
                                          ServiceRequestStatus.open
                                      ? 'marketplace.ineligible_body'
                                      : 'marketplace.quote_closed')
                                  .tr(),
                            ),
                          ),
                        ],
                        if (quote?.status == QuoteStatus.pending) ...[
                          SizedBox(height: AppSpacing.md),
                          AppButton(
                            key: const ValueKey('marketplace-withdraw-quote'),
                            label: 'marketplace.withdraw'.tr(),
                            variant: ButtonVariant.outline,
                            isLoading:
                                state.operation ==
                                ProviderQuoteOperation.withdrawing,
                            onPressed: state.canWithdraw ? _withdraw : null,
                          ),
                        ],
                        if (quote?.status == QuoteStatus.accepted) ...[
                          SizedBox(height: AppSpacing.md),
                          AppButton(
                            label: 'marketplace.jobs'.tr(),
                            onPressed: state.busy || state.uncertain
                                ? null
                                : () => context.pushNamed(AppRouteNames.jobs),
                          ),
                        ],
                        SizedBox(height: AppSpacing.md),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _QuoteFields extends StatelessWidget {
  const _QuoteFields({super.key});
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProviderQuoteCubit>();
    final enabled = context.select(
      (ProviderQuoteCubit cubit) => cubit.state.canEdit,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          key: const ValueKey('marketplace-quote-amount'),
          label: 'marketplace.amount'.tr(),
          initialValue: cubit.state.draft.amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          enabled: enabled,
          onChanged: cubit.updateAmount,
        ),
        SizedBox(height: AppSpacing.formFieldGap),
        AppTextField(
          key: const ValueKey('marketplace-quote-duration'),
          label: 'marketplace.duration'.tr(),
          initialValue: cubit.state.draft.duration,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          enabled: enabled,
          onChanged: cubit.updateDuration,
        ),
        SizedBox(height: AppSpacing.formFieldGap),
        AppTextField(
          key: const ValueKey('marketplace-quote-notes'),
          label: 'marketplace.notes_optional'.tr(),
          initialValue: cubit.state.draft.notes,
          keyboardType: TextInputType.multiline,
          minLines: 3,
          maxLines: 8,
          maxLength: 1000,
          enabled: enabled,
          onChanged: cubit.updateNotes,
        ),
      ],
    );
  }
}
