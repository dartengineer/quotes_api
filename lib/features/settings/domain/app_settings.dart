import 'package:equatable/equatable.dart';

/// The app-wide colour scheme choice.
///
/// The enum [name] is persisted, so values must not be renamed.
enum ThemePreference {
  system('System default'),
  light('Light'),
  dark('Dark');

  const ThemePreference(this.label);

  final String label;
}

/// App-wide settings held by the settings cubit.
class AppSettings extends Equatable {
  const AppSettings({this.themePreference = ThemePreference.system});

  final ThemePreference themePreference;

  AppSettings copyWith({ThemePreference? themePreference}) {
    return AppSettings(
      themePreference: themePreference ?? this.themePreference,
    );
  }

  @override
  List<Object?> get props => [themePreference];
}
