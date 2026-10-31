import 'package:salahly/src/imports/imports.dart';

import 'bloc/session_bloc.dart';
import 'widgets/auth_layout.dart';

class SessionGatePage extends StatelessWidget {
  const SessionGatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionBloc>().state;
    final failed = session.status == SessionStatus.failure;
    return AuthLayout(
      title: 'auth.session_title'.tr(),
      subtitle:
          (failed ? 'auth.session_failed_subtitle' : 'auth.session_subtitle')
              .tr(),
      child: AppCard(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: failed
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    color: context.colors.error,
                    size: 32,
                  ),
                  SizedBox(height: AppSpacing.md),
                  Text(
                    'common.error'.tr(),
                    style: context.textTheme.titleLarge,
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      (session.errorMessage ?? 'errors.unexpected').tr(),
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  SizedBox(height: AppSpacing.lg),
                  AppButton(
                    label: 'common.retry'.tr(),
                    isFullWidth: true,
                    height: ButtonSize.large,
                    isLoading: session.isLoading,
                    onPressed: () => context.read<SessionBloc>().add(
                      const SessionCheckRequested(),
                    ),
                  ),
                  SizedBox(height: AppSpacing.sm),
                  AppButton(
                    label: 'profile.sign_out'.tr(),
                    variant: ButtonVariant.ghost,
                    isLoading: session.isLoading,
                    onPressed: () => context.read<SessionBloc>().add(
                      const SessionLogoutRequested(),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    semanticsLabel: 'common.loading'.tr(),
                    strokeWidth: 2,
                  ),
                  SizedBox(height: AppSpacing.md),
                  Text(
                    'common.loading'.tr(),
                    style: context.textTheme.bodyMedium,
                  ),
                ],
              ),
      ),
    );
  }
}
