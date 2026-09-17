import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Debug-build error capture with a COPYABLE report.
///
/// Why this exists: on device, a Flutter assertion renders the red error
/// screen, which (on Android) offers nothing to copy — so the single most
/// useful piece of evidence for a render/element-tree bug (the
/// "relevant error-causing widget" line plus the stack trace) is
/// unreachable without `adb logcat`. This captures the full
/// [FlutterErrorDetails] text, keeps a bounded tail of recent `debugPrint`
/// output alongside it (including GlobalKey reparenting traces), and renders
/// the report in a panel with a copy button.
///
/// Debug-only: [install] no-ops unless `kDebugMode`, and the release path
/// keeps the framework defaults.
class ErrorReport {
  ErrorReport._();

  /// The most recent formatted report, or null before the first error.
  static final ValueNotifier<String?> last = ValueNotifier<String?>(null);

  static const int _maxLogLines = 400;
  static final List<String> _log = <String>[];
  static bool _printWrapped = false;
  static void Function(String? message, {int? wrapWidth})? _originalPrint;

  /// Recent captured log lines (debug output tail).
  @visibleForTesting
  static List<String> get logLines => List.unmodifiable(_log);

  @visibleForTesting
  static void clearForTest() {
    _log.clear();
    last.value = null;
  }

  /// Route framework errors into [last] and replace the un-copyable red screen
  /// with [ErrorReportPanel]. Safe to call once from `main()`.
  static void install() {
    if (!kDebugMode) return;

    // GlobalKey tree surgery is the known trigger for the element/render-tree
    // assertions seen on device; record its lifecycle lines in the report so
    // the next occurrence names the offending key.
    debugPrintGlobalKeyedWidgetLifecycle = true;

    if (!_printWrapped) {
      _printWrapped = true;
      final originalPrint = _originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.isNotEmpty) {
          _log.add(message);
          if (_log.length > _maxLogLines) _log.removeAt(0);
        }
        originalPrint(message, wrapWidth: wrapWidth);
      };
    }

    // Reassigned on every call (cheap, and keeps `install()` usable from
    // tests that restore the globals afterwards).
    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      last.value = format(details);
      previous?.call(details);
    };

    ErrorWidget.builder = (FlutterErrorDetails details) =>
        ErrorReportPanel(details: details);
  }

  /// Undo [install]'s framework-global mutations. Tests must call this in a
  /// teardown: the test framework asserts (`debugAssertAllFoundationVarsUnset`)
  /// that debug variables are unchanged between tests, and
  /// `debugPrintGlobalKeyedWidgetLifecycle` is one of them.
  @visibleForTesting
  static void uninstallForTest() {
    debugPrintGlobalKeyedWidgetLifecycle = false;
    if (_printWrapped && _originalPrint != null) {
      debugPrint = _originalPrint!;
      _printWrapped = false;
    }
  }

  /// Full, paste-able report for [details], including the recent log tail.
  static String format(FlutterErrorDetails details) {
    final b = StringBuffer()
      ..writeln('=== Talaria error report ===')
      ..writeln('time: ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln(details.toString());
    if (_log.isNotEmpty) {
      b
        ..writeln()
        ..writeln('--- recent log (${_log.length} lines) ---')
        ..writeln(_log.join('\n'));
    }
    return b.toString();
  }

  /// Copy [text] to the clipboard, reporting the outcome so the panel can show
  /// feedback when the platform refuses.
  static Future<bool> copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Replacement for the debug red screen: the same information, but selectable
/// and copyable, so a user can hand the full report back verbatim.
class ErrorReportPanel extends StatefulWidget {
  const ErrorReportPanel({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  State<ErrorReportPanel> createState() => _ErrorReportPanelState();
}

class _ErrorReportPanelState extends State<ErrorReportPanel> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = ErrorReport.format(widget.details);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline,
                    size: 18, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This part of the screen hit an error. Copy the report '
                    'below so it can be fixed.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    report,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 10, height: 1.25),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () async {
                    final ok = await ErrorReport.copy(report);
                    if (!mounted) return;
                    setState(() => _copied = ok);
                  },
                  icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                  label: Text(_copied ? 'Copied' : 'Copy report'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
