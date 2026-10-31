import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/imports/imports.dart';
import 'package:salahly/src/ui/auth/widgets/account_role_card.dart';
import 'package:salahly/src/ui/auth/widgets/auth_layout.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  UserRole _role = UserRole.customer;

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      title: 'onboarding.title'.tr(),
      subtitle: 'onboarding.subtitle'.tr(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final role in UserRole.values) ...[
            AccountRoleCard(
              key: ValueKey('welcome-role-${role.name}'),
              role: role,
              selected: role == _role,
              onTap: () => setState(() => _role = role),
            ),
            SizedBox(height: AppSpacing.md),
          ],
          AppCard(
            padding: EdgeInsets.all(AppSpacing.ml),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'onboarding.email_start'.tr(),
                  style: context.textTheme.titleMedium,
                ),
                SizedBox(height: AppSpacing.sm),
                Text(
                  'onboarding.email_note'.tr(),
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: AppSpacing.lg),
                AppButton(
                  label: 'auth.create_account'.tr(),
                  height: ButtonSize.large,
                  isFullWidth: true,
                  suffixIcon: const Icon(Icons.arrow_forward_rounded, size: 20),
                  onPressed: () => context.goNamed(
                    AppRouteNames.signup,
                    queryParameters: {'role': _role.name},
                  ),
                ),
                SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () => context.goNamed(AppRouteNames.login),
                  child: Text('auth.sign_in'.tr()),
                ),
              ],
            ),
          ),
          SizedBox(height: AppSpacing.md),
          Text(
            'onboarding.availability_note'.tr(),
            textAlign: TextAlign.center,
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
