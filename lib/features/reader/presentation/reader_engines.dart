import 'package:material_ui/material_ui.dart';

import '../../../core/theme/reader_palette.dart';
import '../../library/domain/document_format.dart';
import '../domain/annotation.dart';
import '../domain/locator.dart';
import '../domain/reader_preferences.dart';
import 'epub/epub_reader_view.dart';
import 'pdf/pdf_reader_view.dart';
import 'reader_view_controller.dart';
import 'txt/txt_reader_view.dart';

/// Everything a format view needs from the shared reader.
class ReaderViewConfig {
  const ReaderViewConfig({
    required this.filePath,
    required this.initialLocator,
    required this.preferences,
    required this.palette,
    required this.controller,
    required this.onPosition,
    required this.onTapCenter,
    this.annotations = const [],
    this.onSelection,
    this.onAnnotationTap,
  });

  final String filePath;
  final Locator? initialLocator;
  final ReaderPreferences preferences;
  final ReaderPalette palette;
  final ReaderViewController controller;
  final ValueChanged<ReaderPosition> onPosition;

  /// A tap in the middle of the page (toggles the toolbars).
  final VoidCallback onTapCenter;

  /// Highlights and notes to show.
  final List<Annotation> annotations;

  /// The reader selected text; completes when the user has chosen what to
  /// do with it, after which the view clears the selection.
  final Future<void> Function(AnnotationDraft draft)? onSelection;

  /// The reader tapped a highlight.
  final ValueChanged<Annotation>? onAnnotationTap;
}

/// Maps document formats to their reader views. A format is only offered
/// for reading once its view exists and is tested.
abstract final class ReaderEngines {
  static bool supports(DocumentFormat format) => switch (format) {
    DocumentFormat.txt || DocumentFormat.pdf || DocumentFormat.epub => true,
  };

  /// Whether the text reflows, so typography settings apply. PDF pages are
  /// shown as they were laid out.
  static bool isReflowable(DocumentFormat format) => switch (format) {
    DocumentFormat.txt || DocumentFormat.epub => true,
    DocumentFormat.pdf => false,
  };

  static Widget buildView(DocumentFormat format, ReaderViewConfig config) {
    return switch (format) {
      DocumentFormat.txt => TxtReaderView(config: config),
      DocumentFormat.pdf => PdfReaderView(config: config),
      DocumentFormat.epub => EpubReaderView(config: config),
    };
  }
}
