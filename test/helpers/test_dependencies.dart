import 'dart:io';
import 'dart:typed_data';

import 'package:lectern/app/dependencies.dart';
import 'package:lectern/core/files/file_opener.dart';
import 'package:lectern/core/files/file_saver.dart';
import 'package:lectern/data/files/library_storage.dart';
import 'package:lectern/engines/pdf/pdf_inspector.dart';
import 'package:lectern/features/import/data/document_picker.dart';
import 'package:lectern/features/import/domain/import_outcome.dart';

import 'test_database.dart';

/// A picker that returns preset files instead of showing system UI.
class FakeDocumentPicker implements DocumentPicker {
  List<ImportSource> next = const [];
  Object? error;
  int clearCalls = 0;

  /// Report "preparing" even when nothing comes back (every copy failed).
  bool prepareEvenIfEmpty = false;

  /// When set, the picker stays in "preparing" until this completes.
  Future<void>? preparing;

  @override
  Future<List<ImportSource>> pick({void Function()? onPreparing}) async {
    if (error case final error?) throw error;
    if (next.isNotEmpty || prepareEvenIfEmpty) {
      onPreparing?.call();
      await preparing;
    }
    return next;
  }

  @override
  Future<void> clearTemporaryFiles() async => clearCalls++;
}

/// A file saver that records what would have been saved.
class FakeFileSaver implements FileSaver {
  final saved = <(String, Uint8List, String)>[];
  bool cancel = false;
  Object? error;

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (error case final error?) throw error;
    if (cancel) return false;
    saved.add((fileName, bytes, mimeType));
    return true;
  }
}

/// A file opener that returns a preset file instead of showing system UI.
class FakeFileOpener implements FileOpener {
  OpenedFile? next;
  Object? error;
  int? lastMaxBytes;

  @override
  Future<OpenedFile?> open({required int maxBytes}) async {
    lastMaxBytes = maxBytes;
    if (error case final error?) throw error;
    final file = next;
    if (file != null && file.bytes.length > maxBytes) {
      throw FileTooLargeException(maxBytes);
    }
    return file;
  }
}

/// App dependencies backed by an in-memory database and a temporary
/// library directory. Call [disposeTestDependencies] when done.
Future<AppDependencies> createTestDependencies({
  DocumentPicker? picker,
  FileSaver? fileSaver,
  FileOpener? fileOpener,
}) async {
  final base = await Directory.systemTemp.createTemp('lectern_deps');
  final storage = LibraryStorage(
    root: Directory('${base.path}/library'),
    temporaryDirectory: Directory('${base.path}/cache'),
  );
  await storage.ensureDirectories();
  return AppDependencies(
    database: createTestDatabase(),
    storage: storage,
    picker: picker ?? FakeDocumentPicker(),
    fileSaver: fileSaver ?? FakeFileSaver(),
    fileOpener: fileOpener ?? FakeFileOpener(),
    pdfInspector: PdfrxInspector(initialize: () async {}),
  );
}

Future<void> disposeTestDependencies(AppDependencies deps) async {
  await deps.dispose();
  final base = deps.storage.root.parent;
  if (base.existsSync()) await base.delete(recursive: true);
}
