import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/auth_repository.dart';
import 'package:salahly/src/extensions/context_extension.dart';
import 'package:salahly/src/routing/app_routes.dart';
import 'package:salahly/src/shared/enums/button_enums.dart';
import 'package:salahly/src/shared/widgets/app_button.dart';
import 'package:salahly/src/shared/widgets/app_text_field.dart';
import 'package:salahly/src/theme/theme_constants.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';
import 'package:salahly/src/ui/profile/profile_cubit.dart';
import 'package:salahly/src/utils/form_validators.dart';
import 'package:salahly/src/utils/logger.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.select((SessionBloc bloc) => bloc.state.user);
    if (user == null) return const SizedBox.shrink();

    return BlocProvider(
      key: ValueKey(user.id),
      create: (context) => ProfileCubit(context.read<AuthRepository>(), user),
      child: _ProfileView(user: user),
    );
  }
}

class _ProfileView extends StatefulWidget {
  const _ProfileView({required this.user});

  final AppUser user;

  @override
  State<_ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<_ProfileView> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _city;
  bool _hasEdits = false;
  bool _changingLanguage = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.user.name);
    _phone = TextEditingController(text: widget.user.phone ?? '');
    _city = TextEditingController(text: widget.user.city ?? '');
  }

  @override
  void didUpdateWidget(covariant _ProfileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user != widget.user && !_hasEdits) {
      _populate(widget.user);
    }
  }

  void _populate(AppUser user) {
    _name.text = user.name;
    _phone.text = user.phone ?? '';
    _city.text = user.city ?? '';
    _hasEdits = false;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    context.hideKeyboard();
    context.read<ProfileCubit>().save(
      name: _name.text,
      phone: _phone.text,
      city: _city.text,
    );
  }

  Future<void> _changeLanguage(String language) async {
    if (_changingLanguage || context.locale.languageCode == language) return;
    setState(() => _changingLanguage = true);
    try {
      await context.setLocale(Locale(language));
    } catch (error, stackTrace) {
      AppLogger.error('Could not change language', error, stackTrace);
      if (mounted) context.showErrorSnackBar('common.error'.tr());
    } finally {
      if (mounted) setState(() => _changingLanguage = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _city.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionBloc>().state;
    return BlocConsumer<ProfileCubit, ProfileState>(
      listenWhen: (previous, current) => !previous.saved && current.saved,
      listener: (context, state) {
        _populate(state.user);
        context.showSuccessSnackBar('profile.saved'.tr());
      },
      builder: (context, state) {
        final busy = state.isSaving || session.isLoading || _changingLanguage;
        return SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.pagePadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: Padding(
                        padding: EdgeInsets.all(AppSpacing.cardPadding),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'auth.email'.tr(),
                              style: context.textTheme.labelLarge,
                            ),
                            SizedBox(height: AppSpacing.xs),
                            SelectableText(widget.user.email),
                            SizedBox(height: AppSpacing.md),
                            Text(
                              'profile.role'.tr(),
                              style: context.textTheme.labelLarge,
                            ),
                            SizedBox(height: AppSpacing.xs),
                            Text(
                              'roles.${widget.user.role.name}'.tr(),
                              style: context.textTheme.titleMedium,
                            ),
                            SizedBox(height: AppSpacing.sm),
                            Text(
                              'profile.role_note'.tr(),
                              style: context.textTheme.bodySmall,
                            ),
                            if (widget.user.role == UserRole.provider) ...[
                              SizedBox(height: AppSpacing.sm),
                              Text('profile.provider_note'.tr()),
                              SizedBox(height: AppSpacing.md),
                              AppButton(
                                label: 'provider.open'.tr(),
                                variant: ButtonVariant.outline,
                                isFullWidth: true,
                                onPressed: busy
                                    ? null
                                    : () => context.pushNamed(
                                        AppRouteNames.providerOnboarding,
                                      ),
                              ),
                            ],
                            if (widget.user.role == UserRole.customer) ...[
                              SizedBox(height: AppSpacing.md),
                              AppButton(
                                label: 'requests.history_title'.tr(),
                                variant: ButtonVariant.outline,
                                isFullWidth: true,
                                prefixIcon: const Icon(
                                  Icons.receipt_long_outlined,
                                ),
                                onPressed: busy
                                    ? null
                                    : () => context.pushNamed(
                                        AppRouteNames.serviceRequests,
                                      ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: AppSpacing.lg),
                    Form(
                      key: _formKey,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      onChanged: () => _hasEdits = true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppTextField(
                            label: 'auth.name'.tr(),
                            controller: _name,
                            validator: FormValidators.name,
                            textInputAction: TextInputAction.next,
                            enabled: !busy,
                          ),
                          SizedBox(height: AppSpacing.formFieldGap),
                          AppTextField(
                            label: 'profile.phone'.tr(),
                            controller: _phone,
                            validator: FormValidators.phone,
                            keyboardType: TextInputType.phone,
                            textInputAction: TextInputAction.next,
                            enabled: !busy,
                          ),
                          SizedBox(height: AppSpacing.formFieldGap),
                          AppTextField(
                            label: 'profile.city'.tr(),
                            controller: _city,
                            validator: FormValidators.city,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: busy ? null : (_) => _save(),
                            enabled: !busy,
                          ),
                          if (state.errorMessage != null) ...[
                            SizedBox(height: AppSpacing.ms),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                state.errorMessage!.tr(),
                                style: context.textTheme.bodyMedium?.copyWith(
                                  color: context.colors.error,
                                ),
                              ),
                            ),
                          ],
                          SizedBox(height: AppSpacing.md),
                          AppButton(
                            label: 'common.save'.tr(),
                            isFullWidth: true,
                            isLoading: state.isSaving,
                            onPressed: busy ? null : _save,
                          ),
                        ],
                      ),
                    ),
                    if (context.read<AuthRepository>().isDemo) ...[
                      SizedBox(height: AppSpacing.ms),
                      Text(
                        'profile.demo_note'.tr(),
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    SizedBox(height: AppSpacing.lg),
                    Text(
                      'profile.language'.tr(),
                      style: context.textTheme.titleMedium,
                    ),
                    SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        for (final language in const ['en', 'ar'])
                          ChoiceChip(
                            label: Text(
                              (language == 'en'
                                      ? 'profile.english'
                                      : 'profile.arabic')
                                  .tr(),
                            ),
                            selected: context.locale.languageCode == language,
                            onSelected: busy
                                ? null
                                : (selected) {
                                    if (selected) _changeLanguage(language);
                                  },
                          ),
                      ],
                    ),
                    if (_changingLanguage)
                      Text(
                        'common.loading'.tr(),
                        style: context.textTheme.bodySmall,
                      ),
                    SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: 'profile.sign_out'.tr(),
                      variant: ButtonVariant.outline,
                      isFullWidth: true,
                      isLoading: session.isLoading,
                      onPressed: busy
                          ? null
                          : () {
                              context.hideKeyboard();
                              context.read<SessionBloc>().add(
                                const SessionLogoutRequested(),
                              );
                            },
                    ),
                    if (session.errorMessage != null) ...[
                      SizedBox(height: AppSpacing.ms),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          session.errorMessage!.tr(),
                          style: context.textTheme.bodyMedium?.copyWith(
                            color: context.colors.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
