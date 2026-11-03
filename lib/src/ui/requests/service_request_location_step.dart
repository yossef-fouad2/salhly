import '../../imports/imports.dart';
import 'service_request_form_cubit.dart';

String formatRequestPreferredTime(BuildContext context, DateTime? value) {
  if (value == null) return 'requests.flexible'.tr(context: context);
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return 'requests.preferred_value'.tr(
    context: context,
    namedArgs: {
      'date': material.formatMediumDate(local),
      'time': material.formatTimeOfDay(
        TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      ),
    },
  );
}

class ServiceRequestLocationStep extends StatelessWidget {
  const ServiceRequestLocationStep({super.key});

  Future<void> _chooseTime(BuildContext context) async {
    final cubit = context.read<ServiceRequestFormCubit>();
    context.hideKeyboard();
    final now = DateTime.now();
    final earliest = DateUtils.dateOnly(now);
    final latest = earliest.add(const Duration(days: 180));
    final preferred = cubit.state.draft.preferredAt?.toLocal();
    final initial =
        preferred != null &&
            !preferred.isBefore(earliest) &&
            !preferred.isAfter(latest)
        ? preferred
        : now.add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: earliest,
      lastDate: latest,
    );
    if (!context.mounted ||
        cubit.isClosed ||
        date == null ||
        !cubit.state.canEdit) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: preferred == null
          ? const TimeOfDay(hour: 9, minute: 0)
          : TimeOfDay.fromDateTime(preferred),
    );
    if (!context.mounted || cubit.isClosed || time == null) return;
    cubit.updatePreferredAt(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ServiceRequestFormCubit>();
    final enabled = context.select(
      (ServiceRequestFormCubit cubit) => cubit.state.canEdit,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'requests.location'.tr(),
                style: context.textTheme.titleLarge,
              ),
              SizedBox(height: AppSpacing.sm),
              Text(
                'requests.location_note'.tr(),
                style: context.textTheme.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              SizedBox(height: AppSpacing.lg),
              AppTextField(
                key: const ValueKey('request-city'),
                label: 'requests.city'.tr(),
                initialValue: cubit.state.draft.city,
                prefixIcon: const Icon(Icons.location_city_outlined),
                maxLength: 100,
                textInputAction: TextInputAction.next,
                enabled: enabled,
                onChanged: cubit.updateCity,
              ),
              SizedBox(height: AppSpacing.md),
              AppTextField(
                key: const ValueKey('request-address'),
                label: 'requests.address'.tr(),
                hint: 'requests.address_hint'.tr(),
                initialValue: cubit.state.draft.address,
                minLines: 3,
                maxLines: 6,
                maxLength: 500,
                keyboardType: TextInputType.multiline,
                enabled: enabled,
                onChanged: cubit.updateAddress,
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.md),
        AppCard(
          child:
              BlocSelector<
                ServiceRequestFormCubit,
                ServiceRequestFormState,
                DateTime?
              >(
                selector: (state) => state.draft.preferredAt,
                builder: (context, preferred) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'requests.preferred_time'.tr(),
                      style: context.textTheme.titleLarge,
                    ),
                    SizedBox(height: AppSpacing.sm),
                    Text(
                      'requests.time_note'.tr(),
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),
                    AppButton(
                      key: const ValueKey('request-preferred-time'),
                      label: preferred == null
                          ? 'requests.choose_time'.tr()
                          : formatRequestPreferredTime(context, preferred),
                      prefixIcon: const Icon(Icons.event_outlined),
                      variant: ButtonVariant.outline,
                      onPressed: enabled ? () => _chooseTime(context) : null,
                    ),
                    SizedBox(height: AppSpacing.sm),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: ChoiceChip(
                        label: Text('requests.flexible'.tr()),
                        selected: preferred == null,
                        onSelected: enabled
                            ? (_) => cubit.updatePreferredAt(null)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
        ),
      ],
    );
  }
}
