import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Saves a file where the user chooses.
abstract interface class FileSaver {
  /// Returns false if the user cancelled.
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  });
}

/// [FileSaver] using the system "save as" dialog (Android's Storage Access
/// Framework, via `file_picker`). The user picks the place and the name; no
/// storage permission is needed, and nothing is written anywhere else.
class SystemFileSaver implements FileSaver {
  const SystemFileSaver();

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
    );
    return uri != null;
  }
}
