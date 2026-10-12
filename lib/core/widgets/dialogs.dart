import 'package:material_ui/material_ui.dart';

/// Asks the user to confirm an action. Resolves to true only on confirm.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        // Long text or the keyboard scrolls the dialog instead of
        // overflowing it (large text sizes, small screens).
        scrollable: true,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// Asks for a name. [onSubmit] performs the action and returns an error
/// message to show (the dialog stays open), or null on success.
///
/// Resolves to true if the action succeeded.
Future<bool> showNameDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required Future<String?> Function(String name) onSubmit,
  String initialValue = '',
  String label = 'Name',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => _NameDialog(
      title: title,
      confirmLabel: confirmLabel,
      onSubmit: onSubmit,
      initialValue: initialValue,
      label: label,
    ),
  );
  return result ?? false;
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.confirmLabel,
    required this.onSubmit,
    required this.initialValue,
    required this.label,
  });

  final String title;
  final String confirmLabel;
  final Future<String?> Function(String name) onSubmit;
  final String initialValue;
  final String label;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await widget.onSubmit(_controller.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 200,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: widget.label, errorText: _error),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
