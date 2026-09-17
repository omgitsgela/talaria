import 'dart:collection';

/// Data models for the Talaria chat surface, decoded from tui_gateway
/// event payloads and RPC results.

class SessionRow {
  const SessionRow({
    required this.id,
    this.title = '',
    this.preview = '',
    this.startedAt = 0,
    this.messageCount = 0,
    this.source = '',
  });

  final String id;
  final String title;
  final String preview;
  final double startedAt; // unix seconds
  final int messageCount;
  final String source;

  factory SessionRow.fromJson(Map<String, dynamic> j) => SessionRow(
        id: (j['id'] ?? j['resolved_id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        preview: (j['preview'] ?? '') as String,
        startedAt:
            j['started_at'] is num ? (j['started_at'] as num).toDouble() : 0,
        messageCount: j['message_count'] is int ? j['message_count'] as int : 0,
        source: (j['source'] ?? '') as String,
      );

  SessionRow copyWithTitle(String title) => SessionRow(
        id: id,
        title: title,
        preview: preview,
        startedAt: startedAt,
        messageCount: messageCount,
        source: source,
      );
}

/// A live TUI session from `session.active_list` (process-local, not the
/// DB roster). Mirrors the desktop's multi-session footer row.
class ActiveRow {
  const ActiveRow({
    required this.id,
    this.title = '',
    this.model = '',
    this.cwd = '',
    this.isCurrent = false,
    this.running = false,
    this.status = '',
    this.sessionKey = '',
  });

  final String id;
  final String title;
  final String model;
  final String cwd;
  final bool isCurrent;
  final bool running;

  /// Gateway `session.active_list` status: `idle`, `working`, `waiting`
  /// (clarify/approval pending), or `starting`. Empty on older gateways.
  final String status;

  /// The STORED session key for this live session (`session_key` field).
  /// `id` is the runtime sid; roster rows are stored keys, so matching them
  /// against the live list needs this.
  final String sessionKey;

  factory ActiveRow.fromJson(Map<String, dynamic> j) => ActiveRow(
        id: (j['session_id'] ?? j['id'] ?? '') as String,
        title: (j['title'] ?? j['name'] ?? '') as String,
        model: (j['model'] ?? '') as String,
        cwd: (j['cwd'] ?? j['working_dir'] ?? '') as String,
        isCurrent: j['is_current'] == true || j['current'] == true,
        running: j['running'] == true ||
            j['busy'] == true ||
            j['status'] == 'working',
        status: (j['status'] ?? '') as String,
        sessionKey: (j['session_key'] ?? '') as String,
      );
}

/// The kind of a single, ordered segment of an assistant turn. The gateway
/// emits an assistant turn as an INTERLEAVED stream — think, call a tool,
/// think more, write some text, call another tool, finish — so the true
/// transcript is a sequence, not three separate buckets.
enum MessagePartKind { text, reasoning, tool }

/// One ordered segment of a turn. A [ChatMessage] is an ordered list of these,
/// preserving the order in which thinking / tool calls / prose actually
/// occurred (mirrors the desktop's ordered `parts` model).
class MessagePart {
  MessagePart(this.kind, {this.text = '', this.tool});
  final MessagePartKind kind;

  /// Prose (kind == text) or reasoning (kind == reasoning).
  String text;

  /// The tool call (kind == tool).
  ToolActivity? tool;
}

class ChatMessage {
  ChatMessage({
    required this.role,
    String text = '',
    List<ToolActivity>? tools,
    String reasoning = '',
    bool pending = false,
    String? error,
    this.time,
    List<MessagePart>? parts,
  })  : _id = _nextChatMessageId++,
        _pending = pending,
        _error = error,
        _parts = parts != null ? List<MessagePart>.from(parts) : <MessagePart>[] {
    // Hydration / legacy construction: seed an ordered part list from the
    // bucket fields in canonical order (thinking precedes action precedes
    // answer). Live streaming builds the list order-preserving via the
    // append* mutators instead.
    if (parts == null) {
      if (reasoning.isNotEmpty) {
        _parts.add(MessagePart(MessagePartKind.reasoning, text: reasoning));
      }
      for (final t in (tools ?? const <ToolActivity>[])) {
        _parts.add(MessagePart(MessagePartKind.tool, tool: t));
      }
      if (text.isNotEmpty) {
        _parts.add(MessagePart(MessagePartKind.text, text: text));
      }
    }
    _effectiveReasoning = reasoning;
  }

  final String role; // user | assistant
  final List<MessagePart> _parts;

  /// Monotonic identity for "this message's CONTENT changed" (row
  /// memoization) and "this message changed at all" (widget equality).
  /// Bumped by every content mutator below and by the [pending]/[error]
  /// setters. [revision] is the superset: the widget's `==` uses it so ANY
  /// visible-state change rebuilds exactly the row that changed.
  int _contentRevision = 0;
  int _revision = 0;

  int get contentRevision => _contentRevision;

  /// The message's full mutable-state generation: content AND pending/error.
  /// Used by [operator ==] so a widget built from this message is considered
  /// equal to one rebuilt from it only when nothing the widget renders can
  /// have changed (theme/markdown prefs are inherited widgets that rebuild
  /// dependents independently of `==`).
  int get revision => _revision;

  /// Stable instance identity, shared by [copy] snapshots. The transcript
  /// builder keys the row-widget memo bookkeeping (and tests) on this, so a
  /// snapshot and its live message map to the same entry.
  int get testMessageId => _id;

  /// Per-instance identity: distinguishes two messages whose fields are
  /// otherwise equal (two empty user messages in one transcript).
  final int _id;

  static int _nextChatMessageId = 0;

  void _bumpRevision({bool content = false}) {
    _revision++;
    if (content) {
      _contentRevision++;
      _invalidateCaches();
    }
  }

  /// The ordered segments, in the order they occurred.
  ///
  /// An unmodifiable VIEW over the internal list: O(1), no copy. Never
  /// retain it across mutations — read it during a build.
  List<MessagePart> get parts => UnmodifiableListView<MessagePart>(_parts);

  // ── Ordered, order-preserving mutations (live streaming) ────────────

  /// Append prose, extending a trailing text run or starting a new one.
  void appendText(String s) {
    if (s.isEmpty) return;
    if (_parts.isNotEmpty && _parts.last.kind == MessagePartKind.text) {
      _parts.last.text += s;
    } else {
      _parts.add(MessagePart(MessagePartKind.text, text: s));
    }
    _bumpRevision(content: true);
  }

  /// Append a reasoning chunk, extending a trailing reasoning run or starting
  /// a new one (this is what keeps a "thought → tool → more thought" turn
  /// ordered instead of collapsing it into one pre-tool blob).
  void appendReasoning(String s) {
    if (s.isEmpty) return;
    if (_parts.isNotEmpty && _parts.last.kind == MessagePartKind.reasoning) {
      _parts.last.text += s;
    } else {
      _parts.add(MessagePart(MessagePartKind.reasoning, text: s));
    }
    _bumpRevision(content: true);
  }

  void addTool(ToolActivity t) {
    _parts.add(MessagePart(MessagePartKind.tool, tool: t));
    _bumpRevision(content: true);
  }

  /// Replace the most recent text run with an authoritative text segment (a
  /// `message.interim` seals the segment that was streaming; a
  /// `message.complete` finalizes it). Prose that was already interleaved with
  /// earlier tools is preserved.
  ///
  /// The target is the LAST TEXT part, which is NOT necessarily `_parts.last`:
  /// a `tool.start` for the action that commentary introduced can land between
  /// the streamed deltas and the seal. Appending in that case printed the same
  /// sentence twice, once on each side of the tool block (reported
  /// 2026-09-16). The desktop replaces rather than appends for the same
  /// reason (`mergeFinalAssistantText` in apps/desktop/src/lib/chat-messages).
  void setText(String v) {
    final idx = _parts.lastIndexWhere((p) => p.kind == MessagePartKind.text);
    if (idx < 0) {
      if (v.isNotEmpty) _parts.add(MessagePart(MessagePartKind.text, text: v));
    } else if (v.isEmpty) {
      _parts.removeAt(idx);
    } else {
      _parts[idx].text = v;
    }
    _bumpRevision(content: true);
  }

  /// Overwrite the message's text parts with [texts] in order, preserving any
  /// reasoning/tool parts (used by the history merge, which reconciles only
  /// the prose of a stable-role message).
  void setTextParts(Iterable<String> texts) {
    _parts.removeWhere((p) => p.kind == MessagePartKind.text);
    for (final t in texts) {
      if (t.isNotEmpty) _parts.add(MessagePart(MessagePartKind.text, text: t));
    }
    _bumpRevision(content: true);
  }

  // ── Reads (bucket views over the ordered parts) ─────────────────────
  // These are HOT: the bubble calls [text]/[tools] on every rebuild of
  // every visible row, on every store notification. The derived values are
  // cached and invalidated by the mutators below, so a steady read is O(1)
  // instead of an O(parts) scan + string concatenation per call.

  String? _textCache;
  String? _reasoningCache;
  List<ToolActivity>? _toolsCache;

  /// Invalidate the derived caches. Every mutator that changes the part
  /// contents MUST call this — forgetting it here is a stale-read bug.
  void _invalidateCaches() {
    _textCache = null;
    _reasoningCache = null;
    _toolsCache = null;
  }

  /// All prose, in order.
  String get text {
    var c = _textCache;
    if (c == null) {
      final b = StringBuffer();
      for (final p in _parts) {
        if (p.kind == MessagePartKind.text) b.write(p.text);
      }
      c = _textCache = b.toString();
    }
    return c;
  }

  /// All reasoning across every reasoning run, in order.
  String get reasoning {
    var c = _reasoningCache;
    if (c == null) {
      final b = StringBuffer();
      for (final p in _parts) {
        if (p.kind == MessagePartKind.reasoning) b.write(p.text);
      }
      c = _reasoningCache = b.toString();
    }
    return c;
  }

  /// Every tool call, in order (the list is a snapshot, the tool objects
  /// are the live instances).
  List<ToolActivity> get tools {
    var c = _toolsCache;
    if (c == null) {
      final out = <ToolActivity>[];
      for (final p in _parts) {
        if (p.kind == MessagePartKind.tool) out.add(p.tool!);
      }
      c = _toolsCache = out;
    }
    return c;
  }

  ToolActivity? get lastTool {
    for (var i = _parts.length - 1; i >= 0; i--) {
      if (_parts[i].kind == MessagePartKind.tool) return _parts[i].tool;
    }
    return null;
  }

  /// The raw trace text always lives in [reasoning] (never destroyed by
  /// show/hide). [effectiveReasoning] is the DISPLAY view: the store blanks
  /// it when traces are hidden and restores it on reveal, mirroring the
  /// per-message contract the round 8 tests pin.
  String _effectiveReasoning = '';
  String get effectiveReasoning => _effectiveReasoning;
  set effectiveReasoning(String v) => _effectiveReasoning = v;

  /// Local authoring time of this message (from the gateway's `timestamp`,
  /// Unix seconds, or `DateTime.now()` for optimistic local appends). Drives
  /// the transcript's time-category section breaks. Null when unknown.
  DateTime? time;
  bool _pending;
  bool get pending => _pending;
  set pending(bool v) {
    if (_pending != v) {
      _pending = v;
      _bumpRevision();
    }
  }
  String? _error;
  String? get error => _error;
  set error(String? v) {
    if (_error != v) {
      _error = v;
      _bumpRevision();
    }
  }

  bool get isEmpty =>
      _parts.isEmpty ||
      _parts.every((p) => p.kind == MessagePartKind.text && p.text.isEmpty);

  /// A shallow snapshot of this message: the SAME [role]/[time]/identity and
  /// the SAME parts list, but a frozen [revision]. Used only to memoize the
  /// row WIDGET in the transcript builder — snapshots never enter the live
  /// transcript's `_messages` list, so the store's mutation paths can't alias
  /// them.
  ChatMessage copy() => ChatMessage._copy(
        id: _id,
        role: role,
        parts: _parts,
        effectiveReasoning: _effectiveReasoning,
        time: time,
        pending: _pending,
        error: _error,
        contentRevision: _contentRevision,
        revision: _revision,
      );

  ChatMessage._copy({
    required int id,
    required String role,
    required List<MessagePart> parts,
    required String effectiveReasoning,
    required DateTime? time,
    required bool pending,
    required String? error,
    required int contentRevision,
    required int revision,
  })  : _id = id,
        role = role,
        _parts = parts,
        _effectiveReasoning = effectiveReasoning,
        time = time,
        _pending = pending,
        _error = error,
        _contentRevision = contentRevision,
        _revision = revision;

  /// Equality over everything a rendered row depends on: instance identity,
  /// role, time, and the [revision] generation (content AND pending/error).
  /// Two snapshots of the same message at the same revision compare equal,
  /// which is exactly what the row-widget memoization compares.
  @override
  bool operator ==(Object other) =>
      other is ChatMessage &&
      other._id == _id &&
      other.role == role &&
      other.time == time &&
      other._revision == _revision;

  @override
  int get hashCode => Object.hash(_id, role, time, _revision);
}

class ToolActivity {
  ToolActivity({
    required this.name,
    this.toolId,
    this.state = ToolState.running,
    this.preview,
    this.summary,
    this.startedAt = 0,
  });

  final String name;
  final String? toolId;
  ToolState state;
  String? preview;
  String? summary;
  double startedAt;

  factory ToolActivity.fromEvent(Map<String, dynamic> j) => ToolActivity(
        name: (j['name'] ?? 'tool') as String,
        toolId: j['tool_id'] as String?,
        preview: (j['context'] ??
            j['preview'] ??
            j['command'] ??
            j['args']?.toString()) as String?,
      );
}

enum ToolState { running, done, error, generated }

class ModelOption {
  const ModelOption({
    required this.slug,
    this.provider,
    this.providerName,
    this.isCurrent = false,
    this.authenticated = true,
    required this.bare,
  });
  final String slug;
  final String? provider;

  /// Human-readable provider name (gateway `name`). Falls back to the
  /// provider slug in the UI when null/empty.
  final String? providerName;

  /// Bare model id with any `provider/` prefix the gateway echoes stripped.
  /// Matching the live "current model" against this (plus the provider)
  /// keeps the picker's checkmark correct after a switch — the gateway may
  /// echo the model as `provider/model` while the row slug is unprefixed.
  final String bare;

  /// Gateway's load-time "is this the active model" flag. Stale after any
  /// in-app switch; the store's live `modelIsCurrent` is the source of truth
  /// for the UI.
  final bool isCurrent;
  final bool authenticated;

  String get label => slug.length > 42 ? '${slug.substring(0, 39)}…' : slug;
}

class ProfileInfo {
  const ProfileInfo(
      {required this.name, this.isDefault = false, this.description = ''});
  final String name;
  final bool isDefault;
  final String description;
}

/// A provider and the models it offers, in first-seen order. Used by the
/// settings screen to render the model picker as collapsible per-provider
/// categories instead of one flat list.
///
/// NOTE: "current" is NOT stored here — the gateway bakes it in once at load
/// time. The picker asks the store (`providerIsCurrent`) for the live state.
class ProviderGroup {
  const ProviderGroup({
    required this.slug,
    required this.name,
    required this.models,
  });

  /// Gateway provider slug (the routing key, e.g. `openai`, `custom:lab`).
  final String slug;

  /// Human-readable provider label (falls back to [slug] when the gateway
  /// did not supply a name).
  final String name;
  final List<ModelOption> models;

  bool get allUnauthenticated =>
      models.isNotEmpty && models.every((m) => !m.authenticated);
}

/// Structured outcome of a model-switch attempt via `config.set model`.
///
/// The gateway's `confirm_required` handshake means a model switch may need
/// explicit user approval before applying. [SetModelStatus] distinguishes the
/// three outcomes so callers can present the right UI.
/// [deferred] is a real gateway outcome, not a failure: a switch requested
/// while a turn is streaming is stashed and applied at the NEXT turn start (the
/// gateway deliberately displays the pick meanwhile). Callers must not present
/// it as already active.
enum SetModelStatus { success, confirmRequired, error, disconnected, deferred }

class SetModelResult {
  const SetModelResult({
    required this.status,
    this.value = '',
    this.confirmMessage = '',
    this.error = '',
  });

  final SetModelStatus status;
  final String value;
  final String confirmMessage;
  final String error;

  bool get isSuccess => status == SetModelStatus.success;
  bool get isConfirmRequired => status == SetModelStatus.confirmRequired;
  bool get isError => status == SetModelStatus.error;

  /// Human-readable message for UI display (snackbar, dialog, etc.).
  String get message {
    switch (status) {
      case SetModelStatus.success:
        return value;
      case SetModelStatus.confirmRequired:
        return confirmMessage.isNotEmpty
            ? confirmMessage
            : 'This model may be expensive. Confirm to proceed?';
      case SetModelStatus.error:
        return error;
      case SetModelStatus.disconnected:
        return 'Not connected';
      case SetModelStatus.deferred:
        return value.isEmpty
            ? 'Applies from the next turn'
            : 'Model: $value (applies from the next turn)';
    }
  }
}

/// Outcome of a `command.dispatch`-style structured slash response.
///
/// `slash.exec` returns a plain `{output: ...}` for worker-executed commands
/// (`/help`, `/model`, `/compress`). For the pending-input built-ins
/// (`/queue`, `/steer`, `/retry`, `/goal`, `/undo`, …) it returns a structured
/// directive the client must ACT on — the same contract the desktop's
/// `parseCommandDispatch` consumes:
///   - `send`:    submit `message` as a prompt (works mid-turn — the gateway
///                busy-queues it). `notice` is an optional system line to show
///                first (e.g. `/goal`'s "⊙ Goal set …").
///   - `prefill`: drop `message` into the composer for editing (`/undo`).
///   - `exec`:    display-only `output`.
///   - `alias`:   re-run the command named by `target`.
///   - `skill`:   submit the expanded skill body in `message` (never render it).
class SlashDispatch {
  const SlashDispatch({
    required this.type,
    this.message = '',
    this.notice = '',
    this.output = '',
    this.target = '',
  });

  /// One of `send`, `prefill`, `exec`, `alias`, `skill`. Empty for the
  /// guard/no-op path.
  final String type;
  final String message;
  final String notice;
  final String output;
  final String target;

  bool get isSend => type == 'send';
  bool get isPrefill => type == 'prefill';
  bool get isExec => type == 'exec';
  bool get isAlias => type == 'alias';
  bool get isSkill => type == 'skill';

  /// Display text for display-only results (falls back to the notice).
  String get display => output.isNotEmpty ? output : notice;
}
