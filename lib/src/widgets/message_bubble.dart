import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../theme/markdown_preference.dart';

/// A single transcript row: a user or assistant message with its inline
/// tool-activity list and (collapsible) reasoning.
///
/// The built row is MEMOIZED against [ChatMessage.revision] (plus the theme
/// and the markdown preference, which the build hard-bakes). The store
/// notifies on every streamed delta, so the list builder produces a FRESH
/// [MessageBubble] widget for every visible row on every event and the row's
/// [State.build] runs — but that build is a cheap gate: when nothing the
/// memoized [build] depends on changed it returns the CACHED subtree
/// instance, so no markdown re-parse, no `SelectableText` machinery, no
/// layout of a row that did not change. (`Widget.==` is non-virtual — the
/// framework's `updateChild` widget-identity skip only fires for const
/// widgets — so the State gate is the real memo; the builder passes a
/// [ChatMessage.copy] SNAPSHOT, never the live instance, so the row sees a
/// stable widget until its message actually changes.)
class MessageBubble extends StatefulWidget {
  const MessageBubble({super.key, required this.message, required this.isUser});

  final ChatMessage message;
  final bool isUser;

  /// Test seam: how many times each message's row body has (re)built.
  /// Keyed by [ChatMessage.testMessageId] (stable across snapshot copies).
  /// The count is the memo-miss count: a healthy memo rebuilds a row only
  /// when its message actually changed (or the theme/markdown pref flipped).
  @visibleForTesting
  static final Map<int, int> testBuildCounts = {};

  @visibleForTesting
  static int buildCountFor(ChatMessage m) =>
      testBuildCounts[m.testMessageId] ?? 0;

  /// Test isolation: identityHashCodes are recycled by the GC, so stale
  /// entries would otherwise bleed between tests.
  @visibleForTesting
  static void resetTestBuildCounts() => testBuildCounts.clear();

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  /// Revision the last built [body] was rendered from. -1 = never built.
  int _builtRevision = -1;

