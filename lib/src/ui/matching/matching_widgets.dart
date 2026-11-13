import 'dart:async';

import '../../data/models/matching.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import '../marketplace/marketplace_session.dart';

String matchingNumber(BuildContext context, num value) =>
    NumberFormat('0.##', context.locale.toString()).format(value);

class MatchingFeedback extends StatelessWidget {
  const MatchingFeedback({
    super.key,
    this.loading = false,
    this.loadingKey = 'matching.loading',
    this.errorMessage,
    this.uncertain = false,
    this.onRetry,
  });

  final bool loading;
  final String loadingKey;
  final String? errorMessage;
  final bool uncertain;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (loading) ...[
        LinearProgressIndicator(semanticsLabel: loadingKey.tr()),
        SizedBox(height: AppSpacing.sm),
        Semantics(liveRegion: true, child: Text(loadingKey.tr())),
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
                  (errorMessage ?? 'matching.errors.uncertain').tr(),
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colors.onErrorContainer,
                  ),
                ),
                if (uncertain &&
                    errorMessage != 'matching.errors.uncertain') ...[
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    'matching.pending_note'.tr(),
                    style: TextStyle(color: context.colors.onErrorContainer),
                  ),
                ],
                SizedBox(height: AppSpacing.md),
                AppButton(
                  key: ValueKey(
                    uncertain
                        ? 'matching-retry-original'
                        : 'matching-retry-load',
                  ),
                  label:
                      (uncertain
                              ? 'matching.retry_original'
                              : 'matching.refresh')
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

class MatchingDemoNotice extends StatelessWidget {
  const MatchingDemoNotice({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: AppSpacing.md),
    child: AppCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        key: const PageStorageKey('matching-demo-explanation'),
        leading: const Icon(Icons.science_outlined),
        title: Text('matching.demo_title'.tr()),
        subtitle: Text('matching.demo_summary'.tr()),
        tilePadding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
        childrenPadding: EdgeInsets.all(AppSpacing.md),
        children: [Text('matching.demo_body'.tr())],
      ),
    ),
  );
}

class MatchingRulesCard extends StatelessWidget {
  const MatchingRulesCard({super.key, required this.rules});
  final MatchingRules rules;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: ExpansionTile(
      key: const PageStorageKey('matching-rules-explanation'),
      title: Text('matching.rules_title'.tr()),
      subtitle: Text(
        'matching.rules_revision'.tr(
          namedArgs: {'revision': matchingNumber(context, rules.revision)},
        ),
      ),
      tilePadding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
      childrenPadding: EdgeInsets.all(AppSpacing.md),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('matching.rules_intro'.tr()),
            SizedBox(height: AppSpacing.md),
            for (final factor in MatchFactorKey.values) ...[
              Text(
                'matching.rule_weight'.tr(
                  namedArgs: {
                    'factor': 'matching.factors.${factor.name}'.tr(),
                    'weight': matchingNumber(context, rules.weightFor(factor)),
                    'total': matchingNumber(context, rules.totalWeight),
                    'share': matchingNumber(
                      context,
                      rules.weightFor(factor) * 100 / rules.totalWeight,
                    ),
                  },
                ),
              ),
              SizedBox(height: AppSpacing.sm),
            ],
            Text(
              'matching.rules_neutral'.tr(
                namedArgs: {
                  'neutral': matchingNumber(context, rules.neutralBps / 100),
                },
              ),
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              'matching.rules_scales'.tr(
                namedArgs: {
                  'distance': matchingNumber(context, rules.distanceScaleKm),
                  'years': matchingNumber(context, rules.experienceCapYears),
                },
              ),
            ),
            SizedBox(height: AppSpacing.md),
            Text('matching.evidence_note'.tr()),
            SizedBox(height: AppSpacing.md),
            Text('matching.tie_note'.tr()),
            SizedBox(height: AppSpacing.md),
            Text('matching.reliability_unavailable'.tr()),
          ],
        ),
      ],
    ),
  );
}

class ProviderMatchCard extends StatelessWidget {
  const ProviderMatchCard({
    super.key,
    required this.match,
    required this.rules,
    required this.userId,
    required this.requestId,
  });

