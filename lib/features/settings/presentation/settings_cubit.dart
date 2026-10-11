import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/app_log.dart';
import '../data/settings_repository.dart';
import '../domain/app_settings.dart';

/// Holds app-wide settings. Changes apply immediately and are persisted in
/// the background; a failed write is logged and the in-memory value is kept
/// for the rest of the session.
class SettingsCubit extends Cubit<AppSettings> {
  SettingsCubit(this._repository, AppSettings initial) : super(initial);

  final SettingsRepository _repository;

  Future<void> setThemePreference(ThemePreference value) async {
    if (value == state.themePreference) return;
    emit(state.copyWith(themePreference: value));
    try {
      await _repository.setThemePreference(value);
    } catch (error, stackTrace) {
      AppLog.error('Saving theme preference failed', error, stackTrace);
    }
  }
}
