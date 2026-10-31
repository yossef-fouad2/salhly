import 'package:salahly/src/data/repositories/auth_repository.dart';
import 'package:salahly/src/imports/imports.dart';
import 'package:salahly/src/shared/widgets/demo_banner.dart';

import '../bloc/auth_bloc.dart';
import '../bloc/session_bloc.dart';
import 'auth_layout.dart';

class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  void _onAuthState(BuildContext context, AuthState state) {
    if (state.status == AuthStatus.confirmationRequired) {
      context.goNamed(
        AppRouteNames.verifyEmail,
        queryParameters: {'email': state.email ?? ''},
      );
    } else if (state.status == AuthStatus.recoveryCodeSent) {
      context.goNamed(
        AppRouteNames.resetPassword,
        queryParameters: {'email': state.email ?? ''},
      );
    } else if (state.status == AuthStatus.authenticated ||
        state.status == AuthStatus.passwordUpdated) {
      TextInput.finishAutofillContext();
      context.read<SessionBloc>().add(const SessionCheckRequested());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthBloc, AuthState>(
      listener: _onAuthState,
      child: AuthLayout(
        title: title,
        subtitle: subtitle,
        child: AppCard(
          padding: EdgeInsets.all(AppSpacing.ml),
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.alternate_email_rounded,
                      color: context.colors.onSurface,
                      size: 20,
                    ),
                    SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'auth.email_authentication'.tr(),
                        style: context.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: AppSpacing.lg),
                if (context.read<AuthRepository>().isDemo) ...[
                  const DemoBanner(detail: true),
                  SizedBox(height: AppSpacing.lg),
                ],
                BlocBuilder<AuthBloc, AuthState>(
                  builder: (context, state) {
                    final message = state.errorMessage;
                    if (message != null) {
                      return Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.md),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            message.tr(),
                            style: context.textTheme.bodyMedium?.copyWith(
                              color: context.colors.error,
                            ),
                          ),
                        ),
                      );
                    }
                    if (state.status == AuthStatus.confirmationSent) {
                      return Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.md),
                        child: Semantics(
                          liveRegion: true,
                          child: Text('auth.code_sent'.tr()),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
