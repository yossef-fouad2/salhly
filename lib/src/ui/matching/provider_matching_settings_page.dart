import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/matching_repository.dart';
import '../../data/models/user_model.dart';
import '../../imports/imports.dart';
import '../auth/bloc/session_bloc.dart';
import '../marketplace/marketplace_widgets.dart';
import 'matching_widgets.dart';
import 'provider_matching_cubit.dart';

class ProviderMatchingSettingsPage extends StatelessWidget {
  const ProviderMatchingSettingsPage({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => ProviderMatchingCubit(
      userId: userId,
      repository: context.read<MatchingRepository>(),
      catalogRepository: context.read<CatalogRepository>(),
      session: context.read<SessionBloc>(),
    )..load(),
    child: _ProviderMatchingView(userId: userId),
  );
}

class _ProviderMatchingView extends StatefulWidget {
  const _ProviderMatchingView({required this.userId});
  final String userId;

  @override
  State<_ProviderMatchingView> createState() => _ProviderMatchingViewState();
}

class _ProviderMatchingViewState extends State<_ProviderMatchingView>
    with WidgetsBindingObserver {
  bool _allowExit = false;
  bool _asking = false;
  bool? _wasCurrent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current && _wasCurrent == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ProviderMatchingCubit>().load();
      });
    }
    _wasCurrent = current;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _wasCurrent != false && mounted) {
      context.read<ProviderMatchingCubit>().load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _back() =>
      context.canPop() ? context.pop() : context.goNamed(AppRouteNames.profile);

  Future<void> _leave() async {
    final cubit = context.read<ProviderMatchingCubit>();
    if (!cubit.active) return;
    if (cubit.state.operation == ProviderMatchingOperation.saving ||
        cubit.state.uncertain) {
      context.showSnackBar(
        (cubit.state.uncertain
                ? 'matching.resolve_before_leaving'
                : 'matching.wait_save')
            .tr(),
      );
      return;
    }
    if (!cubit.state.hasUnsavedChanges || _allowExit) return _back();
    if (_asking) return;
    _asking = true;
    final discard = await matchingConfirm(
      context,
      titleKey: 'matching.discard_title',
      bodyKey: 'matching.discard_body',
      confirmKey: 'matching.discard',
    );
    _asking = false;
    if (!mounted || !discard || !cubit.active) return;
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && cubit.active) _back();
  }

  Future<void> _refresh() async {
    final cubit = context.read<ProviderMatchingCubit>();
    if (!cubit.active || cubit.state.busy || cubit.state.uncertain || _asking) {
      return;
    }
    if (cubit.state.hasUnsavedChanges) {
      _asking = true;
      final reload = await matchingConfirm(
        context,
        titleKey: 'matching.reload_title',
        bodyKey: 'matching.reload_body',
        confirmKey: 'matching.reload',
      );
      _asking = false;
      if (!mounted || !reload || !cubit.active) {
        return;
      }
    }
    await cubit.load(discardEdits: true);
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProviderMatchingCubit>();
    return BlocConsumer<ProviderMatchingCubit, ProviderMatchingState>(
      listenWhen: (previous, current) =>
          previous.notice != current.notice ||
          previous.errorMessage != current.errorMessage,
      listener: (context, state) {
        if (!cubit.active) return;
        if (state.notice != null) {
          context.showSuccessSnackBar(state.notice!.tr());
        }
        if (state.errorMessage != null) {
          context.showErrorSnackBar(state.errorMessage!.tr());
        }
      },
      buildWhen: (previous, current) =>
          previous.profile != current.profile ||
          previous.metadata != current.metadata ||
          previous.categories != current.categories ||
          previous.metadataLoading != current.metadataLoading ||
          previous.metadataError != current.metadataError ||
          previous.catalogError != current.catalogError ||
          previous.operation != current.operation ||
          previous.uncertain != current.uncertain ||
          previous.formVersion != current.formVersion ||
          previous.revoked != current.revoked ||
          previous.errorMessage != current.errorMessage ||
          previous.reloadRequired != current.reloadRequired ||
          previous.hasUnsavedChanges != current.hasUnsavedChanges,
      builder: (context, state) {
        if (state.revoked) return const SizedBox.shrink();
        return PopScope<void>(
          canPop:
              state.operation != ProviderMatchingOperation.saving &&
              !state.uncertain &&
              (!state.hasUnsavedChanges || _allowExit),
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _leave();
          },
          child: MarketplaceScaffold(
            userId: widget.userId,
            role: UserRole.provider,
            titleKey: 'matching.settings_title',
            onBack: _leave,
            onRefresh: state.busy || state.uncertain ? null : _refresh,
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                key: PageStorageKey(
                  'matching-settings-scroll-${widget.userId}',
                ),
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.all(AppSpacing.pagePadding),
                children: [
                  MatchingFeedback(
                    loading:
                        state.operation == ProviderMatchingOperation.loading,
                    loadingKey: 'matching.settings_loading',
                    errorMessage: state.errorMessage,
                    uncertain: state.uncertain,
                    onRetry: state.busy
                        ? null
                        : state.uncertain
                        ? cubit.retryPending
                        : _refresh,
                  ),
                  if (context.read<MatchingRepository>().isDemo)
                    const MatchingDemoNotice(),
                  Text(
                    'matching.settings_heading'.tr(),
                    style: context.textTheme.headlineSmall,
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Text('matching.settings_intro'.tr()),
                  SizedBox(height: AppSpacing.md),
                  Text(
                    'matching.settings_no_action'.tr(),
                    style: context.textTheme.bodySmall,
                  ),
                  SizedBox(height: AppSpacing.lg),
                  if (state.profile != null) ...[
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            (state.profile!.discoverable
                                    ? 'matching.discovery_saved_on'
                                    : 'matching.discovery_saved_off')
                                .tr(),
                            style: context.textTheme.titleMedium,
                          ),
                          SizedBox(height: AppSpacing.sm),
                          Text(
                            'matching.saved_name'.tr(
                              namedArgs: {'name': state.profile!.providerName},
                            ),
                          ),
                          SizedBox(height: AppSpacing.sm),
                          Text('matching.eligibility_each_request'.tr()),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),
                  ],
                  if (state.metadataLoading) ...[
                    LinearProgressIndicator(
                      semanticsLabel: 'matching.metadata_loading'.tr(),
                    ),
                    SizedBox(height: AppSpacing.sm),
                    Text('matching.metadata_loading'.tr()),
                    SizedBox(height: AppSpacing.md),
                  ],
                  if (state.metadataError != null ||
                      state.catalogError != null) ...[
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('matching.metadata_failed'.tr()),
                          if (state.metadataError != null)
                            Text(state.metadataError!.tr()),
                          if (state.catalogError != null)
                            Text(state.catalogError!.tr()),
                          SizedBox(height: AppSpacing.md),
                          AppButton(
                            key: const ValueKey('matching-retry-metadata'),
                            label: 'matching.retry_metadata'.tr(),
                            variant: ButtonVariant.outline,
                            onPressed: state.metadataLoading || state.busy
                                ? null
                                : cubit.retryMetadata,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),
                  ],
                  if (!state.canEnableDiscovery && !state.metadataLoading) ...[
                    Text('matching.settings_ineligible'.tr()),
                    SizedBox(height: AppSpacing.md),
                  ],
                  AppButton(
                    key: const ValueKey('matching-manage-provider-setup'),
                    label: 'matching.manage_setup'.tr(),
                    variant: ButtonVariant.outline,
                    onPressed: state.busy || state.uncertain
                        ? null
                        : () => context.pushNamed(
                            AppRouteNames.providerOnboarding,
                          ),
                  ),
                  SizedBox(height: AppSpacing.lg),
                  if (state.profile != null) ...[
                    const _DiscoveryControl(),
                    SizedBox(height: AppSpacing.md),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'matching.origin_title'.tr(),
                            style: context.textTheme.titleLarge,
                          ),
                          SizedBox(height: AppSpacing.sm),
                          Text('matching.origin_guidance'.tr()),
                          SizedBox(height: AppSpacing.lg),
                          _OriginFields(
                            key: ValueKey(
                              'matching-origin-${state.formVersion}',
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: AppSpacing.md),
                    _ExperienceFields(
                      key: ValueKey('matching-experience-${state.formVersion}'),
                    ),
                    SizedBox(height: AppSpacing.md),
                    const _DisclosureControl(),
                    SizedBox(height: AppSpacing.md),
                    if (state.hasUnsavedChanges) ...[
                      Text(
                        'matching.unsaved'.tr(),
                        style: context.textTheme.bodySmall,
                      ),
                      SizedBox(height: AppSpacing.md),
                    ],
                    AppButton(
                      key: const ValueKey('matching-save-settings'),
                      label: 'matching.save_settings'.tr(),
                      isLoading:
                          state.operation == ProviderMatchingOperation.saving,
                      onPressed: state.canSave
                          ? () {
                              context.hideKeyboard();
                              cubit.save();
                            }
                          : null,
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

class _DiscoveryControl extends StatelessWidget {
  const _DiscoveryControl();
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProviderMatchingCubit>();
    final settings = context.select(
      (ProviderMatchingCubit cubit) => (
        cubit.state.draft.discoverable,
        cubit.state.canEdit,
        cubit.state.canEnableDiscovery,
      ),
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            key: const ValueKey('matching-discoverable'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('matching.discovery_checkbox'.tr()),
            value: settings.$1,
            onChanged: settings.$2 && (settings.$1 || settings.$3)
                ? (value) => cubit.setDiscoverable(value ?? false)
                : null,
          ),
          SizedBox(height: AppSpacing.sm),
          Text('matching.discovery_private_note'.tr()),
        ],
      ),
    );
  }
}

class _OriginFields extends StatelessWidget {
  const _OriginFields({super.key});
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProviderMatchingCubit>();
    final enabled = context.select(
      (ProviderMatchingCubit cubit) => cubit.state.canEdit,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          key: const PageStorageKey('matching-provider-latitude'),
          label: 'matching.origin_latitude'.tr(),
          hint: 'matching.latitude_example'.tr(),
          initialValue: cubit.state.draft.latitude,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          textInputAction: TextInputAction.next,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: cubit.updateLatitude,
        ),
        SizedBox(height: AppSpacing.formFieldGap),
        AppTextField(
          key: const PageStorageKey('matching-provider-longitude'),
          label: 'matching.origin_longitude'.tr(),
          hint: 'matching.longitude_example'.tr(),
          initialValue: cubit.state.draft.longitude,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          textInputAction: TextInputAction.next,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: cubit.updateLongitude,
        ),
      ],
    );
  }
}

