import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/provider_profile.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_text_field.dart';
import '../../theme/theme_constants.dart';
import 'provider_onboarding_cubit.dart';

class ProviderCoverageStep extends StatelessWidget {
  const ProviderCoverageStep({super.key});

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
          title: 'provider.areas_title'.tr(),
          subtitle: 'provider.areas_hint'.tr(),
          child: Padding(
            padding: EdgeInsets.only(top: AppSpacing.md),
            child: AppTextField(
              key: const ValueKey('provider-areas'),
              label: 'provider.areas'.tr(),
              initialValue: cubit.state.profile!.serviceAreas.join('\n'),
              onChanged: cubit.updateAreas,
              enabled: canEdit,
              minLines: 3,
              maxLines: 5,
              maxLength: 1009,
              keyboardType: TextInputType.multiline,
            ),
          ),
        ),
        SizedBox(height: AppSpacing.md),
        AppCard(
          title: 'provider.hours_title'.tr(),
          subtitle: 'provider.hours_hint'.tr(),
          child: Column(
            children: [
              for (var weekday = 1; weekday <= 7; weekday++)
                _DayHours(weekday: weekday),
            ],
          ),
        ),
      ],
    );
  }
}

class _DayHours extends StatelessWidget {
  const _DayHours({required this.weekday});

  final int weekday;

  @override
  Widget build(BuildContext context) {
    final (canEdit, hours) = context.select(
      (ProviderOnboardingCubit cubit) => (
        cubit.state.canEdit,
        cubit.state.profile!.availability
            .where((item) => item.weekday == weekday)
            .firstOrNull,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile.adaptive(
          key: ValueKey('provider-day-$weekday'),
          contentPadding: EdgeInsets.zero,
          title: Text('provider.days.$weekday'.tr()),
          value: hours != null,
          onChanged: canEdit
              ? (enabled) =>
                    context.read<ProviderOnboardingCubit>().updateAvailability(
                      weekday,
                      enabled
                          ? ProviderAvailability(
                              weekday: weekday,
                              startMinute: 9 * 60,
                              endMinute: 17 * 60,
                            )
                          : null,
                    )
              : null,
        ),
        if (hours != null)
          Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final isStart in [true, false])
                  OutlinedButton(
                    key: ValueKey(
                      'provider-${isStart ? 'start' : 'end'}-$weekday',
                    ),
                    onPressed: canEdit
                        ? () => _pickTime(context, hours, isStart)
                        : null,
                    child: Text(
                      (isStart ? 'provider.from_time' : 'provider.to_time').tr(
                        namedArgs: {
                          'time': _formatTime(
                            context,
                            isStart ? hours.startMinute : hours.endMinute,
                          ),
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _formatTime(BuildContext context, int minutes) => minutes == 1440
      ? 'provider.end_of_day'.tr()
      : TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(context);

  Future<void> _pickTime(
    BuildContext context,
    ProviderAvailability hours,
    bool isStart,
  ) async {
    final minutes = isStart ? hours.startMinute : hours.endMinute % 1440;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      helpText: (isStart ? 'provider.start_time' : 'provider.end_time').tr(),
    );
    if (!context.mounted || selected == null) return;
    final value = selected.hour * 60 + selected.minute;
    context.read<ProviderOnboardingCubit>().updateAvailability(
      weekday,
      ProviderAvailability(
        weekday: weekday,
        startMinute: isStart ? value : hours.startMinute,
        endMinute: isStart ? hours.endMinute : (value == 0 ? 1440 : value),
      ),
    );
  }
}
