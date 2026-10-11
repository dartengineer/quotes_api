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
  const ImportFinished(this.report);

  final ImportReport report;

  @override
  List<Object?> get props => [report];
}

/// The file picker could not be opened.
final class ImportPickerFailed extends ImportState {
  const ImportPickerFailed();
}

/// App-wide import controller, so an import keeps running while the user
/// moves between tabs.
class ImportCubit extends Cubit<ImportState> {
  ImportCubit({required this._picker, required this._importer})
    : super(const ImportIdle());

  final DocumentPicker _picker;
  final DocumentImporter _importer;
  CancellationToken? _cancellation;

  /// Opens the system picker and imports whatever the user selects.
  Future<void> pickAndImport() async {
    if (state.isBusy) return;
    final List<ImportSource> sources;
    try {
      sources = await _picker.pick(
        onPreparing: () {
          if (!isClosed) emit(const ImportPreparing());
        },
      );
    } catch (error, stackTrace) {
      AppLog.error('Opening the file picker failed', error, stackTrace);
      if (!isClosed) emit(const ImportPickerFailed());
      return;
    }
    if (sources.isEmpty) {
      if (!isClosed) emit(const ImportIdle());
      await _clearPickerCopies();
      return;
    }
    await importSources(sources);
  }

  /// Imports already-available files.
  Future<void> importSources(List<ImportSource> sources) async {
    if (state is ImportRunning) return;
    final cancellation = _cancellation = CancellationToken();
    emit(ImportRunning(ImportProgress(completed: 0, total: sources.length)));

    final report = await _importer.importAll(
      sources,
      cancellation: cancellation,
      onProgress: (progress) {
        if (isClosed || state is! ImportRunning) return;
        emit(ImportRunning(progress, cancelling: cancellation.isCancelled));
      },
    );
    _cancellation = null;
    await _clearPickerCopies();
    if (!isClosed) emit(ImportFinished(report));
  }

  /// Stops the import; the file in progress is abandoned and the rest are
  /// skipped. Files already imported stay in the library.
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
