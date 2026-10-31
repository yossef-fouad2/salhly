import 'dart:async';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/provider_profile.dart';
import '../../data/models/user_model.dart';
import '../../data/repositories/provider_repository.dart';
import '../../extensions/context_extension.dart';
import '../../shared/enums/button_enums.dart';
import '../../shared/widgets/app_button.dart';
import '../../shared/widgets/app_card.dart';
import '../../theme/theme_constants.dart';
import '../auth/bloc/session_bloc.dart';
import 'provider_onboarding_cubit.dart';

class ProviderVerificationStep extends StatelessWidget {
  const ProviderVerificationStep({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProviderOnboardingCubit, ProviderOnboardingState>(
      builder: (context, state) {
        final cubit = context.read<ProviderOnboardingCubit>();
        final verification = state.profile!.verification;
        final status = verification?.status.name ?? 'draft';
        final document = state.document;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppCard(
              title: 'provider.status.$status'.tr(),
              leading: Icon(
                verification?.status == ProviderVerificationStatus.verified
                    ? Icons.verified_outlined
                    : Icons.fact_check_outlined,
                color: context.colors.primary,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('provider.status_hint.$status'.tr()),
                  if (context.read<ProviderRepository>().isDemo) ...[
                    SizedBox(height: AppSpacing.ms),
                    Text(
                      'provider.demo_note'.tr(),
                      style: context.textTheme.bodySmall,
                    ),
                  ],
                  if (verification != null) ...[
                    SizedBox(height: AppSpacing.ms),
                    Text(
                      'provider.submitted_on'.tr(
                        namedArgs: {
                          'date': DateFormat.yMMMd(context.locale.languageCode)
                              .format(verification.submittedAt.toLocal()),
                        },
                      ),
                    ),
                    if (verification.reviewNote?.isNotEmpty ?? false) ...[
                      SizedBox(height: AppSpacing.ms),
                      Text(
                        'provider.review_note'.tr(),
                        style: context.textTheme.labelLarge,
                      ),
                      Text(verification.reviewNote!),
                    ],
                    SizedBox(height: AppSpacing.md),
                    AppButton(
                      label: 'provider.view_document'.tr(),
                      variant: ButtonVariant.outline,
                      isLoading: state.operation == ProviderOperation.reading,
                      onPressed: state.isBusy
                          ? null
                          : () => _viewDocument(context),
                    ),
                  ],
                  SizedBox(height: AppSpacing.sm),
                  TextButton.icon(
                    onPressed: state.isBusy ? null : cubit.load,
                    icon: const Icon(Icons.refresh),
                    label: Text('provider.refresh_status'.tr()),
                  ),
                ],
              ),
            ),
            if (state.profile!.canSubmit) ...[
              SizedBox(height: AppSpacing.md),
              AppCard(
                title: 'provider.document_title'.tr(),
                subtitle: 'provider.document_hint'.tr(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: AppSpacing.md),
                    Text('provider.privacy_note'.tr()),
                    if (document != null) ...[
                      SizedBox(height: AppSpacing.md),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          'provider.document_selected'.tr(
                            namedArgs: {
                              'type': document.extension.toUpperCase(),
                              'size': (document.sizeBytes / 1024)
                                  .ceil()
                                  .toString(),
                            },
                          ),
                        ),
                      ),
                    ],
                    SizedBox(height: AppSpacing.md),
                    AppButton(
                      key: const ValueKey('provider-pick-document'),
                      label:
                          (document == null
                                  ? 'provider.choose_document'
                                  : 'provider.replace_document')
                              .tr(),
                      variant: ButtonVariant.outline,
                      isLoading: state.operation == ProviderOperation.picking,
                      onPressed: state.isBusy ? null : cubit.pickDocument,
                    ),
                    if (document != null)
                      TextButton(
                        onPressed: state.isBusy ? null : cubit.removeDocument,
                        child: Text('provider.remove_document'.tr()),
                      ),
                    SizedBox(height: AppSpacing.sm),
                    CheckboxListTile(
                      key: const ValueKey('provider-consent'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('provider.consent'.tr()),
                      value: state.consent,
                      onChanged: state.isBusy
                          ? null
                          : (value) => cubit.setConsent(value ?? false),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _viewDocument(BuildContext context) async {
    final cubit = context.read<ProviderOnboardingCubit>();
    final userId = cubit.state.profile!.userId;
    final bytes = await cubit.readDocument();
    if (!context.mounted || bytes == null) return;
    final session = context.read<SessionBloc>().state;
    if (session.status != SessionStatus.authenticated ||
        session.user?.id != userId) {
      return;
    }
    await context.showAppDialog<void>(
      builder: (context) => AlertDialog(
        title: Text('provider.view_document'.tr()),
        content: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: _PrivateDocumentImage(bytes: bytes, userId: userId),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('common.close'.tr()),
          ),
        ],
      ),
    );
  }
}

class _PrivateDocumentImage extends StatefulWidget {
  const _PrivateDocumentImage({required this.bytes, required this.userId});

  final Uint8List bytes;
  final String userId;

  @override
  State<_PrivateDocumentImage> createState() => _PrivateDocumentImageState();
}

class _PrivateDocumentImageState extends State<_PrivateDocumentImage> {
  // Bound BOTH decoded dimensions, and never persist private images to disk.
  late final _image = ResizeImage(
    MemoryImage(widget.bytes),
    width: 1200,
    height: 1200,
    policy: ResizeImagePolicy.fit,
  );

  @override
  void dispose() {
    unawaited(_image.evict());
    super.dispose();
  }

  bool _isAuthorized(SessionState state) =>
      state.status == SessionStatus.authenticated &&
      state.user?.id == widget.userId &&
      state.user?.role == UserRole.provider;

  void _revokePreview() {
    unawaited(_image.evict());
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route != null && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final authorized = context.select(
      (SessionBloc bloc) => _isAuthorized(bloc.state),
    );
    // Hide immediately, including while the account-keyed route is exiting.
    return BlocListener<SessionBloc, SessionState>(
      listenWhen: (previous, current) =>
          _isAuthorized(previous) && !_isAuthorized(current),
      listener: (_, _) => _revokePreview(),
      child: !authorized
          ? const SizedBox.shrink()
          : Image(
              image: _image,
              fit: BoxFit.contain,
              semanticLabel: 'provider.view_document'.tr(),
              errorBuilder: (_, _, _) => Center(
                child: Text('provider.errors.document_unavailable'.tr()),
              ),
            ),
    );
  }
}
