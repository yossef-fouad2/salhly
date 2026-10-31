import 'package:salahly/src/data/repositories/auth_repository.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/imports/imports.dart';

import 'bloc/auth_bloc.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/password_field.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    context.read<AuthBloc>().add(
      LoginRequested(email: _email.text, password: _password.text),
    );
  }

  void _fillDemo(String email) {
    _email.text = email;
    _password.text = DemoAuthRepository.demoPassword;
    _submit();
  }

  @override
  Widget build(BuildContext context) {
    final loading = context.select((AuthBloc bloc) => bloc.state.isLoading);
    final isDemo = context.read<AuthRepository>().isDemo;
    return AuthScaffold(
      title: 'auth.log_in'.tr(),
      subtitle: 'auth.log_in_subtitle'.tr(),
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                controller: _email,
                label: 'auth.email'.tr(),
                enabled: !loading,
                validator: FormValidators.email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                autocorrect: false,
                prefixIcon: const Icon(Icons.email_outlined),
              ),
              SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _password,
                label: 'auth.password'.tr(),
                enabled: !loading,
                validator: FormValidators.requiredPassword,
                onSubmitted: (_) => _submit(),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: loading
                      ? null
                      : () => context.goNamed(AppRouteNames.forgotPassword),
                  child: Text('auth.forgot_password'.tr()),
                ),
              ),
              AppButton(
                label: 'auth.sign_in'.tr(),
                height: ButtonSize.large,
                isFullWidth: true,
                isLoading: loading,
                suffixIcon: const Icon(Icons.arrow_forward_rounded, size: 20),
                onPressed: _submit,
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.md),
        TextButton(
          onPressed: loading
              ? null
              : () => context.goNamed(AppRouteNames.signup),
          child: Text('auth.create_account'.tr()),
        ),
        if (isDemo) ...[
          SizedBox(height: AppSpacing.sm),
          const Divider(),
          SizedBox(height: AppSpacing.md),
          Text('auth.demo_accounts'.tr(), style: context.textTheme.titleSmall),
          SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OutlinedButton.icon(
                onPressed: loading
                    ? null
                    : () => _fillDemo(DemoAuthRepository.customerEmail),
                icon: const Icon(Icons.home_outlined, size: 18),
                label: Text('auth.demo_customer'.tr()),
              ),
              OutlinedButton.icon(
                onPressed: loading
                    ? null
                    : () => _fillDemo(DemoAuthRepository.providerEmail),
                icon: const Icon(Icons.handyman_outlined, size: 18),
                label: Text('auth.demo_provider'.tr()),
              ),
            ],
          ),
        ],
        SizedBox(height: AppSpacing.sm),
        TextButton(
          onPressed: loading
              ? null
              : () => context.goNamed(AppRouteNames.onboarding),
          child: Text('auth.explore_account_types'.tr()),
        ),
      ],
    );
  }
}
