import 'dart:convert';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/core/files/file_opener.dart';
import 'package:lectern/features/backup/data/backup_codec.dart';
import 'package:lectern/features/backup/domain/reading_backup.dart';
import 'package:lectern/features/backup/presentation/backup_section.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/settings/domain/app_settings.dart';
import 'package:lectern/features/settings/presentation/settings_cubit.dart';
import 'package:lectern/features/settings/presentation/settings_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_dependencies.dart';

String hashOf(int n) => n.toRadixString(16).padLeft(64, '0');

void main() {
  late AppDependencies deps;
  late FakeFileSaver saver;
  late FakeFileOpener opener;

  setUp(() async {
    saver = FakeFileSaver();
    opener = FakeFileOpener();
    deps = await createTestDependencies(fileSaver: saver, fileOpener: opener);
  });

  tearDown(() => disposeTestDependencies(deps));

  Future<void> tapTile(WidgetTester tester, String title) async {
    await tester.ensureVisible(find.text(title));
    await tester.tap(find.text(title));
    await tester.pump();
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    await pumpUntil(tester, () => finder.evaluate().isNotEmpty);
    await settle(tester);
  }

  OpenedFile backupFile(ReadingBackup backup) =>
      OpenedFile(name: 'backup.json', bytes: encodeBackup(backup));

  test('backup files are named by date', () {
    expect(
      backupFileName(DateTime(2026, 3, 7, 23, 59)),
      'Lectern reading data 2026-03-07.json',
    );
  });

  testWidgets('backing up saves the reading data as JSON', (tester) async {
    final id = await addTestDocument(deps.library, contentHash: hashOf(1));
    await deps.library.setFavorite([id], favorite: true);
    await pumpApp(tester, deps, location: Routes.settings);

    // Cancelling the save dialog saves nothing and says nothing.
    saver.cancel = true;
    await tapTile(tester, 'Back up reading data');
    await pumpUntil(
      tester,
      () => tester
          .widget<ListTile>(
            find.widgetWithText(ListTile, 'Back up reading data'),
          )
          .enabled,
    );
    await settle(tester);
    expect(find.byType(SnackBar), findsNothing);

    saver.cancel = false;
    await tapTile(tester, 'Back up reading data');
    await waitFor(tester, find.text('Backup saved'));
    final (name, bytes, mime) = saver.saved.single;
    expect(
      name,
      matches(RegExp(r'^Lectern reading data \d{4}-\d\d-\d\d\.json$')),
    );
    expect(mime, 'application/json');
    final backup = decodeBackup(bytes);
    expect(backup.documents.single.contentHash, hashOf(1));
    expect(backup.documents.single.favorite, isTrue);
    await unmountApp(tester);
  });

  testWidgets('a failed backup is reported', (tester) async {
    saver.error = const FileSystemException('No space');
    await pumpApp(tester, deps, location: Routes.settings);
    await tapTile(tester, 'Back up reading data');
    await waitFor(tester, find.text('The backup could not be saved'));
    await unmountApp(tester);
  });

  testWidgets('restoring asks first, then reports what changed', (
    tester,
  ) async {
    final id = await addTestDocument(deps.library, contentHash: hashOf(1));
    opener.next = backupFile(
      ReadingBackup(
        createdAt: DateTime.utc(2026, 3, 1, 12),
        settings: const {'app.theme': 'dark'},
        documents: [
          BackupDocument(
            contentHash: hashOf(1),
            title: 'Book 1',
            favorite: true,
            bookmarks: [
              BackupBookmark(
                locator: const EpubLocator(href: 'ch1.xhtml', offset: 4),
                progress: 0.1,
                createdAt: DateTime.utc(2026, 2, 1),
              ),
            ],
          ),
          BackupDocument(contentHash: hashOf(9), title: 'Missing Book'),
        ],
      ),
    );
    await pumpApp(tester, deps, location: Routes.settings);

    // Cancelling the confirmation changes nothing.
    await tapTile(tester, 'Restore from backup');
    await waitFor(tester, find.text('Restore reading data?'));
    expect(opener.lastMaxBytes, BackupLimits.maxFileBytes);
    expect(
      find.textContaining('has reading data for 2 documents'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Your theme and reading settings will be replaced'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(
      (await resolve(tester, deps.library.findById(id)))!.isFavorite,
      isFalse,
    );

    await tapTile(tester, 'Restore from backup');
    await waitFor(tester, find.text('Restore reading data?'));
    await tester.tap(find.text('Restore'));
    await waitFor(tester, find.text('Backup restored'));
    expect(find.text('Reading data restored for 1 document.'), findsOneWidget);
    expect(find.text('1 bookmark added'), findsOneWidget);
    expect(find.text('Theme and reading settings restored'), findsOneWidget);
    expect(
      find.textContaining('1 document in the backup is not in your library'),
      findsOneWidget,
    );
    expect(find.text('Missing Book'), findsOneWidget);

    // The theme applies at once.
    final settings = tester.element(find.byType(SettingsScreen));
    expect(
      settings.read<SettingsCubit>().state.themePreference,
      ThemePreference.dark,
    );
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    await tester.tap(find.text('OK'));
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      (await resolve(tester, deps.library.findById(id)))!.isFavorite,
      isTrue,
    );
    await unmountApp(tester);
  });

  testWidgets('files that cannot be restored are explained', (tester) async {
    await pumpApp(tester, deps, location: Routes.settings);
    final cases = <(void Function(), String)>[
      (
        () => opener.next = OpenedFile(
          name: 'notes.txt',
          bytes: utf8.encode('Just some notes'),
        ),
        'This file is not a Lectern backup, or it is damaged.',
      ),
      (
        () => opener.next = OpenedFile(
          name: 'future.json',
          bytes: utf8.encode(
            jsonEncode({
              'format': 'lectern-reading-data',
              'version': 99,
              'createdAt': '2030-01-01T00:00:00Z',
              'documents': <Object?>[],
            }),
          ),
        ),
        'This backup was made by a newer version of Lectern. Update the app '
            'to restore it.',
      ),
      (
        () => opener.error = const FileTooLargeException(1),
        'This file is too large to be a Lectern backup.',
      ),
      (
        () => opener.error = const FileSystemException('Unreadable'),
        'The file could not be read.',
      ),
    ];
    for (final (prepare, message) in cases) {
      opener
        ..next = null
        ..error = null;
      prepare();
      await tapTile(tester, 'Restore from backup');
      await waitFor(tester, find.text('Couldn’t restore'));
      expect(find.text(message), findsOneWidget);
      await tester.tap(find.text('OK'));
      await settle(tester);
    }
    await unmountApp(tester);
  });

  testWidgets('a backup with nothing new says so', (tester) async {
    opener.next = backupFile(ReadingBackup(createdAt: DateTime.utc(2026)));
    await pumpApp(tester, deps, location: Routes.settings);
    await tapTile(tester, 'Restore from backup');
    await waitFor(tester, find.text('Restore reading data?'));
    await tester.tap(find.text('Restore'));
    await waitFor(tester, find.text('Nothing restored'));
    expect(find.text('This backup has no reading data.'), findsOneWidget);
    await unmountApp(tester);
  });
}
