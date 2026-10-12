import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/app_log.dart';
import '../../../data/files/library_storage.dart';
import '../../library/data/library_repository.dart';
import '../../library/domain/library_document.dart';
import '../../settings/data/settings_repository.dart';
import '../data/annotation_repository.dart';
import '../data/bookmark_repository.dart';
import '../data/reading_progress_repository.dart';
import '../data/reading_session_tracker.dart';
import '../domain/annotation.dart';
import '../domain/bookmark.dart';
import '../domain/locator.dart';
import '../domain/reader_preferences.dart';
import 'reader_engines.dart';

enum ReaderStatus {
  loading,
  ready,
  notFound,
  missingFile,
  unsupported,
  failure,
}

class ReaderState extends Equatable {
  const ReaderState({
    this.status = ReaderStatus.loading,
    this.document,
    this.filePath,
    this.initialLocator,
    this.position,
    this.bookmarks = const [],
    this.annotations = const [],
    this.preferences = const ReaderPreferences(),
    this.chromeVisible = false,
  });

  final ReaderStatus status;
  final LibraryDocument? document;

  /// Absolute path of the library copy.
  final String? filePath;

  /// Where to open the document (the last saved position).
  final Locator? initialLocator;

  /// The latest position reported by the view.
  final ReaderPosition? position;
  final List<Bookmark> bookmarks;

  /// Highlights and notes, in reading order.
  final List<Annotation> annotations;
  final ReaderPreferences preferences;

  /// Whether the toolbars are shown. Documents open full-screen so the
  /// restored position is not covered; tapping the page shows them.
  final bool chromeVisible;

  /// Bookmarks within the visible part of the document.
  List<Bookmark> get bookmarksHere {
    final current = position;
    if (current == null) return const [];
    return bookmarks.where((b) => current.shows(b.locator)).toList();
  }

  ReaderState copyWith({
    ReaderStatus? status,
    LibraryDocument? document,
    String? filePath,
    Locator? initialLocator,
    ReaderPosition? position,
    List<Bookmark>? bookmarks,
    List<Annotation>? annotations,
    ReaderPreferences? preferences,
    bool? chromeVisible,
  }) {
    return ReaderState(
      status: status ?? this.status,
      document: document ?? this.document,
      filePath: filePath ?? this.filePath,
      initialLocator: initialLocator ?? this.initialLocator,
      position: position ?? this.position,
      bookmarks: bookmarks ?? this.bookmarks,
      annotations: annotations ?? this.annotations,
      preferences: preferences ?? this.preferences,
      chromeVisible: chromeVisible ?? this.chromeVisible,
    );
  }

  @override
  List<Object?> get props => [
    status,
    document,
    filePath,
    initialLocator,
    position,
    bookmarks,
    annotations,
    preferences,
    chromeVisible,
  ];
}

/// Format-independent reader state: opening a document, restoring and
/// saving the position, reading sessions, bookmarks and reader settings.
class ReaderCubit extends Cubit<ReaderState> {
  ReaderCubit({
    required this.documentId,
    required this._library,
    required this._progress,
    required this._bookmarks,
    required this._annotations,
    required this._settings,
    required this._storage,
    this._clock,
  }) : super(const ReaderState()) {
    unawaited(_open());
  }

  final int documentId;
  final LibraryRepository _library;
  final ReadingProgressRepository _progress;
  final BookmarkRepository _bookmarks;
  final AnnotationRepository _annotations;
  final SettingsRepository _settings;
  final LibraryStorage _storage;
  final DateTime Function()? _clock;

  ReadingSessionTracker? _tracker;
  StreamSubscription<List<Bookmark>>? _bookmarkSubscription;
  StreamSubscription<List<Annotation>>? _annotationSubscription;

