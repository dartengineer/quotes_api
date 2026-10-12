/// Formats a byte count for display, e.g. `1.4 MB`.
String formatFileSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Formats progress in `[0, 1]` as a whole percentage, e.g. `42%`.
///
/// Progress that has started but rounds to zero shows as `1%`, and anything
/// short of complete never shows `100%`.
String formatPercent(double progress) {
  final clamped = progress.clamp(0.0, 1.0);
  var percent = (clamped * 100).round();
  if (clamped > 0 && percent == 0) percent = 1;
  if (clamped < 1 && percent == 100) percent = 99;
  return '$percent%';
}

/// Formats a reading duration, e.g. `45 min` or `2 h 05 min`.
String formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 1) return 'Less than a minute';
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = (minutes % 60).toString().padLeft(2, '0');
  return '$hours h $rest min';
}
