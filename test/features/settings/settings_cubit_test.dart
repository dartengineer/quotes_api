import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/settings/data/settings_repository.dart';
import 'package:lectern/features/settings/domain/app_settings.dart';
import 'package:lectern/features/settings/presentation/settings_cubit.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository repository;

  setUp(() {
    db = createTestDatabase();
    repository = SettingsRepository(db);
  });

  tearDown(() => db.close());

  blocTest<SettingsCubit, AppSettings>(
    'emits and persists a new theme preference',
    build: () => SettingsCubit(repository, const AppSettings()),
    act: (cubit) => cubit.setThemePreference(ThemePreference.dark),
    expect: () => [const AppSettings(themePreference: ThemePreference.dark)],
    verify: (_) async {
      final stored = await repository.load();
      expect(stored.appSettings.themePreference, ThemePreference.dark);
    },
  );

  blocTest<SettingsCubit, AppSettings>(
    'selecting the current preference emits nothing',
    build: () => SettingsCubit(repository, const AppSettings()),
    act: (cubit) => cubit.setThemePreference(ThemePreference.system),
    expect: () => <AppSettings>[],
  );
}
