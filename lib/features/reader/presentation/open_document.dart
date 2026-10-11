import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/routes.dart';
import '../../library/data/library_repository.dart';
import '../../library/domain/library_document.dart';
import 'reader_engines.dart';

/// Opens [document] in its reader, or its details page when no reader for
/// its format exists yet.
void openDocument(BuildContext context, LibraryDocument document) {
  final route = canRead(document)
      ? Routes.read(document.id)
      : Routes.document(document.id);
  unawaited(context.push(route));
}

/// Opens the library document with [id], if it still exists.
Future<void> openDocumentById(BuildContext context, int id) async {
  final document = await context.read<LibraryRepository>().findById(id);
  if (document != null && context.mounted) openDocument(context, document);
}

bool canRead(LibraryDocument document) =>
    ReaderEngines.supports(document.format);
