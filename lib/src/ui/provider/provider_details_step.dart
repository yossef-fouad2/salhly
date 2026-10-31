import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_empty_state.dart';
import '../../shared/widgets/app_text_field.dart';
import '../../theme/theme_constants.dart';
import 'provider_onboarding_cubit.dart';

class ProviderDetailsStep extends StatelessWidget {
  const ProviderDetailsStep({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProviderOnboardingCubit>();
    final canEdit = context.select(
      (ProviderOnboardingCubit cubit) => cubit.state.canEdit,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          title: 'provider.about_title'.tr(),
          subtitle: 'provider.about_hint'.tr(),
          child: Padding(
            padding: EdgeInsets.only(top: AppSpacing.md),
            child: AppTextField(
              key: const ValueKey('provider-bio'),
              label: 'provider.bio'.tr(),
              initialValue: cubit.state.profile!.bio,
              onChanged: cubit.updateBio,
              enabled: canEdit,
              minLines: 3,
              maxLines: 5,
              maxLength: 1000,
              keyboardType: TextInputType.multiline,
            ),
          ),
        ),
        SizedBox(height: AppSpacing.md),
        const _Skills(),
      ],
    );
  }
}

class _Skills extends StatelessWidget {
  const _Skills();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProviderOnboardingCubit, ProviderOnboardingState>(
      buildWhen: (previous, current) =>
          previous.canEdit != current.canEdit ||
          !listEquals(previous.categories, current.categories) ||
          !listEquals(previous.profile?.skillIds, current.profile?.skillIds),
      builder: (context, state) => AppCard(
        title: 'provider.skills_title'.tr(),
        subtitle: 'provider.skills_hint'.tr(),
        child: state.categories.isEmpty && state.profile!.skillIds.isEmpty
            ? AppEmptyState(
                title: 'home.no_categories'.tr(),
                actionLabel: 'common.retry'.tr(),
                onAction: state.isBusy
                    ? null
                    : context.read<ProviderOnboardingCubit>().load,
              )
            : Padding(
                padding: EdgeInsets.only(top: AppSpacing.md),
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final category in state.categories)
                      FilterChip(
                        key: ValueKey('provider-skill-${category.id}'),
                        label: Text(category.name(context.locale.languageCode)),
                        selected: state.profile!.skillIds.contains(category.id),
                        onSelected: state.canEdit
                            ? (_) => context
                                  .read<ProviderOnboardingCubit>()
                                  .toggleSkill(category.id)
                            : null,
                      ),
                    for (final id in state.profile!.skillIds)
                      if (!state.categories.any(
                        (category) => category.id == id,
                      ))
                        FilterChip(
                          key: ValueKey('provider-skill-$id'),
                          label: Text('provider.unavailable_service'.tr()),
                          selected: true,
                          onSelected: state.canEdit
                              ? (_) => context
                                    .read<ProviderOnboardingCubit>()
                                    .toggleSkill(id)
                              : null,
                        ),
                  ],
                ),
              ),
      ),
    );
  }
}
