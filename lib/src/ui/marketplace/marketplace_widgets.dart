import '../../data/models/marketplace.dart';
import '../../data/models/user_model.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import 'marketplace_session.dart';

String marketplaceMoney(BuildContext context, int amountMinor) =>
    NumberFormat.currency(
      locale: context.locale.toString(),
      name: 'EGP',
      decimalDigits: 2,
    ).format(amountMinor / 100);

String marketplaceNumber(BuildContext context, int number) =>
    NumberFormat.decimalPattern(context.locale.toString()).format(number);

String marketplaceDate(BuildContext context, DateTime value) =>
    DateFormat.yMMMd(context.locale.toString())
        .add_jm()
        .format(value.toLocal());

class MarketplaceScaffold extends StatelessWidget {
  const MarketplaceScaffold({
    super.key,
    required this.userId,
    required this.titleKey,
    required this.child,
    this.role,
    this.onRefresh,
    this.onBack,
  });
  final String userId;
  final String titleKey;
  final UserRole? role;
  final Widget child;
  final VoidCallback? onRefresh;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    if (!context.select(
      (SessionBloc bloc) => marketplaceAuthorized(bloc.state, userId, role),
    )) {
      return const SizedBox.shrink();
    }
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed:
              onBack ??
              () => context.canPop()
                  ? context.pop()
                  : context.goNamed(AppRouteNames.home),
        ),
        title: Text(titleKey.tr()),
        actions: [
          if (onRefresh != null)
            IconButton(
              tooltip: 'marketplace.refresh'.tr(),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: child,
          ),
        ),
      ),
    );
  }
}

class MarketplaceDemoNotice extends StatelessWidget {
  const MarketplaceDemoNotice({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: AppSpacing.md),
    child: AppCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        key: const PageStorageKey('marketplace-demo-guide'),
        tilePadding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
        childrenPadding: EdgeInsets.all(AppSpacing.md),
        leading: const Icon(Icons.science_outlined),
        title: Text('marketplace.demo_title'.tr()),
        subtitle: Text('marketplace.demo_summary'.tr()),
        children: [SelectableText('marketplace.demo_body'.tr())],
      ),
    ),
  );
}

class MarketplaceFeedback extends StatelessWidget {
  const MarketplaceFeedback({
    super.key,
    this.loading = false,
    this.errorMessage,
    this.uncertain = false,
    this.onRetry,
    this.retryLabel = 'marketplace.refresh',
  });
  final bool loading;
  final String? errorMessage;
  final bool uncertain;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (loading) ...[
        LinearProgressIndicator(semanticsLabel: 'common.loading'.tr()),
        SizedBox(height: AppSpacing.md),
      ],
      if (errorMessage != null || uncertain) ...[
        Semantics(
          liveRegion: true,
          child: AppCard(
            color: context.colors.errorContainer,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  (errorMessage ?? 'marketplace.errors.uncertain').tr(),
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colors.onErrorContainer,
                  ),
                ),
                if (uncertain &&
                    errorMessage != 'marketplace.errors.uncertain') ...[
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    'marketplace.pending_note'.tr(),
                    style: TextStyle(color: context.colors.onErrorContainer),
                  ),
                ],
                SizedBox(height: AppSpacing.sm),
                AppButton(
                  key: ValueKey(
                    uncertain
                        ? 'marketplace-retry-original'
                        : 'marketplace-retry-load',
                  ),
                  label: (uncertain ? 'marketplace.retry_original' : retryLabel)
                      .tr(),
                  variant: ButtonVariant.outline,
                  onPressed: onRetry,
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: AppSpacing.md),
      ],
    ],
  );
}

class MarketplaceListingCard extends StatelessWidget {
  const MarketplaceListingCard({
    super.key,
    required this.listing,
    this.child,
    this.onTap,
  });
  final MarketplaceListing listing;
  final Widget? child;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => AppCard(
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          listing.categoryName(context.locale.languageCode),
          style: context.textTheme.labelLarge?.copyWith(
            color: context.colors.secondary,
          ),
        ),
        SizedBox(height: AppSpacing.sm),
        Text(listing.summary, style: context.textTheme.titleLarge),
        SizedBox(height: AppSpacing.md),
        Text('marketplace.city_value'.tr(namedArgs: {'city': listing.city})),
        SizedBox(height: AppSpacing.xs),
        Text(
          'marketplace.published_at'.tr(
            namedArgs: {'date': marketplaceDate(context, listing.publishedAt)},
          ),
          style: context.textTheme.bodySmall,
        ),
        if (child != null) ...[SizedBox(height: AppSpacing.md), child!],
      ],
    ),
  );
}

