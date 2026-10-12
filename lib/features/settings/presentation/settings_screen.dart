import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/app_info.dart';
import '../../../core/widgets/section_header.dart';
import '../../backup/presentation/backup_section.dart';
import '../domain/app_settings.dart';
import 'settings_cubit.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SectionHeader(title: 'Appearance'),
          const _ThemeOptions(),
          const SectionHeader(title: 'Your data'),
          const BackupSection(),
          const SectionHeader(title: 'Privacy'),
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('Stored on this device'),
            subtitle: Text(
              'Your library, reading progress and notes are kept only on '
              'this device. Nothing is uploaded. Backups are saved only '
              'where you choose, and hold your notes as readable text.',
            ),
          ),
          const SectionHeader(title: 'About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text(AppInfo.name),
            subtitle: const Text('Version ${AppInfo.version}'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Open-source licences'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: AppInfo.name,
              applicationVersion: AppInfo.version,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeOptions extends StatelessWidget {
  const _ThemeOptions();

  @override
  Widget build(BuildContext context) {
    final preference = context.select(
      (SettingsCubit c) => c.state.themePreference,
    );
    return RadioGroup<ThemePreference>(
      groupValue: preference,
      onChanged: (value) {
        if (value != null) {
          unawaited(context.read<SettingsCubit>().setThemePreference(value));
        }
      },
      child: Column(
        children: [
          for (final option in ThemePreference.values)
            RadioListTile<ThemePreference>(
              value: option,
              title: Text(option.label),
              secondary: Icon(switch (option) {
                ThemePreference.system => Icons.brightness_auto_outlined,
                ThemePreference.light => Icons.light_mode_outlined,
                ThemePreference.dark => Icons.dark_mode_outlined,
              }),
            ),
        ],
      ),
    );
  }
}
