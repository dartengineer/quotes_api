import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/app_info.dart';
import '../../../core/files/file_opener.dart';
import '../../../core/files/file_saver.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/app_log.dart';
import '../../settings/presentation/settings_cubit.dart';
import '../data/backup_codec.dart';
import '../data/reading_data_backup.dart';
import '../domain/reading_backup.dart';

/// The name a backup is saved under, with the local date.
String backupFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${AppInfo.name} reading data '
      '${now.year}-${two(now.month)}-${two(now.day)}.json';
}

/// Settings entries to back up reading data to a file and restore it.
class BackupSection extends StatefulWidget {
  const BackupSection({super.key, this.clock = DateTime.now});

  final DateTime Function() clock;

  @override
  State<BackupSection> createState() => _BackupSectionState();
}

enum _Task { backUp, restore }

class _BackupSectionState extends State<BackupSection> {
  _Task? _task;

  @override
  Widget build(BuildContext context) {
    final busy = _task != null;
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.save_alt_outlined),
          title: const Text('Back up reading data'),
          subtitle: const Text(
            'Progress, bookmarks, highlights, notes, collections and reading '
            'settings, saved as a file where you choose. The documents '
            'themselves are not included.',
          ),
          trailing: _task == _Task.backUp ? const _Working() : null,
          enabled: !busy,
          onTap: _backUp,
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('Restore from backup'),
          subtitle: const Text(
            'Adds the reading data in a backup to the matching documents in '
            'your library. Nothing is deleted.',
          ),
          trailing: _task == _Task.restore ? const _Working() : null,
          enabled: !busy,
          onTap: _restore,
        ),
      ],
    );
  }

  /// Runs [work], showing [task] as in progress meanwhile.
  Future<T> _run<T>(_Task task, Future<T> Function() work) async {
    setState(() => _task = task);
    try {
      return await work();
    } finally {
      if (mounted) setState(() => _task = null);
    }
  }

  Future<void> _backUp() async {
    final service = context.read<ReadingDataBackup>();
    final saver = context.read<FileSaver>();
    final messenger = ScaffoldMessenger.of(context);
    final fileName = backupFileName(widget.clock());
    try {
      final saved = await _run(_Task.backUp, () async {
        final bytes = await encodeBackupInBackground(await service.create());
        return saver.save(
          fileName: fileName,
          bytes: bytes,
          mimeType: 'application/json',
        );
      });
      if (saved) {
        messenger.showSnackBar(const SnackBar(content: Text('Backup saved')));
      }
    } on BackupFormatException {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Your reading data is too large for one backup file'),
        ),
      );
    } catch (error, stackTrace) {
      AppLog.error('Backing up reading data failed', error, stackTrace);
      messenger.showSnackBar(
        const SnackBar(content: Text('The backup could not be saved')),
      );
    }
  }

  Future<void> _restore() async {
    final service = context.read<ReadingDataBackup>();
    final opener = context.read<FileOpener>();
    final settings = context.read<SettingsCubit>();

    final ReadingBackup? backup;
    try {
      backup = await _run(_Task.restore, () async {
        final file = await opener.open(maxBytes: BackupLimits.maxFileBytes);
        return file == null ? null : decodeBackupInBackground(file.bytes);
      });
    } on FileTooLargeException {
      await _showProblem(_tooLarge);
      return;
    } on BackupFormatException catch (e) {
      await _showProblem(switch (e.problem) {
        BackupProblem.notBackup =>
          'This file is not a ${AppInfo.name} backup, or it is damaged.',
        BackupProblem.newerVersion =>
          'This backup was made by a newer version of ${AppInfo.name}. '
              'Update the app to restore it.',
        BackupProblem.tooLarge => _tooLarge,
      });
      return;
    } catch (error, stackTrace) {
      AppLog.error('Reading a backup file failed', error, stackTrace);
      await _showProblem('The file could not be read.');
      return;
    }
    if (backup == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ConfirmRestoreDialog(backup: backup!),
    );
    if (confirmed != true || !mounted) return;

    final RestoreReport report;
    try {
      report = await _run(_Task.restore, () => service.restore(backup!));
    } catch (error, stackTrace) {
      AppLog.error('Restoring reading data failed', error, stackTrace);
      await _showProblem(
        'Restoring failed. Your library has not been changed.',
      );
      return;
    }
    if (report.settingsRestored) await settings.reload();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _RestoreReportDialog(report: report),
    );
  }

  static const _tooLarge =
      'This file is too large to be a ${AppInfo.name} backup.';

  Future<void> _showProblem(String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Couldn’t restore'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(
      dimension: 24,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        semanticsLabel: 'Working',
      ),
    );
  }
}

