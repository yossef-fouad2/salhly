import '../../data/models/marketplace.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import 'marketplace_widgets.dart';
import 'provider_browse_cubit.dart';

class ProviderBrowsePage extends StatelessWidget {
  const ProviderBrowsePage({
    super.key,
    required this.userId,
    this.myQuotes = false,
  });
  final String userId;
  final bool myQuotes;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => ProviderBrowseCubit(
      userId: userId,
      myQuotes: myQuotes,
      repository: context.read<MarketplaceRepository>(),
      session: context.read<SessionBloc>(),
    )..refresh(),
    child: _ProviderBrowseView(userId: userId, myQuotes: myQuotes),
  );
}

class _ProviderBrowseView extends StatelessWidget {
  const _ProviderBrowseView({required this.userId, required this.myQuotes});
  final String userId;
  final bool myQuotes;

  Future<void> _open(BuildContext context, QuoteOpportunity item) async {
    final cubit = context.read<ProviderBrowseCubit>();
    await context.pushNamed(
      AppRouteNames.providerQuote,
      pathParameters: {'requestId': item.listing.requestId},
    );
    if (!cubit.isClosed) await cubit.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProviderBrowseCubit>();
    return BlocBuilder<ProviderBrowseCubit, ProviderBrowseState>(
      builder: (context, state) => MarketplaceScaffold(
        userId: userId,
        role: UserRole.provider,
        titleKey: myQuotes
            ? 'marketplace.my_quotes'
            : 'marketplace.browse_requests',
        onRefresh: state.busy || state.revoked ? null : cubit.refresh,
        child: RefreshIndicator(
          onRefresh: cubit.refresh,
          child: ListView.builder(
            key: PageStorageKey('marketplace-browse-$userId-$myQuotes'),
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
                      (myQuotes
                              ? 'marketplace.my_quotes_intro'
                              : 'marketplace.feed_intro')
                          .tr(),
                      style: context.textTheme.bodyLarge,
                    ),
                    SizedBox(height: AppSpacing.md),
                    Text(
                      'marketplace.feed_privacy'.tr(),
                      style: context.textTheme.bodySmall,
                    ),
                    SizedBox(height: AppSpacing.lg),
                    MarketplaceFeedback(
                      loading: state.loading,
                      errorMessage: state.errorMessage,
                      onRetry: state.busy || state.revoked
                          ? null
                          : cubit.refresh,
                    ),
                    if (!state.eligible) ...[
                      AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'marketplace.ineligible_title'.tr(),
                              style: context.textTheme.titleLarge,
                            ),
                            SizedBox(height: AppSpacing.sm),
                            Text('marketplace.ineligible_body'.tr()),
                            SizedBox(height: AppSpacing.md),
                            AppButton(
                              label: 'provider.open'.tr(),
                              variant: ButtonVariant.outline,
                              onPressed: () async {
                                await context.pushNamed(
                                  AppRouteNames.providerOnboarding,
                                );
                                if (!cubit.isClosed) await cubit.refresh();
                              },
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: AppSpacing.md),
                    ],
                  ],
                );
              }
              if (index == state.items.length + 1) {
                if (state.items.isEmpty && state.loaded && state.eligible) {
                  return AppEmptyState(
                    icon: myQuotes
                        ? Icons.request_quote_outlined
                        : Icons.search_outlined,
                    title:
                        (myQuotes
                                ? 'marketplace.quotes_empty_title'
                                : 'marketplace.feed_empty_title')
                            .tr(),
                    subtitle:
                        (myQuotes
                                ? 'marketplace.my_quotes_empty'
                                : 'marketplace.feed_empty_body')
                            .tr(),
                    actionLabel: myQuotes
                        ? 'marketplace.browse_requests'.tr()
                        : null,
                    onAction: myQuotes
                        ? () => context.pushNamed(
                            AppRouteNames.providerRequestFeed,
                          )
                        : null,
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
              final item = state.items[index - 1];
              final quote = item.quote;
              return Padding(
                key: ValueKey(item.listing.requestId),
                padding: EdgeInsets.only(bottom: AppSpacing.md),
                child: MarketplaceListingCard(
                  listing: item.listing,
                  onTap: () => _open(context, item),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (quote != null) ...[
                        Text(
                          'marketplace.quote_status.${quote.status.wireName}'
                              .tr(),
                          style: context.textTheme.labelLarge,
                        ),
                        SizedBox(height: AppSpacing.sm),
                        MarketplaceTerms(
                          amountMinor: quote.amountMinor,
                          durationMinutes: quote.durationMinutes,
                          notes: quote.notes,
                        ),
                        SizedBox(height: AppSpacing.md),
                      ],
                      AppButton(
                        label:
                            (quote == null
                                    ? 'marketplace.view_request'
                                    : 'marketplace.view_quote')
                                .tr(),
                        variant: ButtonVariant.outline,
                        onPressed: () => _open(context, item),
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