  /// The theme + markdown preference the cached [body] was rendered under.
  /// The row widget hard-bakes theme colors and the markdown/plain choice, so
  /// a change to EITHER must invalidate the cache — the `Theme`/
  /// `MarkdownPreference` inherited rebuild reaches this build() but the
  /// memoized subtree would otherwise keep the stale colors / rendering.
  ThemeData? _builtTheme;
  bool? _builtMarkdown;
  Widget? _body;

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final theme = Theme.of(context);
    final markdown = MarkdownPreference.maybeOf(context)?.enabled.value ?? true;
    if (_body == null ||
        msg.revision != _builtRevision ||
        _builtTheme != theme ||
        _builtMarkdown != markdown) {
      _body = _buildRow(theme, markdown);
      _builtRevision = msg.revision;
      _builtTheme = theme;
      _builtMarkdown = markdown;
      MessageBubble.testBuildCounts
          .update(msg.testMessageId, (v) => v + 1, ifAbsent: () => 1);
    }
    return _body!;
  }

  /// Builds the row from explicit inputs (not `context`) so the caller can
  /// gate the memo on exactly the values that affect the output.
  Widget _buildRow(ThemeData theme, bool markdown) {
    final message = widget.message;
    final isUser = widget.isUser;
    // Visible traces respect the live show/hide display switch; the raw trace
    // stays in [message.reasoning] and re-appears on reveal. The store gates
    // it per message by blanking [effectiveReasoning] when traces are hidden,
    // so "effective non-empty" is the visible-traces signal here.
    final tracesVisible = message.effectiveReasoning.isNotEmpty;
    final hasContent = message.text.isNotEmpty ||
        message.tools.isNotEmpty ||
        (tracesVisible && message.reasoning.isNotEmpty);
    final isPending = message.pending && !hasContent;

    if (isPending) {
      // Assistant thinking, nothing yet (no text, no tools, no visible trace).
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text('Hermes is working…',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    // Render the message's ordered parts in the order they actually occurred
    // — think → act → think → answer — instead of the old fixed
    // reasoning → tools → text layout that lost any interleaving.
    final parts = message.parts;
    final children = <Widget>[];
    final toolRun = <ToolActivity>[];
    void flushTools() {
      if (toolRun.isEmpty) return;
      children.add(_ToolList(tools: List.unmodifiable(toolRun)));
      toolRun.clear();
    }

    Widget textBubble(String t) {
      return Container(
        margin: EdgeInsets.only(left: isUser ? 0 : 8, right: isUser ? 8 : 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: Radius.circular(isUser ? 16 : 4),
            bottomLeft: Radius.circular(isUser ? 4 : 16),
            bottomRight: const Radius.circular(16),
          ),
        ),
        child: _MessageText(
          text: t,
          assistant: !isUser,
          theme: theme,
          color: isUser
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSurface,
        ),
      );
    }

    for (final part in parts) {
      switch (part.kind) {
        case MessagePartKind.reasoning:
          if (!isUser && tracesVisible && part.text.isNotEmpty) {
            flushTools();
            // Live (spinner) only on the part still streaming — the last one.
            children.add(_Reasoning(
              text: part.text,
              live: message.pending && identical(part, parts.last),
            ));
          }
          break;
        case MessagePartKind.tool:
          final t = part.tool;
          if (!isUser && t != null) toolRun.add(t);
          break;
        case MessagePartKind.text:
          if (part.text.isNotEmpty) {
            flushTools();
            children.add(textBubble(part.text));
          }
          break;
      }
    }
    flushTools();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          ...children,
          if (!isUser &&
              message.pending &&
              message.text.isEmpty &&
              message.tools.isEmpty &&
              message.reasoning.isEmpty)
            _WorkingIndicator(theme: theme),
          if (message.error != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 4),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 16, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(message.error!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The message body: assistant text renders as rich, selectable Markdown when
/// the app-level toggle is ON (the default); user text is always plain
/// selectable text. The toggle is a LOCAL UI preference (see
/// [MarkdownPreference]) and is read live, so flipping it in Settings re-renders
/// every bubble without a restart.
class _MessageText extends StatelessWidget {
  const _MessageText({
    required this.text,
    required this.assistant,
    required this.theme,
    required this.color,
  });

  final String text;
  final bool assistant;
  final ThemeData theme;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final renderMarkdown = assistant &&
        (MarkdownPreference.maybeOf(context)?.enabled.value ?? true);
    if (!renderMarkdown) {
      final lines = text.split('\n');
      if (lines.any((line) => _imageReference(line) != null)) {
        return SelectionArea(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              if (_imageReference(line) case final String source)
                _TranscriptImage(source: source)
              else
                Text(line,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: color, height: 1.4)),
          ],
        ));
      }
      return SelectableText(
        text,
        style: theme.textTheme.bodyLarge?.copyWith(color: color, height: 1.4),
      );
    }
    return SelectionArea(
      child: MarkdownBody(
        data: _imageMarkdown(text),
        imageBuilder: (uri, title, alt) => _TranscriptImage(
            source: uri.toString(), label: alt ?? title ?? 'Image'),
        selectable: false,
        softLineBreak: true,
        styleSheet: MarkdownStyleSheet(
          p: theme.textTheme.bodyLarge?.copyWith(color: color, height: 1.4),
          pPadding: const EdgeInsets.symmetric(vertical: 4),
          strong: theme.textTheme.bodyLarge
              ?.copyWith(color: color, fontWeight: FontWeight.w700),
          em: theme.textTheme.bodyLarge
              ?.copyWith(color: color, fontStyle: FontStyle.italic),
          code: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface,
            fontFamily: 'monospace',
            backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
          ),
          // Fenced code BLOCKS: flutter_markdown's default `codeblockDecoration`
          // is a light-blue panel (Colors.blue.shade100), which made dark-mode
          // code blocks unreadable (light bg behind light text). Give
          // them a theme-consistent dark panel + readable onSurface text so they
          // read correctly in both themes.
          codeblockDecoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          codeblockPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          // BLOCKQUOTES have the same package-default trap as code blocks:
          // the material fallback stylesheet hardcodes
          // `blockquoteDecoration: Colors.blue.shade100` (a LIGHT blue that is
          // not brightness-aware), and MarkdownBody merges the app stylesheet
          // ON TOP of that fallback: any token the app does not override falls
          // through to it, so every quoted passage inherited that color and
          // rendered as white text on light blue in dark mode. Use a
          // theme surface one step below the bubble (inset panel in both
          // brightnesses) plus a gold left accent so it reads as a quote.
          blockquoteDecoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border(
              left: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.4),
                width: 3,
              ),
            ),
          ),
          blockquotePadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          a: theme.textTheme.bodyLarge
              ?.copyWith(color: theme.colorScheme.primary, height: 1.4),
          blockquote: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant, height: 1.4),
          listBullet: theme.textTheme.bodyLarge?.copyWith(color: color),
          listIndent: 16,
          h1: theme.textTheme.titleLarge?.copyWith(color: color),
          h2: theme.textTheme.titleMedium?.copyWith(color: color),
          h3: theme.textTheme.titleSmall?.copyWith(color: color),
          h4: theme.textTheme.bodyLarge?.copyWith(color: color),
        ),
        onTapLink: (text, href, title) async {
          final url = href;
          if (url == null) return;
          final u = Uri.tryParse(url);
          if (u == null) return;
          if (u.hasScheme) {
            try {
              await launchUrl(u, mode: LaunchMode.externalApplication);
            } catch (_) {
              // No handler for this scheme (e.g. tel:/mailto: on some devices).
            }
          } else {
            // Treat as a relative web URL: open in the browser.
            try {
              await launchUrl(Uri.parse('https://$url'),
                  mode: LaunchMode.externalApplication);
            } catch (_) {}
          }
        },
      ),
    );
  }
}

