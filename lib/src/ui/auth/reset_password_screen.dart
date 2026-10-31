import 'package:salahly/src/data/repositories/auth_repository.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/imports/imports.dart';

import 'bloc/auth_bloc.dart';
import 'bloc/session_bloc.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/password_field.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, this.email = ''});
  final String email;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final session = context.read<SessionBloc>().state;
    context.read<AuthBloc>().add(
      PasswordResetRequested(
        email: session.status == SessionStatus.passwordRecovery
            ? session.user!.email
            : _email.text,
        code: _code.text,
        password: _password.text,
      ),
    );
  }

  void _cancel() {
    final session = context.read<SessionBloc>();
    if (session.state.status == SessionStatus.passwordRecovery) {
      session.add(const SessionLogoutRequested());
    } else {
      context.goNamed(AppRouteNames.login);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionBloc>().state;
    final loading =
        context.select((AuthBloc bloc) => bloc.state.isLoading) ||
        session.isLoading;
    final recovering = session.status == SessionStatus.passwordRecovery;
    return AuthScaffold(
      title: 'auth.reset_password'.tr(),
      subtitle:
          (recovering ? 'auth.choose_password' : 'auth.reset_password_subtitle')
              .tr(),
      children: [
        if (session.errorMessage != null)
          Semantics(
            liveRegion: true,
            child: Text(
              session.errorMessage!.tr(),
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colors.error,
              ),
            ),
          ),
        if (context.read<AuthRepository>().isDemo && !recovering) ...[
          Text(
            'auth.demo_code'.tr(
              namedArgs: {'code': DemoAuthRepository.demoCode},
            ),
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colors.secondary,
            ),
          ),
          SizedBox(height: AppSpacing.md),
        ],
        Form(
          key: _formKey,
          child: Column(
            children: [
              if (!recovering) ...[
                AppTextField(
                  controller: _email,
                  label: 'auth.email'.tr(),
                  enabled: !loading,
                  validator: FormValidators.email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  prefixIcon: const Icon(Icons.email_outlined),
                ),
                SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _code,
                  label: 'auth.code'.tr(),
                  enabled: !loading,
                  validator: FormValidators.code,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  autocorrect: false,
                  enableSuggestions: false,
                  prefixIcon: const Icon(Icons.pin_outlined),
                ),
                SizedBox(height: AppSpacing.md),
              ],
              PasswordField(
                controller: _password,
                label: 'auth.new_password'.tr(),
                enabled: !loading,
                isNewPassword: true,
                validator: FormValidators.password,
              ),
              SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _confirmation,
                label: 'auth.confirm_password'.tr(),
                enabled: !loading,
                isNewPassword: true,
                validator: (value) =>
                    FormValidators.confirmPassword(value, _password.text),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.lg),
        AppButton(
          label: 'auth.update_password'.tr(),
          height: ButtonSize.large,
          isFullWidth: true,
          isLoading: loading,
          suffixIcon: const Icon(Icons.arrow_forward_rounded, size: 20),
          onPressed: _submit,
        ),
        if (!recovering)
          TextButton(
            onPressed: loading
                ? null
                : () => context.goNamed(AppRouteNames.forgotPassword),
            child: Text('auth.resend_code'.tr()),
          ),
        TextButton(
          onPressed: loading ? null : _cancel,
          child: Text('auth.back_to_login'.tr()),
        ),
      ],
    );
  }
}
