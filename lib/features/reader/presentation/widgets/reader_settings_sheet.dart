import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/reader_palette.dart';
import '../../../../core/theme/tokens.dart';
import '../../domain/reader_preferences.dart';
import '../reader_cubit.dart';

Future<void> showReaderSettings(BuildContext context) {
  final cubit = context.read<ReaderCubit>();
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    // Keep the page visible behind the sheet to preview changes.
    barrierColor: Colors.transparent,
    builder: (_) =>
        BlocProvider.value(value: cubit, child: const _ReaderSettingsSheet()),
  );
}

class _ReaderSettingsSheet extends StatelessWidget {
  const _ReaderSettingsSheet();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ReaderCubit>();
    final prefs = context.select((ReaderCubit c) => c.state.preferences);
    final theme = Theme.of(context);

    void save(ReaderPreferences value) =>
        unawaited(cubit.savePreferences(value));

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Spacing.xl, 0, Spacing.xl, Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reading settings', style: theme.textTheme.titleLarge),
          const SizedBox(height: Spacing.lg),
          _ThemeChoice(
            selected: prefs.theme,
            onSelected: (t) => save(prefs.copyWith(theme: t)),
          ),
          const SizedBox(height: Spacing.lg),
          SegmentedButton<ReaderFont>(
            showSelectedIcon: false,
            segments: [
              for (final font in ReaderFont.values)
                ButtonSegment(
                  value: font,
                  label: Text(
                    font.label,
                    style: TextStyle(fontFamily: font.family),
                  ),
                ),
            ],
            selected: {prefs.font},
            onSelectionChanged: (s) => save(prefs.copyWith(font: s.single)),
          ),
          const SizedBox(height: Spacing.md),
          _Stepper(
            label: 'Text size',
            value: prefs.fontSize.round().toString(),
            decreaseLabel: 'Smaller text',
            increaseLabel: 'Larger text',
            onDecrease: prefs.fontSize <= ReaderPreferences.minFontSize
                ? null
                : () => save(prefs.copyWith(fontSize: prefs.fontSize - 1)),
            onIncrease: prefs.fontSize >= ReaderPreferences.maxFontSize
                ? null
                : () => save(prefs.copyWith(fontSize: prefs.fontSize + 1)),
          ),
          _SliderRow(
            label: 'Line spacing',
            value: prefs.lineHeight,
            min: ReaderPreferences.minLineHeight,
            max: ReaderPreferences.maxLineHeight,
            divisions: 11,
            display: prefs.lineHeight.toStringAsFixed(1),
            onChanged: (v) =>
                cubit.previewPreferences(prefs.copyWith(lineHeight: v)),
            onChangeEnd: (v) => save(prefs.copyWith(lineHeight: v)),
          ),
          _SliderRow(
            label: 'Paragraph spacing',
            value: prefs.paragraphSpacing,
            min: 0,
            max: ReaderPreferences.maxParagraphSpacing,
            divisions: 10,
            display: prefs.paragraphSpacing.toStringAsFixed(1),
            onChanged: (v) =>
                cubit.previewPreferences(prefs.copyWith(paragraphSpacing: v)),
            onChangeEnd: (v) => save(prefs.copyWith(paragraphSpacing: v)),
          ),
          _SliderRow(
            label: 'Margins',
            value: prefs.margin,
            min: ReaderPreferences.minMargin,
            max: ReaderPreferences.maxMargin,
            divisions: 14,
            display: prefs.margin.round().toString(),
            onChanged: (v) =>
                cubit.previewPreferences(prefs.copyWith(margin: v)),
            onChangeEnd: (v) => save(prefs.copyWith(margin: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Justify text'),
            value: prefs.justify,
            onChanged: (v) => save(prefs.copyWith(justify: v)),
          ),
        ],
      ),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({required this.selected, required this.onSelected});

  final ReaderTheme selected;
  final ValueChanged<ReaderTheme> onSelected;

  @override
  Widget build(BuildContext context) {
    // Sheets use the app theme, which is what "Auto" follows.
    final brightness = Theme.of(context).brightness;
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        for (final theme in ReaderTheme.values)
          ChoiceChip(
            avatar: _Swatch(palette: ReaderPalette.of(theme, brightness)),
            label: Text(theme.label),
            selected: theme == selected,
            onSelected: (_) => onSelected(theme),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.palette});

  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        shape: BoxShape.circle,
        border: Border.all(color: palette.secondaryText),
      ),
      child: SizedBox.square(
        dimension: 18,
        child: Center(
          child: Text(
            'A',
            style: TextStyle(
              color: palette.text,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.decreaseLabel,
    required this.increaseLabel,
    required this.onDecrease,
    required this.onIncrease,
  });

  final String label;
  final String value;
  final String decreaseLabel;
  final String increaseLabel;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton.outlined(
          tooltip: decreaseLabel,
          icon: const Icon(Icons.remove),
          onPressed: onDecrease,
        ),
        SizedBox(
          width: 48,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton.outlined(
          tooltip: increaseLabel,
          icon: const Icon(Icons.add),
          onPressed: onIncrease,
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 132, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            semanticFormatterCallback: (_) => '$label $display',
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(width: 36, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
  }
}
