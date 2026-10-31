import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/provider_repository.dart';
import '../../extensions/context_extension.dart';
import '../../routing/app_routes.dart';
import '../../services/verification_document_picker.dart';
import '../../shared/enums/button_enums.dart';
import '../../shared/motion/staggered_entrance.dart';
import '../../shared/widgets/app_button.dart';
import '../../shared/widgets/app_empty_state.dart';
import '../../shared/widgets/app_loading.dart';
import '../../shared/widgets/demo_banner.dart';
import '../../theme/theme_constants.dart';
import '../auth/bloc/session_bloc.dart';
import 'provider_coverage_step.dart';
import 'provider_details_step.dart';
import 'provider_onboarding_cubit.dart';
import 'provider_verification_step.dart';

class ProviderOnboardingPage extends StatelessWidget {
  const ProviderOnboardingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final userId = context.select((SessionBloc bloc) => bloc.state.user?.id);
    if (userId == null) return const SizedBox.shrink();
    return BlocProvider(
      key: ValueKey(userId),
      create: (context) => ProviderOnboardingCubit(
        userId: userId,
        repository: context.read<ProviderRepository>(),
        catalog: context.read<CatalogRepository>(),
        documentPicker: context.read<VerificationDocumentPicker>(),
      )..load(),
      child: const _ProviderOnboardingView(),
    );
  }
}

class _ProviderOnboardingView extends StatefulWidget {
  const _ProviderOnboardingView();

  @override
  State<_ProviderOnboardingView> createState() =>
      _ProviderOnboardingViewState();
}

class _ProviderOnboardingViewState extends State<_ProviderOnboardingView> {
  bool _allowExit = false;
  bool _askingToLeave = false;

