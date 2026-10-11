import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../../core/images/thumbnail_encoder.dart';

/// Basic facts about a PDF needed at import time.
class PdfInspection {
  const PdfInspection({
    required this.isPasswordProtected,
    this.pageCount,
    this.firstPage,
  });

  /// The PDF needs a password to open. Page count and preview are unknown
  /// until the user provides it.
  final bool isPasswordProtected;
  final int? pageCount;

  /// The first page rendered at thumbnail size.
  final RawPixels? firstPage;
}

/// Thrown when a file claims to be a PDF but PDFium cannot open it.
class PdfUnreadableException implements Exception {
  const PdfUnreadableException(this.detail);

  final String detail;

  @override
  String toString() => 'PdfUnreadableException($detail)';
}

abstract interface class PdfInspector {
  Future<PdfInspection> inspect(String path);
}

/// [PdfInspector] backed by PDFium through pdfrx. PDFium work runs on
/// pdfrx's background worker, not the UI isolate.
class PdfrxInspector implements PdfInspector {
  const PdfrxInspector();

  @override
  Future<PdfInspection> inspect(String path) async {
    final PdfDocument document;
    try {
      // No password provider: PDFium tries the empty password (which opens
      // PDFs that are only permission-restricted) and otherwise fails.
      document = await PdfDocument.openFile(path);
    } on PdfPasswordException {
      return const PdfInspection(isPasswordProtected: true);
    } on Exception catch (error) {
      throw PdfUnreadableException(error.runtimeType.toString());
    }

    try {
      final pages = document.pages;
      if (pages.isEmpty) {
        throw const PdfUnreadableException('no pages');
      }
      return PdfInspection(
        isPasswordProtected: false,
        pageCount: pages.length,
        firstPage: await _renderThumbnail(pages.first),
      );
    } finally {
      await document.dispose();
    }
  }

  Future<RawPixels?> _renderThumbnail(PdfPage page) async {
    if (page.width <= 0 || page.height <= 0) return null;
    final size = ThumbnailEncoder.fitSize(page.width * 4, page.height * 4);
    PdfImage? image;
    try {
      image = await page.render(
        fullWidth: size.width.toDouble(),
        fullHeight: size.height.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (image == null) return null;
      return RawPixels(
        // Copy: the native buffer is released by dispose().
        bytes: Uint8List.fromList(image.pixels),
        width: image.width,
        height: image.height,
        order: PixelOrder.bgra,
      );
    } on Exception {
      // A preview is optional; an unrenderable first page should not block
      // the import.
      return null;
    } finally {
      image?.dispose();
    }
  }
}
