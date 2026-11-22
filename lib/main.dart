import 'package:material_ui/material_ui.dart';
// Flutter 3.50 splits Cupertino out of the framework too: the delegate must
// come from cupertino_ui, the package material_ui is built on, and the
// flutter_localizations copies of both delegates are the deprecated ones.
import 'package:cupertino_ui/cupertino_ui.dart'
    show GlobalCupertinoLocalizations;
// `GlobalWidgetsLocalizations` is the only delegate still taken from here.
import 'package:flutter_localizations/flutter_localizations.dart'
    hide GlobalCupertinoLocalizations, GlobalMaterialLocalizations;
import 'core/i18n/app_strings.dart';
import 'core/settings/settings_controller.dart';
import 'core/theme/app_theme.dart';
import 'views/main_shell_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dictionaries must be in memory before the first frame: AppStrings.get
  // is synchronous by design (see core/i18n/app_strings.dart).
  await AppStrings.ensureLoaded();
  final settings = SettingsController();
  await settings.load();
  runApp(NetStudioApp(settings: settings));
}

class NetStudioApp extends StatelessWidget {
  final SettingsController settings;
  const NetStudioApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'VeloceNet-Studio - Network Monitor & Analysis',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: settings.themeMode,
          locale: settings.locale,
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: MainShellView(settings: settings),
        );
      },
    );
  }
}
