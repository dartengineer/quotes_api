import 'package:file_picker/file_picker.dart';

import '../domain/import_outcome.dart';

/// Lets the user choose documents to import.
abstract interface class DocumentPicker {
  /// Shows the system file picker and returns the chosen files (empty if the
  /// user cancelled). [onPreparing] is called while the platform is copying
  /// the selection into app storage, which can take a while for large files
  /// or cloud documents.
  Future<List<ImportSource>> pick({void Function()? onPreparing});

  /// Deletes temporary copies the picker left behind.
  Future<void> clearTemporaryFiles();
}

/// [DocumentPicker] using the Android Storage Access Framework (via
/// `file_picker`). No storage permission is needed: the user grants access to
/// exactly the files they pick, from any document provider (Downloads, Drive,
/// USB storage...). The plugin hands back app-private copies, which the
/// importer moves into the library.
class SystemDocumentPicker implements DocumentPicker {
  const SystemDocumentPicker();

  @override
  Future<List<ImportSource>> pick({void Function()? onPreparing}) async {
    // Any type: providers often report wrong MIME types for EPUBs, so
    // formats are identified by content after picking instead.
    final files = await FilePicker.pickFiles(
      onFileLoading: (status) {
        if (status == FilePickerStatus.picking) onPreparing?.call();
      },
    );
    return [
      for (final file in files)
        if (file.path case final path?)
          ImportSource(path: path, displayName: file.name),
    ];
  }

  @override
  Future<void> clearTemporaryFiles() => FilePicker.clearTemporaryFiles();
}
