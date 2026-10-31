import 'package:salahly/src/data/repositories/auth_repository.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/imports/imports.dart';

import 'bloc/auth_bloc.dart';
import 'widgets/auth_scaffold.dart';

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key, this.email = ''});
  final String email;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    context.read<AuthBloc>().add(
      EmailConfirmationRequested(email: _email.text, code: _code.text),
    );
  }

  void _resend() {
    if (FormValidators.email(_email.text) != null) {
      _formKey.currentState?.validate();
      return;
    }
    context.read<AuthBloc>().add(
      ConfirmationResendRequested(email: _email.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loading = context.select((AuthBloc bloc) => bloc.state.isLoading);
    return AuthScaffold(
      title: 'auth.verify_email'.tr(),
      subtitle: 'auth.verify_email_subtitle'.tr(),
      children: [
        if (context.read<AuthRepository>().isDemo) ...[
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
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                autofillHints: const [AutofillHints.oneTimeCode],
                autocorrect: false,
                enableSuggestions: false,
                prefixIcon: const Icon(Icons.pin_outlined),
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.lg),
        AppButton(
          label: 'auth.verify_email'.tr(),
          height: ButtonSize.large,
          isFullWidth: true,
          isLoading: loading,
          suffixIcon: const Icon(Icons.arrow_forward_rounded, size: 20),
          onPressed: _submit,
        ),
        TextButton(
          onPressed: loading ? null : _resend,
          child: Text('auth.resend_code'.tr()),
        ),
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
