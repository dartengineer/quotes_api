import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/app_log.dart';
import '../../../../core/utils/formatters.dart';
import '../../domain/search_hit.dart';
import '../reader_view_controller.dart';

/// Search inside the open document; choosing a result jumps to it.
Future<void> showReaderSearch(
  BuildContext context,
  ReaderViewController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _SearchSheet(controller: controller),
  );
}

class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.controller});

  final ReaderViewController controller;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _field = TextEditingController();
  List<SearchHit>? _hits;
  bool _searching = false;
  bool _failed = false;

  /// Identifies the latest search so a slow, obsolete one cannot overwrite
  /// newer results.
  int _generation = 0;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _field.text.trim();
    if (query.isEmpty) return;
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _failed = false;
    });
    try {
      final hits = await widget.controller.search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    } catch (error, stackTrace) {
      AppLog.error('Searching the document failed', error, stackTrace);
      if (!mounted || generation != _generation) return;
      setState(() {
        _searching = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hits = _hits;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: TextField(
                controller: _field,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search in this document',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: 'Search',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _search,
                  ),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(Spacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_failed)
              const _Message('Search failed. Please try again.')
            else if (hits != null && hits.isEmpty)
              const _Message('No matches.')
            else if (hits != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    hits.length == 1 ? '1 match' : '${hits.length} matches',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: hits.length,
                  itemBuilder: (context, index) {
                    final hit = hits[index];
                    return ListTile(
                      title: Text.rich(
                        _highlighted(hit, theme),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(formatPercent(hit.progress)),
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.controller.goTo(
                          hit.locator,
                          highlightLength: hit.matchLength,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: Spacing.md),
          ],
        ),
      ),
    );
  }

  TextSpan _highlighted(SearchHit hit, ThemeData theme) {
    final start = hit.snippetMatchStart.clamp(0, hit.snippet.length);
    final end = (start + hit.matchLength).clamp(start, hit.snippet.length);
    return TextSpan(
      children: [
        TextSpan(text: hit.snippet.substring(0, start)),
        TextSpan(
          text: hit.snippet.substring(start, end),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            backgroundColor: theme.colorScheme.secondaryContainer,
          ),
        ),
        TextSpan(text: hit.snippet.substring(end)),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Text(text, textAlign: TextAlign.center),
    );
  }
}
