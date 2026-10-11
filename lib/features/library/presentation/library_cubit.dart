import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/app_log.dart';
import '../../../core/utils/load_status.dart';
import '../../collections/data/collection_repository.dart';
import '../../collections/domain/library_collection.dart';
import '../../settings/data/settings_repository.dart';
import '../data/library_manager.dart';
import '../data/library_repository.dart';
import '../domain/library_document.dart';
import '../domain/library_filter.dart';
import '../domain/library_layout.dart';
import '../domain/library_query.dart';
import '../domain/reading_status.dart';

class LibraryState extends Equatable {
  const LibraryState({
    this.status = LoadStatus.loading,
    this.documents = const [],
    this.query = const LibraryQuery(),
    this.layout = LibraryLayout.grid,
    this.selectedIds = const {},
    this.collection,
    this.collectionDeleted = false,
  });

  final LoadStatus status;
  final List<LibraryDocument> documents;
  final LibraryQuery query;
  final LibraryLayout layout;

  /// Documents selected for a bulk action; empty when not selecting.
  final Set<int> selectedIds;

  /// The collection being shown, when this is a collection view.
  final LibraryCollection? collection;

  /// The collection shown here was deleted (e.g. from another screen).
  final bool collectionDeleted;

  bool get isSelecting => selectedIds.isNotEmpty;
  LibraryFilter get filter => LibraryFilter.of(query);

  /// Whether search or a filter is narrowing the list.
  bool get isNarrowed =>
      query.search.trim().isNotEmpty || filter != LibraryFilter.all;

  List<LibraryDocument> get selectedDocuments =>
      documents.where((d) => selectedIds.contains(d.id)).toList();

  LibraryState copyWith({
    LoadStatus? status,
    List<LibraryDocument>? documents,
    LibraryQuery? query,
    LibraryLayout? layout,
    Set<int>? selectedIds,
    LibraryCollection? Function()? collection,
    bool? collectionDeleted,
  }) {
    return LibraryState(
      status: status ?? this.status,
      documents: documents ?? this.documents,
      query: query ?? this.query,
      layout: layout ?? this.layout,
      selectedIds: selectedIds ?? this.selectedIds,
      collection: collection != null ? collection() : this.collection,
      collectionDeleted: collectionDeleted ?? this.collectionDeleted,
    );
  }

  @override
  List<Object?> get props => [
    status,
    documents,
    query,
    layout,
    selectedIds,
    collection,
    collectionDeleted,
  ];
}

/// Drives the library screen (or one collection's documents): the document
/// query, the user's layout and sort choices, and multi-selection.
class LibraryCubit extends Cubit<LibraryState> {
  LibraryCubit({
    required this._library,
    required this._settings,
    required this._manager,
    required this._collections,
    int? collectionId,
    this.searchDebounce = const Duration(milliseconds: 250),
  }) : super(LibraryState(query: LibraryQuery(collectionId: collectionId))) {
    unawaited(_start());
  }

  final LibraryRepository _library;
  final SettingsRepository _settings;
  final LibraryManager _manager;
  final CollectionRepository _collections;
  final Duration searchDebounce;

  StreamSubscription<List<LibraryDocument>>? _documentsSubscription;
  StreamSubscription<LibraryCollection?>? _collectionSubscription;
  Timer? _searchTimer;

  /// Set once the user changes the view, so late-arriving stored preferences
  /// never overwrite a choice made in the meantime.
  bool _userChangedView = false;

  int? get collectionId => state.query.collectionId;

  Future<void> _start() async {
    if (collectionId case final id?) {
      _collectionSubscription = _collections
          .watchCollection(id)
          .listen(
            (collection) => emit(
              state.copyWith(
                collection: () => collection,
                collectionDeleted: collection == null,
              ),
            ),
            onError: (Object error, StackTrace stackTrace) =>
                AppLog.error('Watching collection failed', error, stackTrace),
          );
    }
    try {
      final preferences = await _settings.load();
      if (isClosed) return;
      if (!_userChangedView) {
        emit(
          state.copyWith(
            layout: preferences.libraryLayout,
            query: state.query.copyWith(sort: preferences.librarySort),
          ),
        );
      }
    } catch (error, stackTrace) {
      // Defaults are fine; the library itself must still load.
      AppLog.error('Loading library preferences failed', error, stackTrace);
    }
    if (isClosed) return;
    _subscribe();
  }

