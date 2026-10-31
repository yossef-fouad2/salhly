import 'package:salahly/src/imports/imports.dart';

import 'bloc/auth_bloc.dart';
import 'widgets/auth_scaffold.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    context.read<AuthBloc>().add(ForgotPasswordRequested(email: _email.text));
  }

  @override
  Widget build(BuildContext context) {
    final loading = context.select((AuthBloc bloc) => bloc.state.isLoading);
    return AuthScaffold(
      title: 'auth.forgot_password'.tr(),
      subtitle: 'auth.forgot_password_subtitle'.tr(),
      children: [
        Form(
          key: _formKey,
          child: AppTextField(
            controller: _email,
            label: 'auth.email'.tr(),
            enabled: !loading,
            validator: FormValidators.email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            prefixIcon: const Icon(Icons.email_outlined),
          ),
        ),
        SizedBox(height: AppSpacing.lg),
        AppButton(
          label: 'auth.send_code'.tr(),
          height: ButtonSize.large,
          isFullWidth: true,
          isLoading: loading,
          suffixIcon: const Icon(Icons.arrow_forward_rounded, size: 20),
          onPressed: _submit,
        ),
        SizedBox(height: AppSpacing.sm),
        TextButton(
          onPressed: loading
              ? null
              : () => context.goNamed(AppRouteNames.login),
          child: Text('auth.back_to_login'.tr()),
        ),
      ],
    );
  }
}
