import 'src/imports/core_imports.dart';
import 'src/app.dart';

Future<void> main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  await EasyLocalization.ensureInitialized();
  String? startupError;
  try {
    await AppConfig.init();
  } catch (error, stackTrace) {
    AppLogger.error('Salhly initialization failed', error, stackTrace);
    startupError = error is FormatException
        ? error.message
        : AppErrorHandler.format(error);
  }

  runApp(
    LocalizationWrapper(
      child: startupError == null
          ? const StateWrapper(child: App())
          : _StartupErrorApp(message: startupError),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => FlutterNativeSplash.remove(),
  );
}

class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Salhly',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      home: Scaffold(
        appBar: AppBar(title: Text('app.name'.tr())),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'errors.startup'.tr(namedArgs: {'detail': message.tr()}),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
