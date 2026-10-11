import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Centered progress indicator for content that is still loading.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label = 'Loading'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(label: label, child: const CircularProgressIndicator()),
    );
  }
}

/// Friendly placeholder for screens or sections with nothing to show.
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// Optional call to action, typically a button.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CenteredMessage(
      children: [
        Icon(icon, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: Spacing.lg),
        Text(
          title,
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        if (message case final message?) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        if (action case final action?) ...[
          const SizedBox(height: Spacing.xl),
          action,
        ],
      ],
    );
  }
}

/// Error placeholder with an optional retry action.
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({
    super.key,
    this.title = 'Something went wrong',
    required this.message,
    this.onRetry,
    this.icon = Icons.error_outline,
    this.retryLabel = 'Try again',
    this.retryIcon = Icons.refresh,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final IconData icon;
  final String retryLabel;
  final IconData retryIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CenteredMessage(
      children: [
        Icon(icon, size: 56, color: theme.colorScheme.error),
        const SizedBox(height: Spacing.lg),
        Text(
          title,
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        if (onRetry != null) ...[
          const SizedBox(height: Spacing.xl),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: Icon(retryIcon),
            label: Text(retryLabel),
          ),
        ],
      ],
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Scrollable so large text sizes never overflow on small screens.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}
