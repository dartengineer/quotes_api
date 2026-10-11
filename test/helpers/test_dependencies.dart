import 'dart:io';

import 'package:lectern/app/dependencies.dart';
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

  @override
  Future<List<ImportSource>> pick({void Function()? onPreparing}) async {
    if (error case final error?) throw error;
    if (next.isNotEmpty) onPreparing?.call();
    return next;
  }

  @override
  Future<void> clearTemporaryFiles() async => clearCalls++;
}

/// App dependencies backed by an in-memory database and a temporary
/// library directory. Call [disposeTestDependencies] when done.
Future<AppDependencies> createTestDependencies({DocumentPicker? picker}) async {
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
    pdfInspector: PdfrxInspector(initialize: () async {}),
  );
}

Future<void> disposeTestDependencies(AppDependencies deps) async {
  await deps.dispose();
  final base = deps.storage.root.parent;
  if (base.existsSync()) await base.delete(recursive: true);
}
