import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/imports/imports.dart';

import 'bloc/auth_bloc.dart';
import 'widgets/account_role_card.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/password_field.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key, this.initialRole = UserRole.customer});

  final UserRole initialRole;

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  late UserRole _role = widget.initialRole;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    context.read<AuthBloc>().add(
      SignUpRequested(
        name: _name.text,
        email: _email.text,
        password: _password.text,
        role: _role,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loading = context.select((AuthBloc bloc) => bloc.state.isLoading);
    return AuthScaffold(
      title: 'auth.create_account'.tr(),
      subtitle: 'auth.sign_up_subtitle'.tr(),
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                controller: _name,
                label: 'auth.name'.tr(),
                enabled: !loading,
                validator: FormValidators.name,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                prefixIcon: const Icon(Icons.person_outline_rounded),
              ),
              SizedBox(height: AppSpacing.md),
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
              Semantics(
                header: true,
                child: Text(
                  'auth.account_type'.tr(),
                  style: context.textTheme.titleMedium,
                ),
              ),
              for (final role in UserRole.values) ...[
                SizedBox(height: AppSpacing.ms),
                AccountRoleCard(
                  key: ValueKey('signup-role-${role.name}'),
                  role: role,
                  selected: role == _role,
                  onTap: loading ? null : () => setState(() => _role = role),
                ),
              ],
              Padding(
                padding: EdgeInsets.only(
                  top: _role == UserRole.provider ? AppSpacing.sm : 0,
                ),
                child: _role == UserRole.provider
                    ? Text(
                        'auth.provider_hint'.tr(),
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _password,
                label: 'auth.password'.tr(),
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
              SizedBox(height: AppSpacing.lg),
              AppButton(
                label: 'auth.create_account'.tr(),
                height: ButtonSize.large,
                isFullWidth: true,
                isLoading: loading,
                suffixIcon: const Icon(Icons.arrow_forward_rounded, size: 20),
                onPressed: _submit,
              ),
            ],
          ),
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