  Future<void> _open() async {
    try {
      final document = await _library.findById(documentId);
      if (isClosed) return;
      if (document == null) {
        emit(state.copyWith(status: ReaderStatus.notFound));
        return;
      }
      if (!ReaderEngines.supports(document.format)) {
        emit(
          state.copyWith(status: ReaderStatus.unsupported, document: document),
        );
        return;
      }
      final file = _storage.resolve(document.filePath);
      if (!await file.exists()) {
        emit(
          state.copyWith(status: ReaderStatus.missingFile, document: document),
        );
        return;
      }

      final (initialLocator, preferences) = await (
        _progress.loadPosition(documentId),
        _settings.load().then((p) => p.readerPreferences),
      ).wait;
      if (isClosed) return;
      await _library.markOpened(documentId);
      if (isClosed) return;

      _tracker = ReadingSessionTracker(
        store: _progress,
        documentId: documentId,
        initialProgress: document.progress,
        clock: _clock,
      )..resume();
      _bookmarkSubscription = _bookmarks
          .watchBookmarks(documentId)
          .listen(
            (bookmarks) => emit(state.copyWith(bookmarks: bookmarks)),
            onError: (Object error, StackTrace stackTrace) =>
                AppLog.error('Watching bookmarks failed', error, stackTrace),
          );
      _annotationSubscription = _annotations
          .watchAnnotations(documentId)
          .listen(
            (annotations) => emit(state.copyWith(annotations: annotations)),
            onError: (Object error, StackTrace stackTrace) =>
                AppLog.error('Watching annotations failed', error, stackTrace),
          );

      emit(
        state.copyWith(
          status: ReaderStatus.ready,
          document: document,
          filePath: file.path,
          initialLocator: initialLocator,
          preferences: preferences,
        ),
      );
    } catch (error, stackTrace) {
      AppLog.error('Opening a document failed', error, stackTrace);
      if (!isClosed) emit(state.copyWith(status: ReaderStatus.failure));
    }
  }

  /// Called by the format view whenever the visible position changes.
  void onPosition(ReaderPosition position) {
    if (isClosed || position == state.position) return;
    emit(state.copyWith(position: position));
    _tracker?.update(position);
    _recordPageCount(position.pageCount);
  }

  bool _pageCountRecorded = false;

  /// A PDF imported without its password has no page count until opened.
  void _recordPageCount(int? pageCount) {
    final document = state.document;
    if (_pageCountRecorded ||
        pageCount == null ||
        document == null ||
        document.pageCount != null) {
      return;
    }
    _pageCountRecorded = true;
    unawaited(
      _library.recordPageCount(document.id, pageCount).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        AppLog.error('Recording the page count failed', error, stackTrace);
      }),
    );
  }

  void toggleChrome() =>
      emit(state.copyWith(chromeVisible: !state.chromeVisible));

  void setChromeVisible(bool visible) {
    if (visible != state.chromeVisible) {
      emit(state.copyWith(chromeVisible: visible));
    }
  }

  /// Adds a bookmark at the current position, or removes the bookmarks
  /// shown on screen if there are any.
  Future<void> toggleBookmark({String? excerpt}) async {
    final position = state.position;
    if (position == null) return;
    final here = state.bookmarksHere;
    if (here.isNotEmpty) {
      for (final bookmark in here) {
        await _bookmarks.deleteBookmark(bookmark.id);
      }
      return;
    }
    await _bookmarks.addBookmark(
      documentId: documentId,
      locator: position.locator,
      progress: position.progress,
      excerpt: excerpt,
    );
  }

  Future<void> deleteBookmark(int id) => _bookmarks.deleteBookmark(id);

  /// Saves a highlight (with an optional note); returns its id.
  Future<int> addAnnotation(
    AnnotationDraft draft, {
    HighlightColor color = HighlightColor.yellow,
    String? note,
  }) => _annotations.addAnnotation(
    documentId: documentId,
    draft: draft,
    color: color,
    note: note,
  );

  Future<void> setAnnotationNote(int id, String? note) =>
      _annotations.updateNote(id, note);

  Future<void> setAnnotationColor(int id, HighlightColor color) =>
      _annotations.updateColor(id, color);

  Future<void> deleteAnnotation(int id) => _annotations.deleteAnnotation(id);

  /// Applies settings immediately without saving (while a slider moves).
  void previewPreferences(ReaderPreferences preferences) {
    emit(state.copyWith(preferences: preferences));
  }

  /// Applies and saves settings.
  Future<void> savePreferences(ReaderPreferences preferences) async {
    emit(state.copyWith(preferences: preferences));
    try {
      await _settings.setReaderPreferences(preferences);
    } catch (error, stackTrace) {
      AppLog.error('Saving reader settings failed', error, stackTrace);
    }
  }

  /// The app went to the background: save everything now, as the process
  /// may be killed without further notice.
  Future<void> onAppPaused() async => _tracker?.pause();

  void onAppResumed() => _tracker?.resume();

  @override
  Future<void> close() async {
    // Start closing the tracker before any await so its pending timer is
    // cancelled synchronously.
    final tracker = _tracker?.close();
    await _bookmarkSubscription?.cancel();
    await _annotationSubscription?.cancel();
    await tracker;
    return super.close();
  }
}
