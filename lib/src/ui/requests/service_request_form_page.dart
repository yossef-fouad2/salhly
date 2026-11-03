import '../../data/models/user_model.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/service_request_repository.dart';
import '../../imports/imports.dart';
import '../../services/request_photo_picker.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/motion/staggered_entrance.dart';
import '../../shared/widgets/demo_banner.dart';
import '../auth/bloc/session_bloc.dart';
import 'service_request_form_cubit.dart';
import 'service_request_location_step.dart';
import 'service_request_problem_step.dart';
import 'service_request_review_step.dart';

class ServiceRequestFormPage extends StatelessWidget {
  const ServiceRequestFormPage({
    super.key,
    required this.userId,
    this.initialCategoryId,
    this.initialCity = '',
  });

  final String userId;
  final String? initialCategoryId;
  final String initialCity;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => ServiceRequestFormCubit(
      userId: userId,
      repository: context.read<ServiceRequestRepository>(),
      catalog: context.read<CatalogRepository>(),
      photoPicker: context.read<RequestPhotoPicker>(),
      initialCategoryId: initialCategoryId,
      initialCity: initialCity,
    )..load(),
    child: _RequestFormView(userId: userId),
  );
}

class _RequestFormView extends StatefulWidget {
  const _RequestFormView({required this.userId});
  final String userId;

  @override
  State<_RequestFormView> createState() => _RequestFormViewState();
}

class _RequestFormViewState extends State<_RequestFormView> {
  final _errorKey = GlobalKey();
  bool _allowExit = false;
  bool _askingToLeave = false;

