import '../../data/models/marketplace.dart';
import '../../data/models/service_request.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/marketplace_repository.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import 'customer_quotes_cubit.dart';
import 'marketplace_widgets.dart';

class CustomerQuotesPage extends StatelessWidget {
  const CustomerQuotesPage({
    super.key,
    required this.userId,
    required this.requestId,
  });
  final String userId;
  final String requestId;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => CustomerQuotesCubit(
      userId: userId,
      requestId: requestId,
      repository: context.read<MarketplaceRepository>(),
      session: context.read<SessionBloc>(),
    )..refresh(),
    child: _CustomerQuotesView(userId: userId, requestId: requestId),
  );
}

class _CustomerQuotesView extends StatefulWidget {
  const _CustomerQuotesView({required this.userId, required this.requestId});
  final String userId;
  final String requestId;
  @override
  State<_CustomerQuotesView> createState() => _CustomerQuotesViewState();
}

class _CustomerQuotesViewState extends State<_CustomerQuotesView> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _accept(ProviderQuote quote) async {
    final cubit = context.read<CustomerQuotesCubit>();
    if (!cubit.state.canAccept) return;
    final accepted = await marketplaceConfirm(
      context,
      titleKey: 'marketplace.accept_title',
      bodyKey: 'marketplace.accept_consent',
      confirmKey: 'marketplace.accept_confirm',
      details: MarketplaceQuoteCard(quote: quote),
    );
    if (!mounted || !accepted || cubit.isClosed) return;
    await cubit.accept(quote, consent: true);
  }

  Future<void> _openJob(ServiceJob job) async {
    final cubit = context.read<CustomerQuotesCubit>();
    await context.pushNamed(
      AppRouteNames.jobDetail,
      pathParameters: {'jobId': job.id},
    );
    if (!cubit.isClosed) await cubit.refresh();
  }

  void _listen(BuildContext context, CustomerQuotesState state) {
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
    final cubit = context.read<CustomerQuotesCubit>();
    return BlocConsumer<CustomerQuotesCubit, CustomerQuotesState>(
      listenWhen: (previous, current) =>
          previous.notice != current.notice ||
          previous.errorMessage != current.errorMessage,
      listener: _listen,
      buildWhen: (previous, current) =>
          previous.book != current.book ||
          previous.operation != current.operation ||
          previous.uncertain != current.uncertain ||
          previous.revoked != current.revoked ||
          previous.errorMessage != current.errorMessage ||
          previous.hasUnsavedChanges != current.hasUnsavedChanges,
      builder: (context, state) {
        final book = state.book;
        return MarketplaceExitScope(
          userId: widget.userId,
          busy:
              state.operation == CustomerQuotesOperation.publishing ||
              state.operation == CustomerQuotesOperation.accepting,
          uncertain: state.uncertain,
          dirty: state.hasUnsavedChanges,
          fallbackRoute: AppRouteNames.serviceRequests,
          builder: (back) => MarketplaceScaffold(
            userId: widget.userId,
            role: UserRole.customer,
            titleKey: 'marketplace.request_quotes',
            onBack: back,
            onRefresh: state.busy || state.uncertain || state.revoked
                ? null
                : cubit.refresh,
            child: RefreshIndicator(
              onRefresh: cubit.refresh,
              child: ListView.builder(
                controller: _scrollController,
                key: PageStorageKey(
                  'marketplace-customer-${widget.userId}-${widget.requestId}',
                ),
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.all(AppSpacing.pagePadding),
                itemCount: (book?.quotes.length ?? 0) + 2,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        MarketplaceFeedback(
                          loading:
                              state.operation ==
                              CustomerQuotesOperation.loading,
                          errorMessage: state.errorMessage,
                          uncertain: state.uncertain,
                          onRetry: state.busy || state.revoked
                              ? null
                              : state.uncertain
                              ? cubit.retryPending
                              : cubit.refresh,
                        ),
                        if (context.read<MarketplaceRepository>().isDemo)
                          const MarketplaceDemoNotice(),
                        if (book != null &&
                            book.listing == null &&
                            book.requestStatus == ServiceRequestStatus.open)
                          const _PublishListingForm(),
                        if (book?.listing != null) ...[
                          Text(
                            'marketplace.shared_listing'.tr(),
                            style: context.textTheme.titleLarge,
                          ),
                          SizedBox(height: AppSpacing.md),
                          MarketplaceListingCard(listing: book!.listing!),
                          SizedBox(height: AppSpacing.sm),
                          Text(
                            'marketplace.published_privacy'.tr(),
                            style: context.textTheme.bodySmall,
                          ),
                          SizedBox(height: AppSpacing.lg),
                        ],
                        if (book?.job != null) ...[
                          _AcceptedJobCard(
                            job: book!.job!,
                            onOpen: state.busy || state.uncertain
                                ? null
                                : () => _openJob(book.job!),
                          ),
                          SizedBox(height: AppSpacing.lg),
                        ],
                        if (book?.requestStatus ==
                            ServiceRequestStatus.cancelled) ...[
                          Text(
                            'marketplace.request_closed'.tr(),
                            style: context.textTheme.bodyLarge,
                          ),
                          SizedBox(height: AppSpacing.lg),
                        ],
                        if (book?.listing != null && book?.job == null) ...[
                          if (book?.requestStatus ==
                              ServiceRequestStatus.open) ...[
                            AppButton(
                              key: const ValueKey(
                                'matching-open-request-matches',
                              ),
                              label: 'matching.open_matches'.tr(),
                              variant: ButtonVariant.outline,
                              prefixIcon: const Icon(
                                Icons.people_outline_rounded,
                              ),
                              onPressed:
                                  state.busy || state.uncertain || state.revoked
                                  ? null
                                  : () => context.pushNamed(
                                      AppRouteNames.requestMatches,
                                      pathParameters: {
                                        'requestId': widget.requestId,
                                      },
                                    ),
                            ),
                            SizedBox(height: AppSpacing.lg),
                          ],
                          Text(
                            'marketplace.compare_title'.tr(),
                            style: context.textTheme.titleLarge,
                          ),
                          SizedBox(height: AppSpacing.sm),
                          Text('marketplace.compare_note'.tr()),
                          SizedBox(height: AppSpacing.lg),
                        ],
                      ],
                    );
                  }
                  if (index == (book?.quotes.length ?? 0) + 1) {
                    if (book?.hasMore == true) {
                      return AppButton(
                        label: 'marketplace.load_more'.tr(),
                        variant: ButtonVariant.outline,
                        isLoading:
                            state.operation ==
                            CustomerQuotesOperation.loadingMore,
                        onPressed: state.busy || state.uncertain
                            ? null
                            : cubit.loadMore,
                      );
                    }
                    if (book != null &&
                        book.listing != null &&
                        book.job == null &&
                        book.quotes.isEmpty &&
                        book.requestStatus == ServiceRequestStatus.open) {
                      return AppEmptyState(
                        icon: Icons.request_quote_outlined,
                        title: 'marketplace.quotes_empty_title'.tr(),
                        subtitle: 'marketplace.customer_quotes_empty'.tr(),
                      );
                    }
                    return const SizedBox.shrink();
                  }
                  final quote = book!.quotes[index - 1];
                  return Padding(
                    key: ValueKey(quote.id),
                    padding: EdgeInsets.only(bottom: AppSpacing.md),
                    child: MarketplaceQuoteCard(
                      quote: quote,
                      showAccept:
                          quote.status == QuoteStatus.pending &&
                          book.requestStatus == ServiceRequestStatus.open,
                      onAccept: state.canAccept ? () => _accept(quote) : null,
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

class _PublishListingForm extends StatelessWidget {
  const _PublishListingForm();
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<CustomerQuotesCubit>();
    final enabled = context.select(
      (CustomerQuotesCubit cubit) => cubit.state.canPublish,
    );
    final publishing = context.select(
      (CustomerQuotesCubit cubit) =>
          cubit.state.operation == CustomerQuotesOperation.publishing,
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'marketplace.publish_title'.tr(),
            style: context.textTheme.headlineSmall,
          ),
          SizedBox(height: AppSpacing.sm),
          Text('marketplace.publish_intro'.tr()),
          SizedBox(height: AppSpacing.md),
          Text(
            'marketplace.public_guidance'.tr(),
            style: context.textTheme.bodyMedium,
          ),
          SizedBox(height: AppSpacing.lg),
          AppTextField(
            key: const ValueKey('marketplace-public-summary'),
            label: 'marketplace.public_summary'.tr(),
            initialValue: cubit.state.summary,
            minLines: 3,
            maxLines: 8,
            maxLength: 1000,
            keyboardType: TextInputType.multiline,
            enabled: enabled,
            onChanged: cubit.updateSummary,
          ),
          SizedBox(height: AppSpacing.formFieldGap),
          AppTextField(
            key: const ValueKey('marketplace-public-city'),
            label: 'marketplace.public_city'.tr(),
            initialValue: cubit.state.city,
            maxLength: 100,
            textInputAction: TextInputAction.done,
            enabled: enabled,
            onChanged: cubit.updateCity,
          ),
          SizedBox(height: AppSpacing.md),
          BlocSelector<CustomerQuotesCubit, CustomerQuotesState, bool>(
            selector: (state) => state.consent,
            builder: (context, consent) => CheckboxListTile(
              key: const ValueKey('marketplace-publish-consent'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text('marketplace.publish_consent'.tr()),
              value: consent,
              onChanged: enabled
                  ? (value) => cubit.setConsent(value ?? false)
                  : null,
            ),
          ),
          SizedBox(height: AppSpacing.md),
          AppButton(
            key: const ValueKey('marketplace-publish'),
            label: 'marketplace.publish'.tr(),
            isLoading: publishing,
            onPressed: enabled
                ? () {
                    context.hideKeyboard();
                    cubit.publish();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

class _AcceptedJobCard extends StatelessWidget {
  const _AcceptedJobCard({required this.job, required this.onOpen});
  final ServiceJob job;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'marketplace.selected_provider'.tr(),
          style: context.textTheme.titleLarge,
        ),
        SizedBox(height: AppSpacing.sm),
        Text(job.providerName, style: context.textTheme.titleMedium),
        SizedBox(height: AppSpacing.sm),
        Text('marketplace.job_status.${job.status.wireName}'.tr()),
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
        SizedBox(height: AppSpacing.md),
        AppButton(
          key: const ValueKey('marketplace-open-assigned-job'),
          label: 'marketplace.view_job'.tr(),
          onPressed: onOpen,
        ),
      ],
    ),
  );
}
