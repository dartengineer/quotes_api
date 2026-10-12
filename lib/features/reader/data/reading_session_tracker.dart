import 'dart:async';

import '../../../core/utils/app_log.dart';
import '../domain/locator.dart';
import 'reading_progress_repository.dart';

/// Records reading progress for one open document without writing to the
/// database on every scroll event:
///
/// * Positions are throttled: at most one write per [interval], and the
///   latest position is always written shortly after movement stops.
/// * The document's overall progress (shown in lists) is written only on
///   [flush], so library and home queries are not re-run while reading.
/// * A reading session runs from [resume] to [pause]; sessions shorter than
///   [minimumSession] (an accidental open) are not recorded.
///
/// Call [pause] when the app goes to the background and [close] when the
/// reader closes, so nothing is lost if the process is killed afterwards.
class ReadingSessionTracker {
  ReadingSessionTracker({
    required this._store,
    required this.documentId,
    required double initialProgress,
    DateTime Function()? clock,
    this.interval = const Duration(seconds: 2),
    this.minimumSession = const Duration(seconds: 5),
  }) : _clock = clock ?? DateTime.now,
       _savedProgress = initialProgress,
       _latestProgress = initialProgress;

  final ProgressStore _store;
  final int documentId;
  final DateTime Function() _clock;
  final Duration interval;
  final Duration minimumSession;

  Timer? _timer;
  Locator? _pendingLocator;
  double _latestProgress;
  double _savedProgress;
  DateTime? _sessionStart;
  double _sessionStartProgress = 0;
  bool _closed = false;

  /// Serialises writes so they reach the database in order.
  Future<void> _writes = Future.value();

  double get latestProgress => _latestProgress;

  /// Starts (or restarts after [pause]) a reading session.
  void resume() {
    if (_closed || _sessionStart != null) return;
    _sessionStart = _clock();
    _sessionStartProgress = _latestProgress;
  }

  /// Records the current position; it is written within [interval].
  void update(ReaderPosition position) {
    if (_closed) return;
    _pendingLocator = position.locator;
    _latestProgress = position.progress.clamp(0.0, 1.0);
    _timer ??= Timer(interval, () {
      _timer = null;
      unawaited(_writePosition());
    });
  }

  /// Writes the pending position and the overall progress now.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final pending = _writePosition();
    final progress = _latestProgress;
    if (progress == _savedProgress) return pending;
    _savedProgress = progress;
    return _enqueue(() => _store.saveProgress(documentId, progress));
  }

  /// Flushes and ends the current session (app backgrounded).
  Future<void> pause() async {
    final flushed = flush();
    final start = _sessionStart;
    _sessionStart = null;
    if (start != null) {
      final end = _clock();
      if (end.difference(start) >= minimumSession) {
        final startProgress = _sessionStartProgress;
        final endProgress = _latestProgress;
        await _enqueue(
          () => _store.recordSession(
            documentId: documentId,
            startedAt: start,
            endedAt: end,
            startProgress: startProgress,
            endProgress: endProgress,
          ),
        );
      }
    }
    await flushed;
  }

  /// Final flush; the tracker ignores further updates.
  Future<void> close() async {
    if (_closed) return;
    await pause();
    _closed = true;
  }

  Future<void> _writePosition() {
    final locator = _pendingLocator;
    if (locator == null) return _writes;
    _pendingLocator = null;
    return _enqueue(() => _store.savePosition(documentId, locator));
  }

  Future<void> _enqueue(Future<void> Function() write) {
    _writes = _writes.then((_) async {
      try {
        await write();
      } catch (error, stackTrace) {
        // A failed save must never crash reading; the next write retries
        // with the latest position.
        AppLog.error('Saving reading progress failed', error, stackTrace);
      }
    });
    return _writes;
  }
}
