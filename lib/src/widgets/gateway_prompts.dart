import 'package:flutter/material.dart';

import '../gateway/client.dart';

/// Cards for the requests the gateway needs an ANSWER to.
///
/// These are the prompts that make the app usable for anything consequential:
/// an approval before a dangerous command runs, and the sudo password the
/// terminal tool asks for. The gateway blocks the agent until each one is
/// answered, so showing them is not cosmetic: without them the turn sits until
/// the gateway's own timeout expires and the app looks hung.

/// The sudo password or secret-value prompt.
///
/// Masked, and the value is handed straight to the gateway's waiting callback:
/// it is never stored on the device, never echoed, and the field is cleared as
/// soon as it is sent.
class SecretPromptCard extends StatefulWidget {
  const SecretPromptCard({
    super.key,
    required this.request,
    required this.onSubmit,
  });

  final ServerRequest request;
  final void Function(String value) onSubmit;

  @override
  State<SecretPromptCard> createState() => _SecretPromptCardState();
}

class _SecretPromptCardState extends State<SecretPromptCard> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    // Do not leave the value in memory longer than the prompt needs it.
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text;
    _controller.clear();
    widget.onSubmit(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final req = widget.request;
    final prompt = (req.params['prompt'] ?? '').toString();
    final envVar = (req.params['env_var'] ?? '').toString();
    final command = (req.params['command'] ?? '').toString();
    final isSudo = req.method == 'sudo';

    return Container(
      key: const ValueKey('secret_prompt_card'),
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(isSudo ? Icons.terminal : Icons.key,
                  size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isSudo
                      ? 'Sudo password needed'
                      : (envVar.isEmpty
                          ? 'Value needed'
                          : 'Value needed · $envVar'),
                  style: theme.textTheme.labelLarge,
                ),
              ),
            ],
          ),
          if (isSudo && command.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(command,
                style:
                    theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
          ],
          if (prompt.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(prompt, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('secret_prompt_field'),
            controller: _controller,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              isDense: true,
              hintText: isSudo ? 'Password' : 'Value',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off,
                    size: 18),
                tooltip: _obscure ? 'Show' : 'Hide',
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilledButton(
                key: const ValueKey('secret_prompt_send'),
                onPressed: _submit,
                child: const Text('Send'),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('secret_prompt_skip'),
                // An empty value is the gateway's own "skipped" answer, so the
                // agent stops waiting instead of hanging until its timeout.
                onPressed: () => widget.onSubmit(''),
                child: const Text('Skip'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Says, unmistakably, when approvals are switched off for this session.
///
/// `/yolo` is a session flag, but the gateway skips approvals when ANY of three
/// things is true (the session flag, the process-wide flag, or
/// `approvals.mode: off`), so typing /yolo successfully does not by itself mean
/// nothing is being checked. This banner reflects the gateway's own computed
/// answer.
class YoloBanner extends StatelessWidget {
  const YoloBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      key: const ValueKey('yolo_banner'),
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.no_encryption_gmailerrorred, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Approvals are OFF for this session, so dangerous commands run '
              'without asking.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
            ),
          ),
        ],
      ),
    );
  }
}
