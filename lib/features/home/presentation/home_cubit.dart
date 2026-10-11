import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/app_log.dart';
import '../../../core/utils/load_status.dart';
import '../../library/data/library_repository.dart';
import '../../library/domain/library_document.dart';

class HomeState extends Equatable {
  const HomeState({
    this.status = LoadStatus.loading,
    this.totalCount = 0,
    this.continueReading = const [],
    this.recentlyOpened = const [],
    this.recentlyAdded = const [],
  });

  final LoadStatus status;
  final int totalCount;
  final List<LibraryDocument> continueReading;
  final List<LibraryDocument> recentlyOpened;
  final List<LibraryDocument> recentlyAdded;

  bool get isLibraryEmpty => totalCount == 0;

  HomeState copyWith({
    LoadStatus? status,
    int? totalCount,
    List<LibraryDocument>? continueReading,
    List<LibraryDocument>? recentlyOpened,
    List<LibraryDocument>? recentlyAdded,
  }) {
    return HomeState(
      status: status ?? this.status,
      totalCount: totalCount ?? this.totalCount,
      continueReading: continueReading ?? this.continueReading,
      recentlyOpened: recentlyOpened ?? this.recentlyOpened,
      recentlyAdded: recentlyAdded ?? this.recentlyAdded,
    );
  }

  @override
  List<Object?> get props => [
    status,
    totalCount,
    continueReading,
    recentlyOpened,
    recentlyAdded,
  ];
}

enum _Section { count, continueReading, recentlyOpened, recentlyAdded }

/// Feeds the home screen from several small, indexed library queries.
class HomeCubit extends Cubit<HomeState> {
  HomeCubit(this._library, {this.sectionSize = 10}) : super(const HomeState()) {
    _subscribe();
  }

  final LibraryRepository _library;
  final int sectionSize;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Set<_Section> _received = {};

  void _subscribe() {
    _cancelAll();
    _received.clear();
    _listen(
      _Section.count,
      _library.watchCount(),
      (state, int value) => state.copyWith(totalCount: value),
    );
    _listen(
      _Section.continueReading,
      _library.watchContinueReading(limit: sectionSize),
      (state, List<LibraryDocument> value) =>
          state.copyWith(continueReading: value),
    );
    _listen(
      _Section.recentlyOpened,
      _library.watchRecentlyOpened(limit: sectionSize),
      (state, List<LibraryDocument> value) =>
          state.copyWith(recentlyOpened: value),
    );
    _listen(
      _Section.recentlyAdded,
      _library.watchRecentlyAdded(limit: sectionSize),
      (state, List<LibraryDocument> value) =>
          state.copyWith(recentlyAdded: value),
    );
  }

  void _listen<T>(
    _Section section,
    Stream<T> stream,
    HomeState Function(HomeState state, T value) apply,
  ) {
    _subscriptions.add(
      stream.listen(
        (value) {
          _received.add(section);
          // Stay in "loading" until every section has data, so the screen
          // does not flash a half-filled layout.
          final ready = _received.length == _Section.values.length;
          emit(
            apply(
              state,
              value,
            ).copyWith(status: ready ? LoadStatus.ready : state.status),
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          AppLog.error('Watching home section failed', error, stackTrace);
          emit(state.copyWith(status: LoadStatus.failure));
        },
      ),
    );
  }

  void retry() {
    emit(state.copyWith(status: LoadStatus.loading));
    _subscribe();
  }

  void _cancelAll() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  @override
  Future<void> close() async {
    await Future.wait(_subscriptions.map((s) => s.cancel()));
    _subscriptions.clear();
    return super.close();
  }
}