class _ExperienceFields extends StatelessWidget {
  const _ExperienceFields({super.key});
  @override
  Widget build(BuildContext context) =>
      BlocBuilder<ProviderMatchingCubit, ProviderMatchingState>(
        buildWhen: (previous, current) =>
            previous.metadata != current.metadata ||
            previous.categories != current.categories ||
            previous.metadataLoading != current.metadataLoading ||
            previous.metadataError != current.metadataError ||
            previous.catalogError != current.catalogError ||
            previous.canEdit != current.canEdit ||
            !listEquals(previous.oldExperienceIds, current.oldExperienceIds),
        builder: (context, state) {
          final cubit = context.read<ProviderMatchingCubit>();
          return AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'matching.experience_title'.tr(),
                  style: context.textTheme.titleLarge,
                ),
                SizedBox(height: AppSpacing.sm),
                Text('matching.experience_guidance'.tr()),
                if (state.currentCategories.isEmpty) ...[
                  SizedBox(height: AppSpacing.md),
                  Text('matching.no_current_skills'.tr()),
                ],
                for (final category in state.currentCategories) ...[
                  SizedBox(height: AppSpacing.formFieldGap),
                  AppTextField(
                    key: PageStorageKey('matching-experience-${category.id}'),
                    label: 'matching.category_years'.tr(
                      namedArgs: {
                        'category': category.name(context.locale.languageCode),
                      },
                    ),
                    initialValue:
                        state.draft.experienceYears[category.id] ?? '',
                    enabled: state.canEdit && !state.metadataLoading,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (value) =>
                        cubit.updateExperience(category.id, value),
                  ),
                ],
                for (final id in state.oldExperienceIds) ...[
                  SizedBox(height: AppSpacing.md),
                  Text(
                    'matching.old_experience'.tr(
                      namedArgs: {
                        'category':
                            state.categories
                                .where((category) => category.id == id)
                                .firstOrNull
                                ?.name(context.locale.languageCode) ??
                            'matching.unknown_service'.tr(),
                      },
                    ),
                  ),
                  AppButton(
                    key: ValueKey('matching-remove-experience-$id'),
                    label: 'matching.remove_old_experience'.tr(),
                    variant: ButtonVariant.outline,
                    onPressed: state.canEdit
                        ? () => cubit.removeExperience(id)
                        : null,
                  ),
                ],
              ],
            ),
          );
        },
      );
}

class _DisclosureControl extends StatelessWidget {
  const _DisclosureControl();
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProviderMatchingCubit>();
    final settings = context.select(
      (ProviderMatchingCubit cubit) => (
        cubit.state.draft.discoverable,
        cubit.state.draft.consent,
        cubit.state.canEdit,
      ),
    );
    final name = context.select(
      (SessionBloc bloc) => bloc.state.user?.name ?? '',
    );
    if (!settings.$1) return Text('matching.private_save_note'.tr());
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'matching.disclosure_title'.tr(),
            style: context.textTheme.titleLarge,
          ),
          SizedBox(height: AppSpacing.sm),
          Text('matching.name_to_share'.tr(namedArgs: {'name': name})),
          SizedBox(height: AppSpacing.md),
          Text('matching.settings_disclosure'.tr()),
          SizedBox(height: AppSpacing.md),
          CheckboxListTile(
            key: const ValueKey('matching-provider-consent'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('matching.provider_consent'.tr()),
            value: settings.$2,
            onChanged: settings.$3
                ? (value) => cubit.setConsent(value ?? false)
                : null,
          ),
        ],
      ),
    );
  }
}
