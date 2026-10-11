import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../data/files/library_storage.dart';
import '../../domain/document_format.dart';
import '../../domain/library_document.dart';

/// A document's cover: its thumbnail if one was generated at import,
/// otherwise a tinted "book" showing the title.
///
/// Covers are decorative; titles are announced by the surrounding tile, so
/// they are excluded from semantics.
class DocumentCover extends StatelessWidget {
  const DocumentCover({super.key, required this.document});

  final LibraryDocument document;

  @override
  Widget build(BuildContext context) {
    final coverPath = document.coverPath;
    if (coverPath == null) return _GeneratedCover(document: document);
    final file = context.read<LibraryStorage>().resolve(coverPath);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: Radii.smAll,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Decode at display size, never at the thumbnail's full size.
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final width = constraints.maxWidth;
            final cacheWidth = width.isFinite && width > 0
                ? (width * dpr).round()
                : null;
            return Image.file(
              file,
              cacheWidth: cacheWidth,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  _GeneratedCover(document: document),
            );
          },
        ),
      ),
    );
  }
}

/// The tint is derived from the content hash, so a document keeps the same
/// colour across launches.
class _GeneratedCover extends StatelessWidget {
  const _GeneratedCover({required this.document});

  final LibraryDocument document;

  @override
  Widget build(BuildContext context) {
    final tint = _tintFor(document.contentHash);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: Radii.smAll,
        child: ColoredBox(
          color: tint,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final titleSize = (width * 0.11).clamp(9.0, 22.0);
              final pad = (width * 0.1).clamp(6.0, 16.0);
              // Cover art is a fixed design; it must not reflow with the
              // system text size (the tile's real title text does).
              return MediaQuery.withNoTextScaling(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Book spine shading on the left edge.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: (width * 0.06).clamp(3.0, 10.0),
                        color: Colors.black.withValues(alpha: 0.18),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad * 1.3, pad, pad, pad),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FormatBadge(
                            format: document.format,
                            size: titleSize,
                          ),
                          SizedBox(height: pad),
                          Expanded(
                            child: Text(
                              document.title,
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: titleSize,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                            ),
                          ),
                          if (document.author case final author?)
                            Text(
                              author,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: titleSize * 0.75,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static Color _tintFor(String hash) {
    final tints = BrandColors.coverTints;
    final seed = hash.isEmpty
        ? 0
        : hash.codeUnits.fold<int>(0, (a, b) => a + b);
    return tints[seed % tints.length];
  }
}

class _FormatBadge extends StatelessWidget {
  const _FormatBadge({required this.format, required this.size});

  final DocumentFormat format;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: Radii.smAll,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: size * 0.4,
          vertical: size * 0.1,
        ),
        child: Text(
          format.label,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.65,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}
