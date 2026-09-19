/// Typed model of the gateway's reasoning-effort setting.
///
/// Contract, verified against the gateway source:
/// - The `config.set` dispatch key is `reasoning`
///   (`tui_gateway/methods_config_set.py:462`, `_CONFIG_SETTERS`). With
///   `scope: 'global'` (or no live session) the gateway persists the choice
///   as `agent.reasoning_effort` in config.yaml
///   (`methods_config_set.py:310-311`), the same key Desktop edits.
/// - Accepted levels are `VALID_REASONING_EFFORTS`
///   (`hermes_constants.py:960`): minimal, low, medium, high, xhigh, max,
///   ultra. The disabled words none/false/disabled parse to "thinking off"
///   (`hermes_constants.py:972-973`); this app sends `none` for off.
/// - `config.get` key `reasoning` answers `{value: effort, display:
///   show|hide}` (`tui_gateway/methods_config.py:151-165`). The effort lives
///   in `value`; `display` is the unrelated trace-visibility switch. An
///   unset config reads back as `medium` (`methods_config.py:163`).
/// - Unknown values are rejected with error 4002
///   (`methods_config_set.py:308-309`).
library;

/// Transport shape shared with `GatewayClient.request`: the client's tear-off
/// (which has extra optional positional parameters) is assignable to this
/// type, and tests inject a fake.
typedef ConfigTransport = Future<Map<String, dynamic>> Function(
    String method, Map<String, dynamic> params);

/// Outcome of a [ReasoningEffort.write]. [applied] is true only when the
/// authoritative re-read matches the requested value: a write the gateway
/// silently ignored is a failure, never a success.
class EffortWrite {
  const EffortWrite({
    required this.requested,
    required this.actual,
    required this.applied,
    this.refusal,
  });

  /// The level the caller asked for (normalized).
  final String requested;

  /// What the gateway reports after the write. Empty when the write was
  /// refused locally before any RPC.
  final String actual;

  /// The re-read value equals the requested value.
  final bool applied;

  /// Why a locally refused value was refused, null otherwise.
  final String? refusal;

  bool get refused => refusal != null;
}

class ReasoningEffort {
  const ReasoningEffort(this.current);

  /// The live value as last read from the gateway (normalized lowercase).
  /// Empty when no read has succeeded yet.
  final String current;

  /// The `config.get` / `config.set` dispatch key.
  static const configKey = 'reasoning';

  /// Every value the gateway accepts, cheapest first. `none` disables
  /// thinking entirely. Order matters: the selector renders this sequence.
  static const levels = <String>[
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultra',
  ];

  static const _levelSet = <String>{
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultra',
  };

  /// Normalize the way the gateway does (`_word`, methods_config_set.py:45):
  /// trim and lowercase.
  static String normalize(String value) => value.trim().toLowerCase();

  static bool isSupported(String value) => _levelSet.contains(normalize(value));

  /// Whether the current value is one the gateway understands. An
  /// unrecognized value is shown as-is, never coerced.
  bool get isRecognized => _levelSet.contains(current);

  /// Read the current value from live config. Never assumes a default: the
  /// gateway reports `medium` itself when the key is unset
  /// (methods_config.py:163), so an empty [current] here means the read
  /// genuinely returned nothing usable.
  static Future<ReasoningEffort> load(ConfigTransport transport) async {
    final res = await transport('config.get', const {'key': configKey});
    final raw = res['value'];
    return ReasoningEffort(raw is String ? normalize(raw) : '');
  }

  /// Write [value] through `config.set` with global scope (persists
  /// `agent.reasoning_effort`, the Desktop parity behavior), then RE-READ the
  /// value and report what actually stuck.
  ///
  /// Unsupported values are refused before any RPC: coercing them silently
  /// would hide a caller bug, and the gateway would reject them anyway.
  ///
  /// Transport and RPC errors (including the gateway's 4002 rejection)
  /// propagate to the caller.
  Future<EffortWrite> write(ConfigTransport transport, String value) async {
    final v = normalize(value);
    if (!_levelSet.contains(v)) {
      return EffortWrite(
        requested: v,
        actual: '',
        applied: false,
        refusal: 'unsupported reasoning effort: $value',
      );
    }
    await transport('config.set', {
      'key': configKey,
      'value': v,
      'scope': 'global',
    });
    final after = await load(transport);
    return EffortWrite(
      requested: v,
      actual: after.current,
      applied: after.current == v,
    );
  }
}
