import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// Asks for a PDF's password. Returns null if the user cancels.
///
/// The password is used once to open the file and is never stored, logged
/// or offered to autofill.
Future<String?> showPdfPasswordDialog(
  BuildContext context, {
  required bool retry,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PasswordDialog(retry: retry),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.retry});

  final bool retry;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _field = TextEditingController();
  bool _obscured = true;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_field.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Password required'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.retry
                ? 'That password didn’t work. Try again.'
                : 'This PDF is protected. Enter its password to open it.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _field,
            autofocus: true,
            obscureText: _obscured,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              errorText: widget.retry ? 'Incorrect password' : null,
              suffixIcon: IconButton(
                tooltip: _obscured ? 'Show password' : 'Hide password',
                icon: Icon(
                  _obscured ? Icons.visibility_outlined : Icons.visibility_off,
                ),
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Open')),
      ],
    );
  }
}
