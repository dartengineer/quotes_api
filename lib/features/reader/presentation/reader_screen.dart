import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/reader_palette.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import 'reader_cubit.dart';
import 'reader_engines.dart';
import 'reader_view_controller.dart';
import 'widgets/bookmarks_sheet.dart';
import 'widgets/reader_settings_sheet.dart';
import 'widgets/search_sheet.dart';

/// The reading screen shared by all formats: toolbars, progress, bookmarks,
/// settings and search around a format-specific view.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _controller = ReaderViewController();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final cubit = context.read<ReaderCubit>();
    _applySystemUi(cubit.state.chromeVisible);
    // The process can be killed while in the background, so save then.
    _lifecycle = AppLifecycleListener(
      onPause: () => unawaited(cubit.onAppPaused()),
      onResume: cubit.onAppResumed,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _applySystemUi(bool chromeVisible) {
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        chromeVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ReaderCubit, ReaderState>(
      listenWhen: (a, b) => a.chromeVisible != b.chromeVisible,
      listener: (context, state) => _applySystemUi(state.chromeVisible),
      // Position, bookmark and toolbar changes are handled by the bars
      // themselves; rebuilding the page for them would be wasted work.
      buildWhen: (a, b) =>
          a.status != b.status ||
          a.document != b.document ||
          a.preferences != b.preferences,
      builder: (context, state) {
        return switch (state.status) {
          ReaderStatus.loading => const Scaffold(body: LoadingView()),
          ReaderStatus.ready => _ReaderLayout(
            state: state,
            controller: _controller,
          ),
          ReaderStatus.notFound => const _Problem(
            title: 'Not in your library',
            message: 'This document has been removed.',
          ),
          ReaderStatus.missingFile => const _Problem(
            title: 'File missing',
            message:
                'Lectern’s copy of this document can’t be found. Remove it '
                'from the library and import it again.',
          ),
          ReaderStatus.unsupported => _Problem(
            title: 'Can’t open this yet',
            message:
                'Reading ${state.document?.format.label ?? 'this format'} '
                'files is not available yet.',
          ),
          ReaderStatus.failure => const _Problem(
            title: 'Something went wrong',
            message: 'This document could not be opened.',
          ),
        };
      },
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: EmptyStateView(
        icon: Icons.menu_book_outlined,
        title: title,
        message: message,
      ),
    );
  }
}

class _ReaderLayout extends StatelessWidget {
  const _ReaderLayout({required this.state, required this.controller});

  final ReaderState state;
  final ReaderViewController controller;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ReaderCubit>();
    final document = state.document!;
    final palette = ReaderPalette.of(
      state.preferences.theme,
      Theme.of(context).brightness,
    );
    final view = ReaderEngines.buildView(
      document.format,
      ReaderViewConfig(
        filePath: state.filePath!,
        initialLocator: state.initialLocator,
        preferences: state.preferences,
        palette: palette,
        controller: controller,
        onPosition: cubit.onPosition,
        onTapCenter: cubit.toggleChrome,
      ),
    );

    return Theme(
      data: palette.isDark ? AppTheme.dark : AppTheme.light,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: palette.isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: palette.background,
          body: Stack(
            children: [
              Positioned.fill(child: SafeArea(child: view)),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: _TopBar(controller: controller),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _BottomBar(controller: controller),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slides a toolbar in and out with the reader chrome.
class _ChromeSlide extends StatelessWidget {
  const _ChromeSlide({required this.fromTop, required this.child});

  final bool fromTop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visible = context.select((ReaderCubit c) => c.state.chromeVisible);
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : Offset(0, fromTop ? -1 : 1),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }
}

enum _MenuAction { details }

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller});

  final ReaderViewController controller;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ReaderCubit>();
    final scheme = Theme.of(context).colorScheme;
    final document = context.select((ReaderCubit c) => c.state.document!);
    final bookmarked = context.select(
      (ReaderCubit c) => c.state.bookmarksHere.isNotEmpty,
    );

    return _ChromeSlide(
      fromTop: true,
      child: Material(
        color: scheme.surfaceContainer.withValues(alpha: 0.97),
        elevation: 2,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                const BackButton(),
                Expanded(
                  child: Text(
                    document.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Search in document',
                  icon: const Icon(Icons.search),
                  onPressed: () => showReaderSearch(context, controller),
                ),
                IconButton(
                  tooltip: bookmarked ? 'Remove bookmark' : 'Add bookmark',
                  isSelected: bookmarked,
                  icon: const Icon(Icons.bookmark_border),
                  selectedIcon: const Icon(Icons.bookmark),
                  onPressed: () {
                    final locator = cubit.state.position?.locator;
                    unawaited(
                      cubit.toggleBookmark(
                        excerpt: locator == null
                            ? null
                            : controller.excerptAt(locator),
                      ),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Bookmarks',
                  icon: const Icon(Icons.bookmarks_outlined),
                  onPressed: () => showBookmarksSheet(context, controller),
                ),
                IconButton(
                  tooltip: 'Reading settings',
                  icon: const Icon(Icons.text_fields),
                  onPressed: () => showReaderSettings(context),
                ),
                PopupMenuButton<_MenuAction>(
                  tooltip: 'More options',
                  onSelected: (action) => switch (action) {
                    _MenuAction.details => unawaited(
                      context.push(Routes.document(document.id)),
                    ),
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: _MenuAction.details,
                      child: Text('Document details'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatefulWidget {
  const _BottomBar({required this.controller});

  final ReaderViewController controller;

  @override
  State<_BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends State<_BottomBar> {
  /// The slider value while it is being dragged.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final progress = context.select(
      (ReaderCubit c) => c.state.position?.progress ?? 0,
    );
    final value = _dragValue ?? progress;
    final scheme = Theme.of(context).colorScheme;
    return _ChromeSlide(
      fromTop: false,
      child: Material(
        color: scheme.surfaceContainer.withValues(alpha: 0.97),
        elevation: 2,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.sm,
              Spacing.xs,
              Spacing.lg,
              Spacing.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Slider(
                    value: value.clamp(0.0, 1.0),
                    semanticFormatterCallback: (v) =>
                        'Reading position ${formatPercent(v)}',
                    label: formatPercent(value),
                    onChanged: (v) => setState(() => _dragValue = v),
                    onChangeEnd: (v) {
                      setState(() => _dragValue = null);
                      widget.controller.goToProgress(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    formatPercent(value),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