  void _navigateBack() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.goNamed(AppRouteNames.home);
    }
  }

  Future<void> _leave() async {
    final state = context.read<ProviderOnboardingCubit>().state;
    if (state.isWriting) {
      context.showSnackBar('provider.wait_operation'.tr());
      return;
    }
    if (!state.hasUnsavedChanges || _allowExit) {
      _navigateBack();
      return;
    }
    if (_askingToLeave) return;
    _askingToLeave = true;
    final discard = await context.showAppDialog<bool>(
      builder: (context) => AlertDialog(
        title: Text('provider.discard_title'.tr()),
        content: Text('provider.discard_message'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('provider.keep_editing'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('provider.discard'.tr()),
          ),
        ],
      ),
    );
    _askingToLeave = false;
    if (!mounted || discard != true) return;
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) _navigateBack();
  }

  @override
  Widget build(BuildContext context) {
    // Draft keystrokes do not rebuild the page chrome or the other form fields.
    final view = context.select(
      (ProviderOnboardingCubit cubit) => (
        initial: cubit.state.profile == null,
        operation: cubit.state.operation,
        step: cubit.state.step,
        unsaved: cubit.state.hasUnsavedChanges,
        dirty: cubit.state.isDirty,
        editable: cubit.state.profile?.canEdit ?? false,
        canSubmit: cubit.state.profile?.canSubmit ?? false,
        error: cubit.state.errorMessage,
      ),
    );
    final cubit = context.read<ProviderOnboardingCubit>();
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final busy = view.operation != ProviderOperation.idle;
    final writing =
        view.operation == ProviderOperation.saving ||
        view.operation == ProviderOperation.submitting;
    final primaryLabel = view.step < 2
        ? 'provider.continue'
        : view.canSubmit
        ? 'provider.submit'
        : 'common.close';

    return BlocListener<ProviderOnboardingCubit, ProviderOnboardingState>(
      listenWhen: (previous, current) =>
          current.notice != null && current.notice != previous.notice,
      listener: (context, state) =>
          context.showSuccessSnackBar(state.notice!.tr()),
      child: PopScope<void>(
        canPop: !writing && (!view.unsaved || _allowExit),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: _leave),
            title: Text('provider.title'.tr()),
          ),
          body: SafeArea(
            child: view.initial
                ? (busy
                      ? AppLoading(message: 'common.loading'.tr())
                      : AppEmptyState(
                          title: 'common.error'.tr(),
                          subtitle: view.error?.tr(),
                          actionLabel: 'common.retry'.tr(),
                          onAction: cubit.load,
                        ))
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!keyboardVisible &&
                              context.read<ProviderRepository>().isDemo)
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: AppSpacing.pagePadding,
                              ),
                              child: const DemoBanner(),
                            ),
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              AppSpacing.pagePadding,
                              AppSpacing.sm,
                              AppSpacing.pagePadding,
                              AppSpacing.md,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'provider.step'.tr(
                                    namedArgs: {
                                      'number': '${view.step + 1}',
                                      'total': '3',
                                    },
                                  ),
                                  style: context.textTheme.labelLarge,
                                ),
                                if (!keyboardVisible) ...[
                                  SizedBox(height: AppSpacing.xs),
                                  Semantics(
                                    header: true,
                                    child: Text(
                                      'provider.steps.${view.step}'.tr(),
                                      style: context.textTheme.titleLarge,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (view.operation == ProviderOperation.loading)
                            LinearProgressIndicator(
                              semanticsLabel: 'provider.refresh_status'.tr(),
                            ),
                          Expanded(
                            child: SingleChildScrollView(
                              key: PageStorageKey('provider-step-${view.step}'),
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: EdgeInsets.symmetric(
                                horizontal: AppSpacing.pagePadding,
                                vertical: AppSpacing.sm,
                              ),
                              child: StaggeredEntrance(
                                key: ValueKey(view.step),
                                itemCount: 1,
                                child: EntranceItem(
                                  index: 0,
                                  child: switch (view.step) {
                                    0 => const ProviderDetailsStep(),
                                    1 => const ProviderCoverageStep(),
                                    _ => const ProviderVerificationStep(),
                                  },
                                ),
                              ),
                            ),
                          ),
                          const Divider(height: 1),
                          Padding(
                            padding: EdgeInsets.all(AppSpacing.pagePadding),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (view.error != null) ...[
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      view.error!.tr(),
                                      style: context.textTheme.bodySmall
                                          ?.copyWith(
                                            color: context.colors.error,
                                          ),
                                    ),
                                  ),
                                  SizedBox(height: AppSpacing.sm),
                                ],
                                Row(
                                  children: [
                                    if (view.step > 0) ...[
                                      Expanded(
                                        child: AppButton(
                                          label: 'provider.back'.tr(),
                                          variant: ButtonVariant.outline,
                                          onPressed: busy
                                              ? null
                                              : () => _step(view.step - 1),
                                        ),
                                      ),
                                      SizedBox(width: AppSpacing.sm),
                                    ],
                                    Expanded(
                                      child: AppButton(
                                        key: const ValueKey('provider-next'),
                                        label: primaryLabel.tr(),
                                        isLoading:
                                            view.operation ==
                                            ProviderOperation.submitting,
                                        onPressed: busy ? null : _continue,
                                      ),
                                    ),
                                  ],
                                ),
                                if (view.editable && !keyboardVisible)
                                  TextButton(
                                    key: const ValueKey('provider-save'),
                                    onPressed: busy || !view.dirty
                                        ? null
                                        : () {
                                            context.hideKeyboard();
                                            cubit.save();
                                          },
                                    child: Text(
                                      (view.operation ==
                                                  ProviderOperation.saving
                                              ? 'common.loading'
                                              : 'provider.save_draft')
                                          .tr(),
                                    ),
                                  ),
                                if (view.unsaved && !keyboardVisible)
                                  Text(
                                    'provider.unsaved'.tr(),
                                    style: context.textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  void _step(int index) {
    context.hideKeyboard();
    context.read<ProviderOnboardingCubit>().setStep(index);
  }

  void _continue() {
    context.hideKeyboard();
    final cubit = context.read<ProviderOnboardingCubit>();
    if (cubit.state.step < 2) {
      cubit.setStep(cubit.state.step + 1);
    } else if (cubit.state.profile!.canSubmit) {
      cubit.submit();
    } else {
      _leave();
    }
  }
}
