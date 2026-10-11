import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/app_log.dart';
import '../../../core/utils/load_status.dart';
import '../../settings/data/settings_repository.dart';
import '../data/library_repository.dart';
import '../domain/library_document.dart';
import '../domain/library_layout.dart';
import '../domain/library_query.dart';

class LibraryState extends Equatable {
  const LibraryState({
    this.status = LoadStatus.loading,
    this.documents = const [],
    this.query = const LibraryQuery(),
    this.layout = LibraryLayout.grid,
  });

  final LoadStatus status;
  final List<LibraryDocument> documents;
  final LibraryQuery query;
  final LibraryLayout layout;

  LibraryState copyWith({
    LoadStatus? status,
    List<LibraryDocument>? documents,
    LibraryQuery? query,
    LibraryLayout? layout,
  }) {
    return LibraryState(
      status: status ?? this.status,
      documents: documents ?? this.documents,
      query: query ?? this.query,
      layout: layout ?? this.layout,
    );
  }

  @override
  List<Object?> get props => [status, documents, query, layout];
}

/// Drives the library screen: watches the documents for the current query
/// and remembers the user's layout and sort choices.
class LibraryCubit extends Cubit<LibraryState> {
  LibraryCubit({required this._library, required this._settings})
    : super(const LibraryState()) {
    unawaited(_start());
  }

  final LibraryRepository _library;
  final SettingsRepository _settings;
  StreamSubscription<List<LibraryDocument>>? _subscription;

  /// Set once the user changes the view, so late-arriving stored preferences
  /// never overwrite a choice made in the meantime.
  bool _userChangedView = false;

  Future<void> _start() async {
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
    unawaited(_subscription?.cancel());
    _subscription = _library
        .watchDocuments(state.query)
        .listen(
          (documents) => emit(
            state.copyWith(status: LoadStatus.ready, documents: documents),
          ),
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

  Future<void> _persist(Future<void> Function() write) async {
    try {
      await write();
    } catch (error, stackTrace) {
      AppLog.error('Saving library preference failed', error, stackTrace);
    }
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    return super.close();
  }
}
