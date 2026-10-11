/// Static app identity.
abstract final class AppInfo {
  static const name = 'Lectern';

  /// Must match `version` in pubspec.yaml (without the build number);
  /// a unit test enforces this.
  static const version = '0.1.0';
}
