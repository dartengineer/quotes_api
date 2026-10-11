import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Explains that a link points to a website. The app never opens it (it
/// works offline and makes no network requests); the address can be copied.
Future<void> showWebLinkDialog(BuildContext context, Uri url) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Link to a website'),
      content: SelectableText(url.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.tonal(
          onPressed: () {
            unawaited(Clipboard.setData(ClipboardData(text: url.toString())));
            Navigator.of(context).pop();
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('Link copied')));
          },
          child: const Text('Copy link'),
        ),
      ],
    ),
  );
}