  bool _authorized(SessionState state) =>
      state.status == SessionStatus.authenticated &&
      state.user?.id == widget.userId &&
      state.user?.role == UserRole.customer;

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.goNamed(AppRouteNames.home);
    }
  }

  Future<void> _leave() async {
    final state = context.read<ServiceRequestFormCubit>().state;
    if (state.operation == RequestFormOperation.submitting) {
      context.showSnackBar('requests.wait_submission'.tr());
      return;
    }
    if (!state.hasUnsavedChanges || _allowExit) return _back();
    if (_askingToLeave) return;
    _askingToLeave = true;
    final pending = state.outcomeUncertain;
    final leave = await context.showAppDialog<bool>(
      builder: (context) => AlertDialog(
        title: Text(
          (pending ? 'requests.leave_pending_title' : 'requests.discard_title')
              .tr(),
        ),
        content: Text(
          (pending ? 'requests.leave_pending_body' : 'requests.discard_body')
              .tr(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('requests.keep_editing'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              (pending ? 'requests.check_history' : 'requests.discard').tr(),
            ),
          ),
        ],
      ),
    );
    _askingToLeave = false;
    if (!mounted ||
        leave != true ||
        !_authorized(context.read<SessionBloc>().state)) {
      return;
    }
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (pending) {
      context.replaceNamed(AppRouteNames.serviceRequests);
    } else {
      _back();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!context.select((SessionBloc bloc) => _authorized(bloc.state))) {
      return const SizedBox.shrink();
    }
    final view = context.select(
      (ServiceRequestFormCubit cubit) => (
        loaded: cubit.state.catalogLoaded,
        step: cubit.state.step,
        operation: cubit.state.operation,
        dirty: cubit.state.hasUnsavedChanges,
        uncertain: cubit.state.outcomeUncertain,
        error: cubit.state.errorMessage,
      ),
    );
    final cubit = context.read<ServiceRequestFormCubit>();
    final busy = view.operation != RequestFormOperation.idle;
    final submitting = view.operation == RequestFormOperation.submitting;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final compactControls =
        MediaQuery.sizeOf(context).width < 480 &&
        MediaQuery.textScalerOf(context).scale(16) > 24;
    final VoidCallback? previousStep = busy
        ? null
        : () {
            context.hideKeyboard();
            cubit.previousStep();
          };

    return BlocListener<ServiceRequestFormCubit, ServiceRequestFormState>(
      listenWhen: (previous, current) =>
          previous.submitted != current.submitted ||
          previous.errorMessage != current.errorMessage,
      listener: (context, state) {
        if (state.submitted != null) {
          context.showSuccessSnackBar('requests.submitted_notice'.tr());
          context.replaceNamed(
            AppRouteNames.serviceRequestDetail,
            pathParameters: {'requestId': state.submitted!.id},
          );
        } else if (state.errorMessage != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final target = _errorKey.currentContext;
            if (!mounted || target == null) return;
            Scrollable.ensureVisible(
              target,
              duration: AppMotion.durationOf(context, AppDurations.quick),
              curve: AppCurves.decelerate,
            );
          });
        }
      },
      child: PopScope<void>(
        canPop: !submitting && (!view.dirty || _allowExit),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: _leave),
            title: Text('requests.new_request'.tr()),
          ),
          body: SafeArea(
            child: !view.loaded
                ? busy
                      ? AppLoading(message: 'common.loading'.tr())
                      : AppEmptyState(
                          title: 'common.error'.tr(),
                          subtitle: view.error?.tr(),
                          actionLabel: 'common.retry'.tr(),
                          onAction: cubit.load,
                        )
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!keyboard &&
                              context.read<ServiceRequestRepository>().isDemo)
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: AppSpacing.pagePadding,
                              ),
                              child: const DemoBanner(),
                            ),
                          Padding(
                            padding: EdgeInsets.all(AppSpacing.pagePadding),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'requests.step'.tr(
                                    namedArgs: {
                                      'number': '${view.step + 1}',
                                      'total': '3',
                                    },
                                  ),
                                  style: context.textTheme.labelLarge?.copyWith(
                                    color: context.colors.secondary,
                                  ),
                                ),
                                SizedBox(height: AppSpacing.sm),
                                ExcludeSemantics(
                                  child: !AppMotion.isEnabled(context)
                                      ? LinearProgressIndicator(
                                          value: (view.step + 1) / 3,
                                        )
                                      : TweenAnimationBuilder<double>(
                                          tween: Tween(
                                            end: (view.step + 1) / 3,
                                          ),
                                          duration: AppDurations.quick,
                                          curve: AppCurves.decelerate,
                                          builder: (context, value, _) =>
                                              LinearProgressIndicator(
                                                value: value,
                                                borderRadius: AppBorders.full,
                                              ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              key: PageStorageKey('request-step-${view.step}'),
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
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Semantics(
                                        header: true,
                                        child: Text(
                                          'requests.steps.${view.step}'.tr(),
                                          style: context.textTheme.titleLarge,
                                        ),
                                      ),
                                      SizedBox(height: AppSpacing.md),
                                      if (view.error != null) ...[
                                        Semantics(
                                          key: _errorKey,
                                          liveRegion: true,
                                          child: AppCard(
                                            color:
                                                context.colors.errorContainer,
                                            child: Text(
                                              view.error!.tr(),
                                              style: TextStyle(
                                                color: context
                                                    .colors
                                                    .onErrorContainer,
                                              ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(height: AppSpacing.md),
                                      ],
                                      switch (view.step) {
                                        0 => ServiceRequestProblemStep(
                                          userId: widget.userId,
                                        ),
                                        1 => const ServiceRequestLocationStep(),
                                        _ => const ServiceRequestReviewStep(),
                                      },
                                      SizedBox(height: AppSpacing.md),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.all(AppSpacing.pagePadding),
                            child: Row(
                              children: [
                                if (view.step > 0 && !view.uncertain) ...[
                                  if (compactControls)
                                    IconButton.outlined(
                                      tooltip: 'requests.back'.tr(),
                                      onPressed: previousStep,
                                      icon: const Icon(
                                        Icons.arrow_back_rounded,
                                      ),
                                    )
                                  else
                                    Expanded(
                                      child: AppButton(
                                        label: 'requests.back'.tr(),
                                        variant: ButtonVariant.outline,
                                        onPressed: previousStep,
                                      ),
                                    ),
                                  SizedBox(width: AppSpacing.sm),
                                ],
                                Expanded(
                                  child: AppButton(
                                    key: const ValueKey('request-next'),
                                    label:
                                        (view.uncertain
                                                ? 'requests.check_submission'
                                                : view.step == 2
                                                ? 'requests.submit'
                                                : 'requests.continue')
                                            .tr(),
                                    height: ButtonSize.large,
                                    isLoading: submitting,
                                    onPressed: busy
                                        ? null
                                        : () {
                                            context.hideKeyboard();
                                            if (view.step == 2) {
                                              cubit.submit();
                                            } else {
                                              cubit.nextStep();
                                            }
                                          },
                                  ),
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
}
