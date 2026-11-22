import 'package:material_ui/material_ui.dart';
// `GlobalMaterialLocalizations` now ships with material_ui; the
// flutter_localizations copy is the deprecated one, so hide that name here
// instead of letting the two imports collide.
import 'package:flutter_localizations/flutter_localizations.dart'
    hide GlobalMaterialLocalizations;
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
