import 'dart:async';
import 'dart:collection';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/app_log.dart';
import '../../../core/utils/cancellation.dart';
import '../data/document_importer.dart';
import '../data/document_picker.dart';
import '../domain/import_outcome.dart';

sealed class ImportState extends Equatable {
  const ImportState();

  bool get isBusy => this is ImportPreparing || this is ImportRunning;

  @override
  List<Object?> get props => [];
}

final class ImportIdle extends ImportState {
  const ImportIdle();
}

/// The system picker is copying the selected files.
final class ImportPreparing extends ImportState {
  const ImportPreparing();
}

final class ImportRunning extends ImportState {
  const ImportRunning(this.progress, {this.cancelling = false});

  final ImportProgress progress;
  final bool cancelling;

  @override
  List<Object?> get props => [progress, cancelling];
}

final class ImportFinished extends ImportState {
  const ImportFinished(this.report, {this.openWhenDone = false});

  final ImportReport report;

  /// Whether to open the document straight away (an "Open with" request).
  final bool openWhenDone;

  /// The document to show without waiting for the user, if any.
  int? get documentToOpen => openWhenDone ? report.singleDocumentId : null;

  @override
  List<Object?> get props => [report, openWhenDone];
}

/// The file picker could not be opened.
final class ImportPickerFailed extends ImportState {
  const ImportPickerFailed();
}

/// App-wide import controller, so an import keeps running while the user
/// moves between tabs.
///
/// Files that arrive while an import runs (for example a document shared
/// from another app) are queued and reported together with it, never
/// dropped.
class ImportCubit extends Cubit<ImportState> {
  ImportCubit({required this._picker, required this._importer})
    : super(const ImportIdle());

  final DocumentPicker _picker;
  final DocumentImporter _importer;
  final _queue = Queue<_Batch>();
  CancellationToken? _cancellation;
  bool _picking = false;

  bool get _importing => _cancellation != null;

  /// Whether picker progress may be shown: not while another import, or its
  /// summary, is on screen.
  bool get _pickerOwnsState =>
      !isClosed && !_importing && state is! ImportFinished;

  /// Opens the system picker and imports whatever the user selects.
  Future<void> pickAndImport() async {
    if (state.isBusy || _picking) return;
    _picking = true;
    final List<ImportSource> sources;
    try {
      sources = await _picker.pick(
        onPreparing: () {
          if (_pickerOwnsState) emit(const ImportPreparing());
        },
      );
    } catch (error, stackTrace) {
      AppLog.error('Opening the file picker failed', error, stackTrace);
      if (_pickerOwnsState) emit(const ImportPickerFailed());
      return;
    } finally {
      _picking = false;
    }
    if (sources.isEmpty) {
      if (!isClosed && state is ImportPreparing) emit(const ImportIdle());
      if (!_importing) await _clearPickerCopies();
      return;
    }
    await importSources(sources);
  }

  /// Imports already-available files. [rejected] lists files that could not
  /// be received at all, to include in the report. Completes once these
  /// files have been processed.
  Future<void> importSources(
    List<ImportSource> sources, {
    List<ImportOutcome> rejected = const [],
    bool openWhenDone = false,
  }) {
    if (isClosed || (sources.isEmpty && rejected.isEmpty)) {
      return Future.value();
    }
    final batch = _Batch(sources, rejected, openWhenDone: openWhenDone);
    _queue.add(batch);
    if (!_importing) unawaited(_importQueue());
    return batch.done.future;
  }

  Future<void> _importQueue() async {
    final cancellation = _cancellation = CancellationToken();
    final outcomes = <ImportOutcome>[];
    var total = 0;
    var batches = 0;
    var openWhenDone = false;

    void report(ImportProgress progress) {
      if (isClosed) return;
      emit(ImportRunning(progress, cancelling: cancellation.isCancelled));
    }

    while (_queue.isNotEmpty) {
      final batch = _queue.removeFirst();
      batches++;
      total += batch.length;
      openWhenDone = batch.openWhenDone;
      if (cancellation.isCancelled) {
        // Skipped; counted in the report's total.
        batch.done.complete();
        continue;
      }
      outcomes.addAll(batch.rejected);
      final done = outcomes.length;
      report(ImportProgress(completed: done, total: total + _queuedFileCount));
      try {
        final result = await _importer.importAll(
          batch.sources,
          cancellation: cancellation,
          onProgress: (progress) => report(
            ImportProgress(
              completed: done + progress.completed,
              total: total + _queuedFileCount,
              currentFileName: progress.currentFileName,
            ),
          ),
        );
        outcomes.addAll(result.outcomes);
      } catch (error, stackTrace) {
        // The importer reports per-file problems itself; this is a bug.
        // The batch's files show as skipped.
        AppLog.error('Import batch failed', error, stackTrace);
      } finally {
        batch.done.complete();
      }
    }

    // Finish synchronously, so files arriving from now on start a new run.
    _cancellation = null;
    if (!isClosed) {
      emit(
        ImportFinished(
          ImportReport(
            outcomes: outcomes,
            total: total,
            cancelled: cancellation.isCancelled,
          ),
          openWhenDone: openWhenDone && batches == 1,
        ),
      );
    }
    if (!_picking && !_importing) await _clearPickerCopies();
  }

  int get _queuedFileCount => _queue.fold(0, (sum, b) => sum + b.length);

  /// Stops the import; the file in progress is abandoned and the rest
  /// (including queued files) are skipped. Files already imported stay in
  /// the library.
  void cancel() {
    final current = state;
    if (current is! ImportRunning || current.cancelling) return;
    _cancellation?.cancel();
    emit(ImportRunning(current.progress, cancelling: true));
  }

  /// Acknowledges a finished import or picker failure.
  void dismiss() {
    if (!state.isBusy) emit(const ImportIdle());
  }

  Future<void> _clearPickerCopies() async {
    try {
      await _picker.clearTemporaryFiles();
    } catch (error, stackTrace) {
      AppLog.error('Clearing picker copies failed', error, stackTrace);
    }
  }

  @override
  Future<void> close() {
    _cancellation?.cancel();
    return super.close();
  }
}

class _Batch {
  _Batch(this.sources, this.rejected, {required this.openWhenDone});

  final List<ImportSource> sources;
  final List<ImportOutcome> rejected;
  final bool openWhenDone;
  final done = Completer<void>();

  int get length => sources.length + rejected.length;
}