class _ConfirmRestoreDialog extends StatelessWidget {
  const _ConfirmRestoreDialog({required this.backup});

  final ReadingBackup backup;

  @override
  Widget build(BuildContext context) {
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(backup.createdAt.toLocal());
    final documents = backup.documents.length;
    return AlertDialog(
      title: const Text('Restore reading data?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This backup from $date has reading data for '
              '${_count(documents, 'document')}.',
            ),
            const SizedBox(height: Spacing.md),
            const Text(
              'Bookmarks, highlights, notes and reading history are added to '
              'what you have, and a newer reading position replaces an older '
              'one. Nothing is deleted.',
            ),
            if (backup.settings.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              const Text(
                'Your theme and reading settings will be replaced by the ones '
                'in the backup.',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

class _RestoreReportDialog extends StatelessWidget {
  const _RestoreReportDialog({required this.report});

  final RestoreReport report;

  /// How many missing documents are named; the rest are counted.
  static const _namedMissing = 5;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final changes = [
      if (r.positionsRestored > 0)
        '${_count(r.positionsRestored, 'reading position')} restored',
      if (r.bookmarksAdded > 0) '${_count(r.bookmarksAdded, 'bookmark')} added',
      if (r.highlightsAdded > 0)
        '${_count(r.highlightsAdded, 'highlight')} added',
      if (r.highlightsUpdated > 0)
        '${_count(r.highlightsUpdated, 'highlight')} updated',
      if (r.sessionsAdded > 0)
        '${_count(r.sessionsAdded, 'reading session')} added',
      if (r.collectionsCreated > 0)
        '${_count(r.collectionsCreated, 'collection')} created',
      if (r.collectionEntriesAdded > 0)
        '${_count(r.collectionEntriesAdded, 'document')} added to collections',
      if (r.settingsRestored) 'Theme and reading settings restored',
    ];
    final missing = r.missingTitles;
    final one = missing.length == 1;
    final paragraphs = <Widget>[
      if (r.updatedBooks > 0)
        Text('Reading data restored for ${_count(r.updatedBooks, 'document')}.')
      else if (r.matchedBooks > 0)
        const Text('Your library already has everything in this backup.'),
      if (changes.isNotEmpty) _Bullets(changes),
      if (missing.isNotEmpty) ...[
        Text(
          '${_count(missing.length, 'document')} in the backup '
          '${one ? 'is' : 'are'} not in your library. Import '
          '${one ? 'it' : 'them'}, then restore the backup again to bring '
          'back ${one ? 'its' : 'their'} reading data:',
        ),
        _Bullets([
          ...missing.take(_namedMissing),
          if (missing.length > _namedMissing)
            'and ${missing.length - _namedMissing} more',
        ]),
      ],
      if (r.skippedEntries > 0)
        Text(
          r.skippedEntries == 1
              ? '1 entry could not be used and was skipped.'
              : '${r.skippedEntries} entries could not be used and were '
                    'skipped.',
        ),
      if (r.matchedBooks == 0 && missing.isEmpty && changes.isEmpty)
        const Text('This backup has no reading data.'),
    ];
    return AlertDialog(
      title: Text(r.changedAnything ? 'Backup restored' : 'Nothing restored'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, paragraph) in paragraphs.indexed) ...[
              if (i > 0) const SizedBox(height: Spacing.md),
              paragraph,
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class _Bullets extends StatelessWidget {
  const _Bullets(this.items);

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: Text(item)),
              ],
            ),
          ),
      ],
    );
  }
}

String _count(int count, String noun) =>
    '$count ${count == 1 ? noun : '${noun}s'}';