String? _imageReference(String line) {
  final value = line.trim();
  for (final prefix in ['@image:', 'MEDIA:']) {
    if (value.startsWith(prefix)) {
      var source = value.substring(prefix.length).trim();
      if (source.length >= 2 &&
          ((source.startsWith('"') && source.endsWith('"')) ||
              (source.startsWith("'") && source.endsWith("'")))) {
        source = source.substring(1, source.length - 1);
      }
      // MEDIA also carries audio and documents, which are not images.
      if (prefix == '@image:' || _isImageUrl(source)) return source;
    }
  }
  if (RegExp(r'\s').hasMatch(value)) return null;
  return _isImageUrl(value) ? value : null;
}

bool _isImageUrl(String source) {
  if (source.startsWith('data:image/')) return true;
  final uri = Uri.tryParse(source);
  return uri != null &&
      RegExp(r'\.(png|jpe?g|gif|webp|bmp|avif|heic|svg)$', caseSensitive: false)
          .hasMatch(uri.path);
}

String _imageMarkdown(String text) {
  String? fence;
  return text.split('\n').map((line) {
    final marker = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line)?.group(1);
    if (marker != null) {
      if (fence == null) {
        fence = marker;
      } else if (marker.startsWith(fence!)) {
        fence = null;
      }
      return line;
    }
    if (fence != null || line.startsWith('    ')) return line;
    final source = _imageReference(line);
    if (source == null) return line;
    return '\n![Image](<${source.replaceAll(' ', '%20').replaceAll('>', '%3E')}>)\n';
  }).join('\n');
}

class _TranscriptImage extends StatelessWidget {
  const _TranscriptImage({required this.source, this.label = 'Image'});
  final String source;
  final String label;

  ImageProvider? _provider() {
    try {
      final uri = Uri.parse(source);
      if (uri.scheme == 'data') {
        final data = uri.data!;
        if (!data.mimeType.startsWith('image/')) return null;
        final Uint8List bytes = data.contentAsBytes();
        return bytes.isEmpty ? null : MemoryImage(bytes);
      }
      if ((uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        return NetworkImage(source);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Widget _unavailable() => Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
            'Image unavailable: $label\n${source.startsWith('data:') ? 'Invalid or unsupported image data' : source}\nThe image could not be loaded on this device.'),
      );

  @override
  Widget build(BuildContext context) {
    final provider = _provider();
    if (provider == null) return _unavailable();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image(
          image: provider,
          height: 240,
          width: 320,
          fit: BoxFit.contain,
          semanticLabel: label,
          errorBuilder: (_, error, stack) => _unavailable(),
          frameBuilder: (context, child, frame, synchronous) {
            if (frame == null && !synchronous) {
              return const SizedBox(
                  height: 80, child: Center(child: Text('Loading image…')));
            }
            return Semantics(
              button: true,
              label: 'Open image full size',
              child: InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (context) => Scaffold(
                    appBar: AppBar(title: Text(label)),
                    body: Center(
                        child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 8,
                      child: Image(
                          image: provider,
                          fit: BoxFit.contain,
                          errorBuilder: (_, error, stack) => _unavailable()),
                    )),
                  ),
                )),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ToolList extends StatelessWidget {
  const _ToolList({required this.tools});
  final List<ToolActivity> tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          for (final t in tools)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  _toolIcon(t, theme),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.name,
                            style: theme.textTheme.labelMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        if (t.preview != null && t.preview!.isNotEmpty)
                          Text(t.preview!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolIcon(ToolActivity t, ThemeData theme) {
    switch (t.state) {
      case ToolState.running:
        return Semantics(
          label: 'tool running',
          child: const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
        );
      case ToolState.generated:
        return Semantics(
            label: 'tool generated',
            child: Icon(Icons.auto_awesome,
                size: 14, color: theme.colorScheme.primary));
      case ToolState.done:
        return Semantics(
            label: 'tool done',
            child: Icon(Icons.check_circle,
                size: 14, color: theme.colorScheme.primary));
      case ToolState.error:
        return Semantics(
            label: 'tool error',
            child: Icon(Icons.error, size: 14, color: theme.colorScheme.error));
    }
  }
}

class _Reasoning extends StatelessWidget {
  const _Reasoning({required this.text, this.live = false});
  final String text;

  /// True while the trace is still streaming in (no final answer yet): shows a
  /// live pulse next to the label so the user knows reasoning is happening now,
  /// not that a past trace is being replayed.
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ExpansionTile(
            backgroundColor: Colors.transparent,
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 8),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            initiallyExpanded: live,
            title: Row(
              children: [
                if (live)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  Icon(Icons.psychology_alt,
                      size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  live ? 'Thinking…' : 'Reasoning',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            children: [
              SelectableText(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkingIndicator extends StatelessWidget {
  const _WorkingIndicator({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text('Hermes is working…',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
