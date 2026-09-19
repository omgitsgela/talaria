import 'package:flutter/material.dart';

import '../models/models.dart';

/// The messages waiting to run after the current turn.
///
/// Each one can be changed or dropped until it is sent, which is the whole
/// reason the queue lives in the app rather than being handed to the gateway:
/// the gateway keeps a single queued prompt and offers no way to change it.
/// Mirrors the desktop's composer queue, which shows its entries above the
/// input for the same reason.
class QueuedPromptStrip extends StatelessWidget {
  const QueuedPromptStrip({
    super.key,
    required this.prompts,
    required this.onToggleEdit,
    required this.onRemove,
    required this.onSendNow,
    this.editingId,
    this.enabled = true,
  });

  final List<QueuedPrompt> prompts;
  final ValueChanged<QueuedPrompt> onToggleEdit;
  final ValueChanged<String> onRemove;
  final ValueChanged<String> onSendNow;

  /// The entry currently loaded into the composer for editing, if any.
  final String? editingId;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (prompts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule_send, size: 14, color: muted),
              const SizedBox(width: 6),
              Text(
                prompts.length == 1
                    ? 'Queued for the next turn'
                    : '${prompts.length} queued for the next turn',
                style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600, color: muted),
              ),
            ],
          ),
          for (final q in prompts)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          q.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontStyle:
                                q.id == editingId ? FontStyle.italic : null,
                          ),
                        ),
                        if (q.id == editingId)
                          Text(
                            'Editing above. Send to update, or clear the box to drop it.',
                            style:
                                theme.textTheme.labelSmall?.copyWith(color: muted),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                        q.id == editingId ? Icons.close : Icons.edit_outlined,
                        size: 16),
                    tooltip:
                        q.id == editingId ? 'Stop editing' : 'Edit this message',
                    visualDensity: VisualDensity.compact,
                    onPressed: enabled ? () => onToggleEdit(q) : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.send_outlined, size: 16),
                    tooltip: 'Send now instead of waiting',
                    visualDensity: VisualDensity.compact,
                    onPressed: enabled ? () => onSendNow(q.id) : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    tooltip: 'Remove from the queue',
                    visualDensity: VisualDensity.compact,
                    onPressed: enabled ? () => onRemove(q.id) : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