  void _subscribe() {
    // Cancelling the previous query's stream guarantees a slow, obsolete
    // result can never overwrite the current one.
    unawaited(_documentsSubscription?.cancel());
    _documentsSubscription = _library
        .watchDocuments(state.query)
        .listen(
          (documents) {
            // Drop selections that are no longer visible (removed or
            // filtered out), so bulk actions only affect what is shown.
            final visible = {for (final d in documents) d.id};
            emit(
              state.copyWith(
                status: LoadStatus.ready,
                documents: documents,
                selectedIds: state.selectedIds.intersection(visible),
              ),
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLog.error('Watching library failed', error, stackTrace);
            emit(state.copyWith(status: LoadStatus.failure));
          },
        );
  }

  void retry() {
    emit(state.copyWith(status: LoadStatus.loading));
    _subscribe();
  }

  // --- View ---------------------------------------------------------------

  Future<void> setSort(LibrarySort sort) async {
    _userChangedView = true;
    if (sort == state.query.sort) return;
    emit(state.copyWith(query: state.query.copyWith(sort: sort)));
    _subscribe();
    await _persist(() => _settings.setLibrarySort(sort));
  }

  Future<void> setLayout(LibraryLayout layout) async {
    _userChangedView = true;
    if (layout == state.layout) return;
    emit(state.copyWith(layout: layout));
    await _persist(() => _settings.setLibraryLayout(layout));
  }

  /// Updates the search text. The query runs once typing pauses; clearing
  /// the search applies immediately.
  void setSearch(String text) {
    if (text == state.query.search) return;
    emit(state.copyWith(query: state.query.copyWith(search: text)));
    _searchTimer?.cancel();
    if (text.trim().isEmpty) {
      _subscribe();
    } else {
      _searchTimer = Timer(searchDebounce, _subscribe);
    }
  }

  void setFilter(LibraryFilter filter) {
    if (filter == state.filter) return;
    emit(state.copyWith(query: filter.applyTo(state.query)));
    _subscribe();
  }

  /// Clears search and filters, keeping the sort order.
  void clearNarrowing() {
    _searchTimer?.cancel();
    emit(
      state.copyWith(
        query: LibraryFilter.all.applyTo(state.query.copyWith(search: '')),
      ),
    );
    _subscribe();
  }

  // --- Selection ------------------------------------------------------------

  void toggleSelected(int id) {
    final selected = {...state.selectedIds};
    if (!selected.remove(id)) selected.add(id);
    emit(state.copyWith(selectedIds: selected));
  }

  void selectAll() {
    emit(state.copyWith(selectedIds: {for (final d in state.documents) d.id}));
  }

  void clearSelection() => emit(state.copyWith(selectedIds: const {}));

  /// Favourites the selection, or un-favourites it if all are favourites.
  Future<void> toggleFavoriteForSelection() async {
    final selected = state.selectedDocuments;
    if (selected.isEmpty) return;
    final favorite = !selected.every((d) => d.isFavorite);
    await _library.setFavorite(state.selectedIds, favorite: favorite);
  }

  Future<void> setStatusForSelection(ReadingStatus status) async {
    if (!state.isSelecting) return;
    await _library.setStatus(state.selectedIds, status);
    clearSelection();
  }

  Future<void> addSelectionToCollection(int collectionId) async {
    if (!state.isSelecting) return;
    await _collections.addDocuments(collectionId, state.selectedIds);
    clearSelection();
  }

  /// In a collection view: takes the selection out of the collection only.
  Future<void> removeSelectionFromCollection() async {
    final id = collectionId;
    if (id == null || !state.isSelecting) return;
    await _collections.removeDocuments(id, state.selectedIds);
    clearSelection();
  }

  /// Removes the selection from the library. Returns how many were removed.
  Future<int> removeSelectionFromLibrary() async {
    if (!state.isSelecting) return 0;
    final removed = await _manager.removeDocuments(state.selectedIds);
    clearSelection();
    return removed;
  }

  // --- Collection view -------------------------------------------------

  /// Renames the collection shown. Returns an error message, or null.
  Future<String?> renameCollection(String name) async {
    final id = collectionId;
    if (id == null) return null;
    try {
      await _collections.renameCollection(id, name);
      return null;
    } on InvalidCollectionNameException catch (e) {
      return e.message;
    }
  }

  /// Deletes the collection shown; its documents stay in the library.
  Future<void> deleteCollection() async {
    final id = collectionId;
    if (id != null) await _collections.deleteCollection(id);
  }

  Future<void> _persist(Future<void> Function() write) async {
    try {
      await write();
    } catch (error, stackTrace) {
      AppLog.error('Saving library preference failed', error, stackTrace);
    }
  }

  @override
  Future<void> close() async {
    _searchTimer?.cancel();
    await _documentsSubscription?.cancel();
    await _collectionSubscription?.cancel();
    return super.close();
  }
}