  final ProviderMatch match;
  final MatchingRules rules;
  final String userId;
  final String requestId;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(match.providerName, style: context.textTheme.titleLarge),
        SizedBox(height: AppSpacing.sm),
        Text(
          'matching.eligible_label'.tr(),
          style: context.textTheme.bodySmall,
        ),
        SizedBox(height: AppSpacing.md),
        Text(
          'matching.total_value'.tr(
            namedArgs: {'score': matchingNumber(context, match.scoreBps / 100)},
          ),
          style: context.textTheme.headlineSmall,
        ),
        SizedBox(height: AppSpacing.sm),
        Text(
          'matching.evidence_value'.tr(
            namedArgs: {
              'evidence': matchingNumber(context, match.evidenceBps / 100),
            },
          ),
        ),
        SizedBox(height: AppSpacing.md),
        Text('matching.rating_unavailable'.tr()),
        SizedBox(height: AppSpacing.sm),
        Text('matching.not_a_quote'.tr(), style: context.textTheme.bodySmall),
        SizedBox(height: AppSpacing.md),
        ExpansionTile(
          key: PageStorageKey(
            'matching-factors-$userId-$requestId-${match.providerId}',
          ),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text('matching.explain'.tr()),
          children: [
            for (final factor in match.factors)
              Padding(
                key: ValueKey(
                  'matching-factor-${match.providerId}-${factor.key.name}',
                ),
                padding: EdgeInsets.only(bottom: AppSpacing.lg),
                child: _FactorExplanation(
                  match: match,
                  factor: factor,
                  rules: rules,
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

class _FactorExplanation extends StatelessWidget {
  const _FactorExplanation({
    required this.match,
    required this.factor,
    required this.rules,
  });
  final ProviderMatch match;
  final MatchFactor factor;
  final MatchingRules rules;

  static const _reasons = {
    'no_query_location',
    'no_provider_origin',
    'straight_line',
    'no_reviews',
    'no_time_preference',
    'no_declared_hours',
    'within_hours',
    'outside_hours',
    'no_experience',
    'self_reported',
  };

  String _value(BuildContext context) => switch (factor.key) {
    MatchFactorKey.distance =>
      match.distanceKm == null
          ? 'matching.distance_unavailable'.tr()
          : 'matching.distance_value'.tr(
              namedArgs: {
                'distance': matchingNumber(context, match.distanceKm!),
              },
            ),
    MatchFactorKey.rating => 'matching.rating_unavailable'.tr(),
    MatchFactorKey.availability =>
      (match.available == null
              ? 'matching.hours_unavailable'
              : match.available!
              ? 'matching.hours_inside'
              : 'matching.hours_outside')
          .tr(),
    MatchFactorKey.experience =>
      match.experienceYears == null
          ? 'matching.experience_unavailable'.tr()
          : 'matching.experience_value'.tr(
              namedArgs: {
                'years': matchingNumber(context, match.experienceYears!),
              },
            ),
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'matching.factors.${factor.key.name}'.tr(),
        style: context.textTheme.titleMedium,
      ),
      SizedBox(height: AppSpacing.xs),
      Text(_value(context)),
      SizedBox(height: AppSpacing.sm),
      Text(
        (_reasons.contains(factor.reason)
                ? 'matching.reasons.${factor.reason}'
                : 'matching.reason_unavailable')
            .tr(),
      ),
      SizedBox(height: AppSpacing.sm),
      if (factor.scoreBps == null) ...[
        Text(
          'matching.factor_neutral'.tr(
            namedArgs: {
              'neutral': matchingNumber(context, factor.effectiveBps / 100),
            },
          ),
        ),
        SizedBox(height: AppSpacing.sm),
      ],
      Text(
        'matching.factor_numbers'.tr(
          namedArgs: {
            'score': matchingNumber(context, factor.effectiveBps / 100),
            'weight': matchingNumber(context, factor.weight),
            'total': matchingNumber(context, rules.totalWeight),
            'contribution': matchingNumber(
              context,
              factor.effectiveBps * factor.weight / (100 * rules.totalWeight),
            ),
          },
        ),
      ),
    ],
  );
}

Future<bool> matchingConfirm(
  BuildContext context, {
  required String titleKey,
  required String bodyKey,
  required String confirmKey,
  String cancelKey = 'matching.keep_editing',
}) async {
  final session = context.read<SessionBloc>();
  final user = session.state.user;
  if (user == null) return false;
  final revoked = ValueNotifier(false);
  final guard = MarketplaceSession(
    session: session,
    userId: user.id,
    role: user.role,
    onRevoked: () => revoked.value = true,
  );
  try {
    final confirmed = await context.showAppDialog<bool>(
      builder: (dialogContext) => ValueListenableBuilder<bool>(
        valueListenable: revoked,
        builder: (context, _, _) => !guard.active
            ? const SizedBox.shrink()
            : AlertDialog(
                scrollable: true,
                title: Text(titleKey.tr()),
                content: Text(bodyKey.tr()),
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
    return confirmed == true && guard.active;
  } finally {
    // close revokes synchronously; subscription cleanup must not delay dialog actions.
    unawaited(guard.close());
    revoked.dispose();
  }
}
