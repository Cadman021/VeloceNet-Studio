/// Single source of truth for release metadata shown in the UI.
/// Keep [kAppVersion] in sync with `pubspec.yaml` and the `v*` git tag.
class AppInfo {
  AppInfo._();

  static const String kAppVersion = '1.1.0';
  static const String kAuthorName = 'Sina Cadman';
  static const String kAuthorUrl = 'https://github.com/Cadman021';
}
