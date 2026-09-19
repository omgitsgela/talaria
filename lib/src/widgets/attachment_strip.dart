import 'package:flutter/material.dart';

import '../media/image_attachment.dart';

class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip(
      {super.key,
      required this.attachments,
      required this.onRemove,
      this.enabled = true});

  final List<PendingAttachment> attachments;
  final ValueChanged<String> onRemove;
  final bool enabled;

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 76,
      child: ListView.separated(
        primary: false,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: attachments.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          final bytes = attachment.bytes;
          return Container(
            key: ValueKey(attachment.ref),
            width: 240,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              SizedBox(
                width: 48,
                height: 48,
                child: bytes == null
                    ? const Icon(Icons.insert_drive_file_outlined)
                    : Image.memory(bytes,
                        fit: BoxFit.cover,
                        cacheWidth: 144,
                        errorBuilder: (context, error, stack) =>
                            const Icon(Icons.broken_image_outlined)),
              ),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(attachment.filename,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(_size(attachment.sizeBytes),
                      style: Theme.of(context).textTheme.labelSmall),
                ],
              )),
              IconButton(
                tooltip: 'Remove ${attachment.filename}',
                onPressed: enabled ? () => onRemove(attachment.ref) : null,
                icon: const Icon(Icons.close_rounded),
              ),
            ]),
          );
        },
      ),
    );
  }
}
