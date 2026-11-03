import '../../data/models/service_category.dart';
import '../../data/models/service_request.dart';
import '../../imports/imports.dart';
import 'request_photo_image.dart';
import 'service_request_form_cubit.dart';

class ServiceRequestProblemStep extends StatelessWidget {
  const ServiceRequestProblemStep({super.key, required this.userId});
  final String userId;

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
                'requests.category'.tr(),
                style: context.textTheme.titleLarge,
              ),
              SizedBox(height: AppSpacing.ms),
              const _CategoryChoices(),
              SizedBox(height: AppSpacing.lg),
              AppTextField(
                key: const ValueKey('request-title'),
                label: 'requests.title_label'.tr(),
                hint: 'requests.title_hint'.tr(),
                initialValue: cubit.state.draft.title,
                maxLength: 120,
                enabled: enabled,
                textInputAction: TextInputAction.next,
                onChanged: cubit.updateTitle,
              ),
              SizedBox(height: AppSpacing.md),
              AppTextField(
                key: const ValueKey('request-description'),
                label: 'requests.description'.tr(),
                hint: 'requests.description_hint'.tr(),
                initialValue: cubit.state.draft.description,
                minLines: 4,
                maxLines: 8,
                maxLength: 2000,
                enabled: enabled,
                keyboardType: TextInputType.multiline,
                onChanged: cubit.updateDescription,
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.md),
        _RequestPhotos(userId: userId),
      ],
    );
  }
}

class _CategoryChoices extends StatelessWidget {
  const _CategoryChoices();

  @override
  Widget build(BuildContext context) =>
      BlocSelector<
        ServiceRequestFormCubit,
        ServiceRequestFormState,
        ({List<ServiceCategory> categories, String? selected, bool enabled})
      >(
        selector: (state) => (
          categories: state.categories,
          selected: state.draft.categoryId,
          enabled: state.canEdit,
        ),
        builder: (context, view) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (view.categories.isEmpty)
              Text(
                'home.no_categories'.tr(),
                style: context.textTheme.bodyMedium,
              ),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final category in view.categories)
                  ChoiceChip(
                    key: ValueKey('request-category-${category.id}'),
                    label: Text(category.name(context.locale.languageCode)),
                    selected: category.id == view.selected,
                    onSelected: view.enabled
                        ? (_) => context
                              .read<ServiceRequestFormCubit>()
                              .selectCategory(category.id)
                        : null,
                  ),
              ],
            ),
            TextButton.icon(
              onPressed: view.enabled
                  ? context.read<ServiceRequestFormCubit>().load
                  : null,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text('requests.refresh_categories'.tr()),
            ),
          ],
        ),
      );
}

class _RequestPhotos extends StatelessWidget {
  const _RequestPhotos({required this.userId});
  final String userId;

  Future<void> _preview(
    BuildContext context,
    RequestPhotoInput photo,
    int index,
  ) async {
    context.hideKeyboard();
    await context.showAppDialog<void>(
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 640,
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: RequestPhotoImage(
                    userId: userId,
                    bytes: photo.bytes,
                    semanticLabel: 'requests.photo_label'.tr(
                      namedArgs: {'number': '${index + 1}'},
                    ),
                  ),
                ),
                SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: 'common.close'.tr(),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) => BlocBuilder<ServiceRequestFormCubit, ServiceRequestFormState>(
    buildWhen: (previous, current) =>
        previous.canEdit != current.canEdit ||
        previous.operation != current.operation ||
        !listEquals(previous.draft.photos, current.draft.photos),
    builder: (context, state) {
      final cubit = context.read<ServiceRequestFormCubit>();
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'requests.photos_optional'.tr(),
              style: context.textTheme.titleLarge,
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              'requests.photo_guidance'.tr(),
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            if (state.draft.photos.isNotEmpty) ...[
              SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final (index, photo) in state.draft.photos.indexed)
                    SizedBox(
                      key: ValueKey(photo.id),
                      width: 112,
                      child: Column(
                        children: [
                          Semantics(
                            button: true,
                            child: InkWell(
                              onTap: state.isBusy
                                  ? null
                                  : () => _preview(context, photo, index),
                              borderRadius: AppBorders.lg,
                              child: ClipRRect(
                                borderRadius: AppBorders.lg,
                                child: AspectRatio(
                                  aspectRatio: 1,
                                  child: RequestPhotoImage(
                                    userId: userId,
                                    bytes: photo.bytes,
                                    maxDimension: 320,
                                    fit: BoxFit.cover,
                                    semanticLabel: 'requests.photo_label'.tr(
                                      namedArgs: {'number': '${index + 1}'},
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            key: ValueKey('remove-photo-${photo.id}'),
                            tooltip: 'requests.remove_photo'.tr(
                              namedArgs: {'number': '${index + 1}'},
                            ),
                            onPressed: state.canEdit
                                ? () => cubit.removePhoto(photo.id)
                                : null,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            SizedBox(height: AppSpacing.md),
            AppButton(
              key: const ValueKey('request-add-photo'),
              label: 'requests.add_photo'.tr(
                namedArgs: {
                  'count': '${state.draft.photos.length}',
                  'max': '3',
                },
              ),
              variant: ButtonVariant.outline,
              prefixIcon: const Icon(Icons.add_photo_alternate_outlined),
              isLoading: state.operation == RequestFormOperation.picking,
              onPressed: state.canEdit && state.draft.photos.length < 3
                  ? cubit.pickPhoto
                  : null,
            ),
          ],
        ),
      );
    },
  );
}
