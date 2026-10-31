import 'dart:async';

import '../../imports/imports.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/auth_repository_impl.dart';
import '../../data/repositories/demo_auth_repository.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/notifications_repository.dart';
import '../../data/repositories/provider_repository.dart';
import '../../services/verification_document_picker.dart';
import '../../ui/auth/bloc/session_bloc.dart';

/// Composition root. Repositories are shared; feature cubits remain page-scoped.
class StateWrapper extends StatelessWidget {
  final Widget child;
  final AuthRepository? authRepository;
  final ProviderRepository? providerRepository;
  final VerificationDocumentPicker? verificationDocumentPicker;

  const StateWrapper({
    super.key,
    required this.child,
    this.authRepository,
    this.providerRepository,
    this.verificationDocumentPicker,
  });

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<AuthRepository>(
          create: (_) =>
              authRepository ??
              (AppConfig.isDemoMode
                  ? DemoAuthRepository()
                  : AuthRepositoryImpl()),
          dispose: (repository) => unawaited(repository.dispose()),
        ),
        RepositoryProvider<CatalogRepository>(
          create: (context) => CatalogRepository(
            client: context.read<AuthRepository>().isDemo
                ? null
                : AppConfig.supabase!,
          ),
        ),
        RepositoryProvider<NotificationsRepository>(
          create: (context) => NotificationsRepository(
            client: context.read<AuthRepository>().isDemo
                ? null
                : AppConfig.supabase!,
          ),
        ),
        RepositoryProvider<ProviderRepository>(
          create: (context) =>
              providerRepository ??
              ProviderRepository(
                authRepository: context.read<AuthRepository>(),
                client: context.read<AuthRepository>().isDemo
                    ? null
                    : AppConfig.supabase!,
              ),
        ),
        RepositoryProvider<VerificationDocumentPicker>(
          create: (_) =>
              verificationDocumentPicker ?? VerificationDocumentPicker.instance,
        ),
      ],
      child: BlocProvider<SessionBloc>(
        lazy: false,
        create: (context) =>
            SessionBloc(repository: context.read<AuthRepository>()),
        child: child,
      ),
    );
  }
}
