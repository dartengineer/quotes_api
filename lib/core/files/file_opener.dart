import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_log.dart';

/// A file the user chose, read into memory.
class OpenedFile {
  const OpenedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Thrown when a chosen file is bigger than the caller accepts.
class FileTooLargeException implements Exception {
  const FileTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() => 'FileTooLargeException($maxBytes)';
}

/// Lets the user choose a file for the app to read.
abstract interface class FileOpener {
  /// Shows the system file picker and reads the chosen file. Returns null
  /// if the user cancelled. Throws [FileTooLargeException] rather than
  /// reading more than [maxBytes].
  Future<OpenedFile?> open({required int maxBytes});
}

/// [FileOpener] using the system file picker (Android's Storage Access
/// Framework, via `file_picker`), so no storage permission is needed.
class SystemFileOpener implements FileOpener {
  const SystemFileOpener();

  @override
  Future<OpenedFile?> open({required int maxBytes}) async {
    // Any type: providers report JSON under several MIME types.
    final files = await FilePicker.pickFiles();
    final file = files.firstOrNull;
    if (file == null) return null;
    try {
      final length = await file.length();
      if (length != null && length > maxBytes) {
        throw FileTooLargeException(maxBytes);
      }
      // The reported length can be missing or wrong; count while reading.
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) throw FileTooLargeException(maxBytes);
      }
      return OpenedFile(name: file.name, bytes: bytes.takeBytes());
    } finally {
      await _deleteCopies(files);
    }
  }

  /// Deletes the copies the picker made in the app's cache, which may hold
  /// private data (a backup's notes), leaving any other file alone.
  static Future<void> _deleteCopies(List<PlatformFile> files) async {
    try {
      final cache = p.join((await getTemporaryDirectory()).path, 'file_picker');
      for (final file in files) {
        final path = file.path;
        if (path != null && p.isWithin(cache, path)) {
          await File(path).delete();
        }
      }
    } on Exception catch (error, stackTrace) {
      AppLog.error('Deleting a picked file copy failed', error, stackTrace);
    }
  }
}
