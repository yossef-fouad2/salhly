import '../../imports/imports.dart';
import 'service_request_form_cubit.dart';
import 'service_request_location_step.dart';

class ServiceRequestReviewStep extends StatelessWidget {
  const ServiceRequestReviewStep({super.key});

  @override
  Widget build(
    BuildContext context,
  ) => BlocBuilder<ServiceRequestFormCubit, ServiceRequestFormState>(
    builder: (context, state) {
      final draft = state.draft;
      final category = state.categories
          .where((category) => category.id == draft.categoryId)
          .firstOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  draft.title.trim(),
                  style: context.textTheme.headlineSmall,
                ),
                SizedBox(height: AppSpacing.md),
                _ReviewField(
                  label: 'requests.category'.tr(),
                  value:
                      category?.name(context.locale.languageCode) ??
                      'requests.errors.category'.tr(),
                ),
                _ReviewField(
                  label: 'requests.description'.tr(),
                  value: draft.description.trim(),
                ),
                _ReviewField(
                  label: 'requests.city'.tr(),
                  value: draft.city.trim(),
                ),
                _ReviewField(
                  label: 'requests.address'.tr(),
                  value: draft.address.trim(),
                ),
                _ReviewField(
                  label: 'requests.preferred_time'.tr(),
                  value: formatRequestPreferredTime(context, draft.preferredAt),
                ),
                _ReviewField(
                  label: 'requests.photos'.tr(),
                  value: 'requests.photo_count'.tr(
                    namedArgs: {'count': '${draft.photos.length}'},
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: AppSpacing.md),
          AppCard(
            color: context.colors.primaryContainer,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  color: context.colors.onPrimaryContainer,
                ),
                SizedBox(height: AppSpacing.sm),
                Text(
                  'requests.review_note'.tr(),
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colors.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: AppSpacing.md),
          AppCard(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: CheckboxListTile(
              key: const ValueKey('request-consent'),
              value: draft.consent,
              onChanged: state.canEdit
                  ? (value) => context
                        .read<ServiceRequestFormCubit>()
                        .setConsent(value ?? false)
                  : null,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              title: Text(
                'requests.consent'.tr(),
                style: context.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _ReviewField extends StatelessWidget {
  const _ReviewField({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: AppSpacing.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.textTheme.labelMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        SizedBox(height: AppSpacing.xs),
        Text(value, style: context.textTheme.bodyLarge),
      ],
    ),
  );
}
