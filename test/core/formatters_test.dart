import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/formatters.dart';

void main() {
  group('formatFileSize', () {
    test('uses binary units with sensible precision', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(1023), '1023 B');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatFileSize(250 * 1024 * 1024), '250 MB');
      expect(formatFileSize(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });

  group('formatPercent', () {
    test('rounds to whole percentages', () {
      expect(formatPercent(0), '0%');
      expect(formatPercent(0.424), '42%');
      expect(formatPercent(1), '100%');
    });

    test('never shows started progress as 0% or unfinished as 100%', () {
      expect(formatPercent(0.001), '1%');
      expect(formatPercent(0.999), '99%');
    });

    test('clamps out-of-range values', () {
      expect(formatPercent(-1), '0%');
      expect(formatPercent(2), '100%');
    });
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 30)), 'Less than a minute');
    expect(formatDuration(const Duration(minutes: 45)), '45 min');
    expect(formatDuration(const Duration(hours: 2, minutes: 5)), '2 h 05 min');
  });
}
