import 'package:salahly/src/imports/imports.dart';
import 'package:salahly/src/ui/auth/bloc/session_bloc.dart';

class App extends StatefulWidget {
  const App({super.key, this.initialLocation = AppRoutes.home});

  final String initialLocation;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late final AppRouter _appRouter;

  @override
  void initState() {
    super.initState();
    _appRouter = AppRouter(
      context.read<SessionBloc>(),
      initialLocation: widget.initialLocation,
    );
  }

  @override
  void dispose() {
    _appRouter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScreenUtilWrapper(builder: _buildMaterialApp);
  }

  Widget _buildMaterialApp(BuildContext context) {
    return MaterialApp.router(
      title: 'Salhly',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(primaryColorHex: '#0B132B'),
      darkTheme: buildDarkTheme(primaryColorHex: '#0B132B'),
      themeMode: ThemeMode.system,
      routerConfig: _appRouter.router,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      builder: (context, child) => SkeletonWrapper(child: child!),
    );
  }
}
