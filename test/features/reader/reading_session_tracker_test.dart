import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/features/reader/data/reading_progress_repository.dart';
import 'package:lectern/features/reader/data/reading_session_tracker.dart';
import 'package:lectern/features/reader/domain/locator.dart';

class _RecordingStore implements ProgressStore {
  final positions = <Locator>[];
  final progress = <double>[];
  final sessions = <(Duration, double, double)>[];
  bool failNext = false;

  @override
  Future<void> savePosition(int documentId, Locator locator) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    positions.add(locator);
  }

  @override
  Future<void> saveProgress(int documentId, double value) async {
    progress.add(value);
  }

  @override
  Future<void> recordSession({
    required int documentId,
    required DateTime startedAt,
    required DateTime endedAt,
    required double startProgress,
    required double endProgress,
  }) async {
    sessions.add((endedAt.difference(startedAt), startProgress, endProgress));
  }
}

ReaderPosition at(int offset, [double? progress]) => ReaderPosition(
  locator: TextLocator(offset),
  progress: progress ?? offset / 1000,
);

void main() {
  late _RecordingStore store;

  setUp(() => store = _RecordingStore());

  ReadingSessionTracker tracker(FakeAsync async, {double initial = 0}) =>
      ReadingSessionTracker(
        store: store,
        documentId: 1,
        initialProgress: initial,
        clock: () => DateTime.utc(2026).add(async.elapsed),
      );

  test('throttles position writes and always writes the latest', () {
    fakeAsync((async) {
      final t = tracker(async);
      for (var i = 1; i <= 50; i++) {
        t.update(at(i * 10));
        async.elapse(const Duration(milliseconds: 100));
      }
      // 5 s of continuous scrolling with a 2 s interval.
      expect(store.positions.length, inInclusiveRange(2, 3));
      async.elapse(const Duration(seconds: 3));
      expect(store.positions.last, const TextLocator(500));
      expect(store.progress, isEmpty, reason: 'lists are not touched yet');
    });
  });

  test('flush writes position and overall progress immediately', () {
    fakeAsync((async) {
      final t = tracker(async);
      t.update(at(300));
      unawaited(t.flush());
      async.flushMicrotasks();
      expect(store.positions, [const TextLocator(300)]);
      expect(store.progress, [0.3]);

      // Nothing new: no duplicate writes.
      unawaited(t.flush());
      async.elapse(const Duration(seconds: 5));
      expect(store.positions, hasLength(1));
      expect(store.progress, hasLength(1));
    });
  });

  test('records sessions between resume and pause, ignoring short ones', () {
    fakeAsync((async) {
      final t = tracker(async, initial: 0.2)..resume();
      async.elapse(const Duration(seconds: 2));
      unawaited(t.pause());
      async.flushMicrotasks();
      expect(store.sessions, isEmpty, reason: 'too short to count');

      t.resume();
      async.elapse(const Duration(minutes: 3));
      t.update(at(500, 0.5));
      unawaited(t.pause());
      async.flushMicrotasks();
      expect(store.sessions, [(const Duration(minutes: 3), 0.2, 0.5)]);
      expect(store.progress.last, 0.5);
    });
  });

  test('close flushes and ignores later updates', () {
    fakeAsync((async) {
      final t = tracker(async)..resume();
      t.update(at(100));
      unawaited(t.close());
      async.flushMicrotasks();
      t.update(at(200));
      async.elapse(const Duration(seconds: 5));
      expect(store.positions, [const TextLocator(100)]);
    });
  });

  test('a failed write does not stop later writes', () {
    fakeAsync((async) {
      final t = tracker(async);
      store.failNext = true;
      t.update(at(100));
      async.elapse(const Duration(seconds: 3));
      t.update(at(200));
      async.elapse(const Duration(seconds: 3));
      expect(store.positions, [const TextLocator(200)]);
    });
  });
}