class MarketplaceTerms extends StatelessWidget {
  const MarketplaceTerms({
    super.key,
    required this.amountMinor,
    required this.durationMinutes,
    required this.notes,
  });
  final int amountMinor;
  final int durationMinutes;
  final String notes;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        marketplaceMoney(context, amountMinor),
        style: context.textTheme.headlineSmall,
      ),
      SizedBox(height: AppSpacing.sm),
      Text(
        'marketplace.duration_value'.tr(
          namedArgs: {'minutes': marketplaceNumber(context, durationMinutes)},
        ),
      ),
      if (notes.isNotEmpty) ...[
        SizedBox(height: AppSpacing.md),
        Text('marketplace.notes'.tr(), style: context.textTheme.labelLarge),
        SizedBox(height: AppSpacing.xs),
        Text(notes),
      ],
    ],
  );
}

class MarketplaceQuoteCard extends StatelessWidget {
  const MarketplaceQuoteCard({
    super.key,
    required this.quote,
    this.onAccept,
    this.showAccept = false,
  });
  final ProviderQuote quote;
  final VoidCallback? onAccept;
  final bool showAccept;
  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(quote.providerName, style: context.textTheme.titleLarge),
        SizedBox(height: AppSpacing.sm),
        Text(
          'marketplace.quote_status.${quote.status.wireName}'.tr(),
          style: context.textTheme.labelLarge,
        ),
        SizedBox(height: AppSpacing.md),
        MarketplaceTerms(
          amountMinor: quote.amountMinor,
          durationMinutes: quote.durationMinutes,
          notes: quote.notes,
        ),
        SizedBox(height: AppSpacing.md),
        Text(
          'marketplace.revision_value'.tr(
            namedArgs: {
              'revision': marketplaceNumber(context, quote.revision),
              'date': marketplaceDate(context, quote.updatedAt),
            },
          ),
          style: context.textTheme.bodySmall,
        ),
        if (showAccept) ...[
          SizedBox(height: AppSpacing.md),
          AppButton(
            key: ValueKey('accept-quote-${quote.id}'),
            label: 'marketplace.review_accept'.tr(),
            onPressed: onAccept,
          ),
        ],
      ],
    ),
  );
}

Future<bool> marketplaceConfirm(
  BuildContext context, {
  required String titleKey,
  required String bodyKey,
  required String confirmKey,
  String cancelKey = 'common.cancel',
  Widget? details,
}) async {
  final session = context.read<SessionBloc>();
  final user = session.state.user;
  if (user == null) return false;
  final confirmed = await context.showAppDialog<bool>(
    builder: (dialogContext) => BlocBuilder<SessionBloc, SessionState>(
      bloc: session,
      builder: (context, state) =>
          !marketplaceAuthorized(state, user.id, user.role)
          ? const SizedBox.shrink()
          : AlertDialog(
              title: Text(titleKey.tr()),
              scrollable: true,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (details != null) ...[
                    details,
                    SizedBox(height: AppSpacing.lg),
                  ],
                  Text(bodyKey.tr()),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(cancelKey.tr()),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(confirmKey.tr()),
                ),
              ],
            ),
    ),
  );
  return confirmed == true &&
      marketplaceAuthorized(session.state, user.id, user.role);
}

/// Retains an ambiguous operation's exact inputs until its retry resolves.
class MarketplaceExitScope extends StatefulWidget {
  const MarketplaceExitScope({
    super.key,
    required this.userId,
    required this.busy,
    required this.uncertain,
    required this.dirty,
    required this.builder,
    this.fallbackRoute = AppRouteNames.home,
  });
  final String userId;
  final bool busy;
  final bool uncertain;
  final bool dirty;
  final String fallbackRoute;
  final Widget Function(VoidCallback back) builder;
  @override
  State<MarketplaceExitScope> createState() => _MarketplaceExitScopeState();
}

class _MarketplaceExitScopeState extends State<MarketplaceExitScope> {
  bool _allowExit = false;
  bool _asking = false;

  void _back() =>
      context.canPop() ? context.pop() : context.goNamed(widget.fallbackRoute);

  Future<void> _leave() async {
    if (widget.busy || widget.uncertain) {
      context.showSnackBar(
        (widget.uncertain
                ? 'marketplace.resolve_before_leaving'
                : 'marketplace.wait_operation')
            .tr(),
      );
      return;
    }
    if (!widget.dirty || _allowExit) return _back();
    if (_asking) return;
    _asking = true;
    final discard = await marketplaceConfirm(
      context,
      titleKey: 'marketplace.discard_title',
      bodyKey: 'marketplace.discard_body',
      confirmKey: 'marketplace.discard',
      cancelKey: 'marketplace.keep_editing',
    );
    _asking = false;
    if (!mounted ||
        !discard ||
        !marketplaceAuthorized(
          context.read<SessionBloc>().state,
          widget.userId,
        )) {
      return;
    }
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) _back();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !widget.busy && !widget.uncertain && (!widget.dirty || _allowExit),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave();
    },
    child: widget.builder(_leave),
  );
}
