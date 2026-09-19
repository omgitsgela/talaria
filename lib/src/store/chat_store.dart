import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gateway/client.dart';
import '../gateway/config.dart';
import '../gateway/http_service.dart';
import '../gateway/native_oauth.dart';
import '../gateway/oauth_flow.dart';
import '../media/attachment_cache.dart';
import '../media/image_attachment.dart';
import '../models/context_breakdown.dart';
import '../models/context_usage.dart';
import '../models/goal_status.dart';
import '../models/models.dart';
import '../notifications/notifier.dart';
import '../notifications/foreground.dart';

/// One segment of the conversations list: a label (empty for the pinned
/// group) and the rows in it, already in display order.
class RosterSegment {
  const RosterSegment(this.label, this.rows);

  final String label; // '' = pinned group, else 'Today'/'Yesterday'/…
  final List<SessionRow> rows;
}

/// Owns the live connection to the gateway plus all chat state.
///
/// One store per app; the app connects on launch and the store survives
/// screen switches. Streaming events from the gateway drive [messages]
/// and [notifications] (foreground + background).
class ChatStore extends ChangeNotifier {
  ChatStore(
      {required GatewayConfig config,
      GatewayClient? client,
      OAuthFlowRunner? oauthRunner})
      : config = config,
        _client = client ?? GatewayClient(config),
        _http = GatewayHttp(config),
        _oauth = oauthRunner {
    _wireEvents();
    _client.stateChanges.listen(_onState);
    _client.beforeConnect = _refreshOAuthIfStale;
  }

  final GatewayConfig config;
  final GatewayClient _client;
  final GatewayHttp _http;
  final OAuthFlowRunner? _oauth;
  final TalariaNotifier _notifier = TalariaNotifier();
  final ForegroundKeeper _fg = ForegroundKeeper();

  /// Called before every (re)dial. If the connection uses a stored OAuth
  /// bearer and it is at/near expiry, rotate it through the gateway refresh
  /// endpoint so the dial never presents a dead token. Non-OAuth configs and
  /// static (non-stored) bearers are a no-op. Failures are swallowed — the
  /// dial will surface them.
  Future<void> _refreshOAuthIfStale() async {
    final runner = _oauth;
    if (runner == null) return;
    if (!config.usesOAuth) return;
    try {
      final stored = await runner.store.load(config.baseUrl);
      if (stored == null)
        return; // No stored set — bearer may be a static token.
      if (stored.accessToken == config.oauthToken &&
          !NativeOAuthService.tokenNeedsRefresh(stored,
              nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
        return; // Stored bearer still valid.
      }
      if (stored.refreshToken.isEmpty) return;
      // Refreshing: show a TRANSIENT status, and ALWAYS clear it when the
      // refresh finishes (success or failure). We manage the line ourselves
      // (no `onStatus` callback) so the clear is guaranteed to run. Relying on
      // the caller's later clear was the bug: that clear does not run on the
      // reconnect path, so "Refreshing session…" used to stick in the
      // transcript forever (the gray box that never went away).
      _statusLine = 'Refreshing session…';
      if (!_disposed) notifyListeners();
      try {
        final refreshed = await runner.refresh(config.baseUrl, stored,
            headers: config.headers);
        if (refreshed != null && refreshed.accessToken.isNotEmpty) {
          config.oauthToken = refreshed.accessToken;
        }
      } finally {
        _statusLine = '';
        if (!_disposed) notifyListeners();
      }
    } catch (_) {
      // Best-effort: let the dial fail with the stale token rather than crash.
    }
  }

  GwConnectionState _conn = GwConnectionState.idle;
  GwConnectionState get connection => _conn;
  String? _connectError;
  String? get connectError => _connectError;

  // Sessions
  final List<SessionRow> _sessions = [];
  List<SessionRow> get sessions => List.unmodifiable(_sessions);
  final List<ActiveRow> _activeList = [];
  List<ActiveRow> get activeList => List.unmodifiable(_activeList);

  int _selection = 0;
  int _attachGen =
      0; // Bumped on every lifecycle transition to invalidate in-flight attach results.
  bool _loadingSession = false;
  bool get loadingSession => _loadingSession;

  /// The runtime id the gateway most recently HANDED US for the active
  /// conversation (from `session.create` or `session.resume`). Holding it is
  /// evidence the session is live without asking the gateway again, and it is
  /// dropped when the socket does, because a WS disconnect is what detaches and
  /// reaps runtime ids on the gateway side.
  String? _verifiedLiveSessionId;

  /// Test seam: the runtime id currently trusted as live, if any.
  String? get verifiedLiveSessionIdForTest => _verifiedLiveSessionId;

  /// True while the transcript of the active conversation is genuinely in
  /// flight and nothing is on screen yet: a resume is running, or a
  /// `session.history` read is.
  ///
  /// The transcript view uses this to show a loading state instead of the
  /// "new conversation" empty state, because a long conversation can take a
  /// moment to load and "Ask Hermes anything" reads as though the conversation,
  /// and possibly the whole roster, had been lost.
  ///
  /// It deliberately does NOT consult [_sessRefreshPending]. That flag is a
  /// sticky INTENT ("a read is due"), armed by every `sessions.changed`
  /// broadcast, including ones that arrive with no conversation open — where
  /// [_scheduleSessionRefresh] correctly refuses to act on it. Treating intent
  /// as activity left the app spinning on "Loading conversation…" forever after
  /// a cold start (reported: force-close and reopen). Only in-flight work
  /// counts, and both flags below are cleared in a `finally`, so the state
  /// cannot outlive the request that produced it.
  bool get awaitingTranscript =>
      _messages.isEmpty && (_loadingSession || _sessRefreshInFlight);
  String? _activeStoredSessionId;
  String? get activeStoredSessionId => _activeStoredSessionId;
  String? _activeSessionId;
  String? get activeSessionId => _activeSessionId;

  // Transcript of the active session.
  final List<ChatMessage> _messages = [];

  /// Bumped whenever the TRANSCRIPT ITSELF is replaced or reordered rather than
  /// appended to: a rehydrate, a resume, a session switch, a delete.
  ///
  /// The view needs to tell "the newest end grew", which the read-hold
  /// compensates for by moving the reader's offset, from "the list under the
  /// reader was replaced", where moving them is a jump to somewhere else in the
  /// conversation. Measured: a parked reader at offset 2500 was thrown to 9978
  /// (of 12851) by a silent rehydrate, exactly twice the extent change because
  /// the compensation applied once per layout pass.
  int _transcriptEpoch = 0;

  /// See [_transcriptEpoch].
  int get transcriptEpoch => _transcriptEpoch;
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  bool _streaming = false;
  bool get streaming => _streaming;

  /// Test seam: drive the optimistic streaming flag directly. Production code
  /// only ever sets [streaming] through send/interrupt/event paths.
  @visibleForTesting
  set streamingForTest(bool v) {
    if (_streaming != v) {
      _streaming = v;
      _notify();
    }
  }
  bool _creatingSession = false;
  bool get creatingSession => _creatingSession;

  // ── Authoritative turn state (stuck-working fix) ───────────────────
  // The local [streaming] flag is optimistic — it goes true on send and
  // clears on message.complete. If a terminal event is lost (socket blip,
  // gateway restart, another client's /interrupt), it stays true forever:
  // the UI then shows "working" with a dead Stop button. So the store
  // reconciles against the gateway's session.active_list `status` field
  // (idle/working/waiting/starting) — the same authoritative source the
  // desktop's sidebar dots use — and drops the local flag when the gateway
  // says the turn is not running.
  //
  // Reconciliation is EVENT-DRIVEN, not a poll: a finished turn always
  // writes the session DB (final message persistence), and the gateway's
  // change watcher broadcasts `sessions.changed` within ~500ms of any such
  // write. That broadcast — plus reconnects and interrupts — is the
  // heartbeat that re-checks the authoritative status. A turn that is
  // genuinely still running never needs checking (the local flag is
  // already correct), and a lost terminal event is repaired by the next
  // `sessions.changed` for the session that just ended. No timers, no
  // steady-state polling cost.
  bool _interrupting = false;
  bool get interrupting => _interrupting;
  int _lastStatusPollAt = 0;
  String _lastGatewayStatus = '';

  /// Per-session dot state keyed by stored session id (see [SessionDotState]).
  final Map<String, String> _sessionDotStates = {};
  Map<String, String> get sessionDotStates => Map.unmodifiable(_sessionDotStates);

  /// Resolve the dot state for a session id, falling back to `idle`.
  String sessionDotState(String? storedId) {
    if (storedId == null || storedId.isEmpty) return 'idle';
    return _sessionDotStates[storedId] ?? 'idle';
  }

  /// Dot state of the ACTIVE conversation, resolving live streaming and
  /// pending-attention state on top of the last gateway-reported status.
  String get activeSessionState {
    if (_pendingRequest != null) return 'needs-input';
    if (_streaming) return 'working';
    if (_activeSessionId != null && _activeStoredSessionId == null) return 'draft';
    switch (_lastGatewayStatus) {
      case 'waiting':
        return 'needs-input';
      case 'working':
        return 'working';
      case 'starting':
        return 'working';
      case 'stalled':
        return 'stalled';
      default:
        return _activeStoredSessionId != null ? 'idle' : 'draft';
    }
  }

  /// Gateway-reported status of the active live session (idle/working/
  /// waiting/starting), empty when unknown or the session is not live in
  /// the gateway process (e.g. a fresh draft).
  String get lastGatewayStatus => _lastGatewayStatus;

  String _statusLine = '';
  String get statusLine => _statusLine;

  /// True while the gateway is rewriting this session's history for a
  /// compression request. Armed when a request is accepted (or when the
  /// gateway's own `compressing` status arrives) and disarmed on
  /// `compressed`/`compacted`/`ready`. Guards the start acknowledgement so it
  /// can fire at most once per compression.
  bool _compressing = false;
  bool get compressing => _compressing;

  /// Tell the user a compression has STARTED. The finish toast already exists
  /// (the `compressSession` result SnackBar), but the in-flight window was
  /// silent: `session.compress` blocks until the rewrite completes, and the
  /// gateway only streams a `compressing` status line when there are 4 or
  /// more messages (which then appears only in the status pill, easy to miss).
  /// [detail] is the gateway's own status text when we already have it.
  void _announceCompressionStart({String? detail}) {
    if (_compressing) return;
    _compressing = true;
    if (!_notices.isClosed) {
      _notices.add(detail != null && detail.trim().isNotEmpty
          ? detail.trim()
          : 'Compressing conversation…');
    }
  }

  /// `status.update` kinds worth showing in the transcript's status pill.
  /// The gateway also relays the agent's internal narration as kind
  /// `lifecycle` ("Session is free; loading the latest transcript…",
  /// recall/compaction bookkeeping) — desktop parity keeps that out of the
  /// transcript, and during a thinking turn it otherwise scrolled irrelevant
  /// text in the bottom pill for the entire turn. Compaction / background
  /// process / goal / loop notices DO matter, so those stay.
  static const Set<String> _meaningfulStatusKinds = {
    'compacting',
    'compressed',
    'compacted',
    'compressing',
    'process',
    'goal',
    'loop',
    'warn',
    'error',
  };

  /// True while the gateway is rewriting this session's history (context
  /// compaction). A `session.history` read taken mid-rewrite can come back
  /// short or empty, so transcript pulls are DEFERRED until the compaction
  /// reports done. A read taken during that window used to blank the
  /// transcript on screen for the rest of the turn.
  bool _compacting = false;

  final StreamController<String> _notices =
      StreamController<String>.broadcast(sync: true);

  /// Current context-window occupancy for the active session, as reported by
  /// the gateway's usage payload. Stays [ContextUsage.unknown] until the
  /// gateway reports a real reading, so the app bar shows nothing rather than
  /// a fabricated 0%.
  ContextUsage _context = ContextUsage.unknown;
  ContextUsage get contextUsage => _context;

  /// Full breakdown (category slices plus the model window) behind the
  /// context meter. Null until a reading arrives, so the meter renders
  /// nothing rather than inventing a bar.
  ContextBreakdown? _breakdown;

  /// Compact app-bar label (`24.5k/128k`), or null when unknown.
  String? get contextLabel => _context.label;

  /// The breakdown behind the meter, or null when the gateway has not
  /// reported one.
  ContextBreakdown? get contextBreakdown => _breakdown;

  /// The live gateway client. A screen that needs a one-off config call
  /// reuses this socket instead of opening a second connection to the
  /// same gateway.
  GatewayClient get client => _client;

  /// The gateway reports usage in two shapes: nested under `usage` on
  /// `session.info` and `message.complete`, and flat on a `session.usage`
  /// reply or event. Accept either.
  static ContextUsage _usageFrom(Map<String, dynamic> payload) {
    final nested = payload['usage'];
    if (nested is Map) return ContextUsage.fromUsage(nested);
    return ContextUsage.fromUsage(payload);
  }

  /// Pull the authoritative usage once per (re)attach, so the readout is live
  /// before the first turn of a reopened conversation ends. Best-effort: the
  /// push sources (session.info, message.complete) cover a gateway that does
  /// not expose the request.
  Future<void> _refreshContextUsage() async {
    final sid = _activeSessionId;
    if (sid == null || sid.isEmpty) return;
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('session.usage', {'session_id': sid});
      if (_disposed || _activeSessionId != sid) return;
      final next = ContextUsage.fromUsage(res);
      if (next != _context) {
        _context = next;
        _notify();
      }
    } catch (_) {
      // Best-effort; the event sources fill this in on the next turn.
    }
  }

  /// Reads the category breakdown on demand. The sheet that shows it is the
  /// only consumer, so the ordinary turn path makes no extra round trip and a
  /// gateway that does not expose the method simply yields an empty meter.
  Future<ContextBreakdown> loadContextBreakdown() async {
    final sid = _activeSessionId;
    if (sid == null ||
        sid.isEmpty ||
        _client.state != GwConnectionState.open) {
      return _breakdown ?? ContextBreakdown.empty;
    }
    try {
      final raw =
          await _client.request('session.context_breakdown', {'session_id': sid});
      if (_disposed || _activeSessionId != sid) {
        return _breakdown ?? ContextBreakdown.empty;
      }
      final next = ContextBreakdown.fromPayload(raw);
      if (next.hasData || _breakdown != null) {
        _breakdown = next;
        _notify();
      }
      return next;
    } catch (_) {
      // An empty meter beats a guessed one.
      return _breakdown ?? ContextBreakdown.empty;
    }
  }

  /// Transient, user-facing FAILURE notices.
  ///
  /// The transcript's trailing gray pill carried these, and it is gone: it
  /// mostly showed the agent's internal chatter and got stuck on "Using
  /// terminal…" for a whole turn (reported 2026-09-16). Failures must not
  /// become silent with it, so they ride a SnackBar instead.
  Stream<String> get notices => _notices.stream;

  /// Notification body for a pending request: an approval shows its command, a
  /// batch clarify shows its first question plus a count (the card below the
  /// transcript carries the full form).
  static String _requestSummary(GatewayEvent ev) {
    final p = ev.payload;
    if (ev.type == 'approval.request') {
      return p['command']?.toString() ?? 'Approve this action';
    }
    final batch = p['questions'];
    if (batch is List && batch.isNotEmpty) {
      final first = batch.first;
      final text = first is Map
          ? (first['question'] ?? 'Answer the questions').toString()
          : 'Answer the questions';
      return batch.length > 1 ? '$text (+${batch.length - 1} more)' : text;
    }
    return p['question']?.toString() ?? 'Answer the question';
  }

  /// Record a user-facing failure: keep it in [statusLine] (widely read) and
  /// raise it on [notices] so the UI can show it.
  void _fail(String message) {
    _statusLine = message;
    if (!_notices.isClosed) _notices.add(message);
    _notify();
  }

  // ── Persistent long-horizon goal (composer status parity) ─────────
  // A `/goal <text>` goal persists across many turns. Its live state is read
  // on demand via the read-only `slash.exec {command:'goal status'}` RPC and
  // parsed into [activeGoal] — the same mechanism and output strings the
  // Hermes desktop uses. The transcript renders it as a persistent bar above
  // the composer. Goal state is per-active-session and is cleared on a
  // conversation switch (each session has its own goal).
  GoalStatus? _activeGoal;
  GoalStatus? get activeGoal => _activeGoal;

  /// Serialize concurrent `goal status` pulls so a slow response can never
  /// overwrite a fresher one.
  Future<void>? _goalRefreshInFlight;

  /// Best-effort refresh of the active session's goal bar. Returns immediately
  /// (and no-ops) when there is no live session. Swallows all errors: an
  /// older gateway without `/goal status`, a transport blip, or a draft
  /// session simply leaves the bar unchanged.
  Future<void> refreshGoal() async {
    final sid = _activeSessionId;
    if (sid == null || sid.isEmpty || _loadingSession) return;
    if (_client.state != GwConnectionState.open) return;
    // Coalesce: reuse an in-flight pull so a burst of triggers (session switch
    // + turn end + /goal) doesn't fan out into many parallel RPCs.
    final inFlight = _goalRefreshInFlight;
    if (inFlight != null) return inFlight;
    final fut = _doRefreshGoal(sid);
    _goalRefreshInFlight = fut;
    try {
      await fut;
    } finally {
      _goalRefreshInFlight = null;
    }
  }

  Future<void> _doRefreshGoal(String sid) async {
    try {
      final res = await _client.request('slash.exec',
          {'session_id': sid, 'command': 'goal status'});
      if (_disposed || sid != _activeSessionId) return; // stale after a switch
      final output = (res['output'] ?? '').toString();
      final result = parseGoalStatusText(output);
      if (result is GoalParseNone) {
        // No goal / cleared — reflect that (drop the bar if one is showing).
        if (_activeGoal != null) {
          _activeGoal = null;
          _notify();
        }
      } else if (result is GoalParseValue) {
        // Reflect the gateway's current goal, whatever its state. A `done`
        // goal stays visible (green "done") until the user dismisses it with
        // the bar's X button (which sends `/goal clear`) — the bar is an
        // honest mirror of the gateway, and dismissing it is an explicit act.
        final goal = result.goal;
        final cur = _activeGoal;
        if (cur == null ||
            cur.title != goal.title ||
            cur.status != goal.status ||
            cur.detail != goal.detail) {
          _activeGoal = goal;
          _notify();
        }
      }
      // GoalParseUnchanged: keep the previous state (unrecognized line).
    } catch (_) {
      // Best-effort: never surface a goal-fetch failure as an error state.
    }
  }

  /// Dismiss the goal bar: send `/goal clear` to the gateway (the authoritative
  /// action — the gateway keeps a finished goal around until it's cleared, so
  /// this is what actually makes it go away) and drop the local bar. The
  /// command runs immediately (dispatch) even mid-turn.
  Future<void> dismissGoal() async {
    final sid = _activeSessionId;
    if (sid == null || sid.isEmpty) return;
    // Drop the bar now (optimistic) so the X responds instantly.
    if (_activeGoal != null) {
      _activeGoal = null;
      _notify();
    }
    try {
      await _client
          .request('slash.exec', {'session_id': sid, 'command': 'goal clear'});
    } catch (_) {
      // Best-effort. If it failed, the next refresh will restore the bar.
    }
  }

  /// Drop the goal bar (used on conversation switch). Idempotent; notifies
  /// only on change.
  void clearGoal() {
    if (_activeGoal != null) {
      _activeGoal = null;
      _notify();
    }
  }

  /// Test seam: install a goal directly without a gateway round-trip, so the
  /// goal bar UI can be exercised in isolation. Production code only sets the
  /// goal through [refreshGoal]/[clearGoal].
  @visibleForTesting
  void setGoalForTest(GoalStatus? goal) {
    _activeGoal = goal;
    _notify();
  }

  // ── Pinned conversations (client-side preference) ─────────────────
  // The gateway has a DB-level pin column but does NOT expose a `session.pin`
  // RPC over the wire, and the `session.list` row does not carry a `pinned`
  // flag. So pinning is a per-client preference, persisted in the app
  // (keyed to the gateway host, like the model-picker bookmarks). The store
  // owns the pure set + ordering logic (unit-testable, no SharedPreferences);
  // the Sessions sheet loads/saves the actual prefs and mirrors them here.
  final Set<String> _pinned = {};
  Set<String> get pinnedIds => Set.unmodifiable(_pinned);

  /// True when the conversation with stored id [id] is pinned to the top.
  bool isPinned(String id) => _pinned.contains(id);

  /// Add every id in [ids] to the pinned set (used to hydrate the in-memory
  /// set from the persisted prefs). Idempotent; notifies only on change.
  void applyPinned(Iterable<String> ids, {bool clear = false}) {
    if (clear) _pinned.clear();
    final before = _pinned.length;
    for (final id in ids) {
      if (id.isNotEmpty) _pinned.add(id);
    }
    if (_pinned.length != before) _notify();
  }

  /// Toggle the pinned state of the conversation with stored id [id].
  /// Returns the new pinned state. Pure (no I/O); the caller persists.
  bool togglePin(String id) {
    final now = _pinned.contains(id) ? false : true;
    if (now) {
      _pinned.add(id);
    } else {
      _pinned.remove(id);
    }
    _notify();
    return now;
  }

  // ── Roster segmentation (pinned + time buckets) ───────────────────
  /// Time-bucket label for a conversation's [unixSeconds], or null when it
  /// has no timestamp (those rows fall into 'Older').
  static String? _rosterTimeBucket(double unixSeconds) {
    if (unixSeconds <= 0) return null;
    final d = DateTime.fromMillisecondsSinceEpoch((unixSeconds * 1000).round());
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final days = today.difference(that).inDays;
    if (days < 0) return 'Today'; // clock skew guard — treat as current
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days <= 7) return 'This week';
    if (days <= 31) return 'This month';
    return 'Older';
  }

  /// Order the stored-session roster into display segments: the PINNED group
  /// first (most recent first, the gateway's own order), then one segment per
  /// time bucket in newest-first order (Today, Yesterday, This week, This
  /// month, Older), each preserving the gateway's most-recent-first order.
  /// Pure and side-effect free — safe to call every build.
  List<RosterSegment> segmentedSessions(List<SessionRow> sessions) {
    final pinnedRows = <SessionRow>[];
    final byBucket = <String, List<SessionRow>>{
      'Today': [],
      'Yesterday': [],
      'This week': [],
      'This month': [],
      'Older': [],
    };
    for (final s in sessions) {
      if (_pinned.contains(s.id)) {
        pinnedRows.add(s);
        continue;
      }
      final bucket = _rosterTimeBucket(s.startedAt) ?? 'Older';
      byBucket[bucket]!.add(s);
    }
    final out = <RosterSegment>[];
    if (pinnedRows.isNotEmpty) out.add(RosterSegment('', pinnedRows));
    for (final label in byBucket.keys) {
      final rows = byBucket[label]!;
      if (rows.isNotEmpty) out.add(RosterSegment(label, rows));
    }
    return out;
  }

  // Models / profiles (Settings)
  List<ModelOption> _models = [];
  List<ModelOption> get models => List.unmodifiable(_models);

  // ── Live "current model" tracking ─────────────────────────────────
  // The gateway bakes `is_current` into model.options ONCE at load time, and
  // `config.set model` returns only {key, value} (no provider). So the picker
  // recomputes the checkmark live from these fields instead of trusting the
  // frozen ModelOption.isCurrent — which is why the old checkmark never moved
  // after a switch. [currentModelSlug]/[currentModelProvider] are the bare
  // slug + provider of the model actually in use right now.
  String _currentModel = '';
  String get currentModel => _currentModel;
  String _currentModelSlug = '';
  String get currentModelSlug => _currentModelSlug;
  String _currentModelProvider = '';
  String get currentModelProvider => _currentModelProvider;

  /// Split a bare model reference (e.g. `gpt-4o` or `vendor/model`) into
  /// (providerSlug, modelSlug). Empty provider when there is no `/` prefix.
  static ({String slug, String provider}) splitModelRef(String ref) {
    final i = ref.indexOf('/');
    if (i <= 0) return (slug: ref, provider: '');
    return (provider: ref.substring(0, i), slug: ref.substring(i + 1));
  }

  /// The picker's identity key for a model row (`provider:slug`). Used as the
  /// bookmark key so the same model under two providers stays distinct.
  String modelKey(ModelOption m) => '${m.provider ?? ''}:${m.slug}';

  /// The live model identity of the current row. The picker uses this to mark
  /// the checkmark (and pin the current group), so it follows `setModel` and
  /// gateway `session.info` updates.
  bool modelIsCurrent(ModelOption m) {
    if (m.bare.isEmpty) return false;
    if (_currentModelSlug.isEmpty) return m.isCurrent;
    if (m.bare != _currentModelSlug) return false;
    final p = m.provider ?? '';
    return _currentModelProvider.isEmpty || p == _currentModelProvider;
  }

  /// A provider group is "current" when it contains the live model.
  bool providerIsCurrent(ProviderGroup g) => g.models.any(modelIsCurrent);

  /// Set the live current-model identity from a gateway `session.info` /
  /// resume `info` (model + provider). Falls back to splitting the model ref
  /// when no provider is supplied.
  void setLiveModel(String model, {String? provider}) {
    final bare = model.trim();
    _currentModel = bare;
    final p = (provider ?? '').trim();
    if (p.isNotEmpty) {
      _currentModelProvider = p;
      // Strip the `provider/` prefix when the provider is known, so the
      // slug matches the ModelOption.bare that the gateway built from the
      // per-provider model list.
      final prefix = '$p/';
      _currentModelSlug =
          bare.startsWith(prefix) ? bare.substring(prefix.length) : bare;
    } else {
      final split = splitModelRef(bare);
      _currentModelProvider = split.provider;
      _currentModelSlug = split.slug;
    }
    _notify();
  }

  // ── Live model quick-config (header popover) ──────────────────────
  // The gateway's `session.info` payload carries the session's effective
  // `reasoning_effort` ('' = profile default, 'none' = thinking off, or a
  // level), and `config.get fast` reports the service tier. The header's
  // model-name menu edits these LIVE (session-scoped config.set), which
  // applies to the next turn immediately — no restart, no settings round-trip.
  static const reasoningLevels =
      ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
  static const defaultReasoningEffort = 'medium';
  String _reasoningEffort = '';
  String get reasoningEffort => _reasoningEffort;
  bool get thinkingEnabled =>
      _reasoningEffort.isNotEmpty && _reasoningEffort != 'none';
  String _fastMode = '';
  String get fastMode => _fastMode;

  /// The gateway's `config.get fast` reports `'fast'` (priority tier) or
  /// `'normal'`; session.info echoes `service_tier: 'priority'|''`. Both are
  /// normalized to this vocabulary here.
  bool get fastEnabled => _fastMode == 'fast';
  bool _modelConfigLoaded = false;

  /// Whether reasoning traces are shown at all (the gateway `reasoning`
  /// DISPLAY switch, independent of whether the model actually thinks). The
  /// Settings "reasoning" toggle is this knob: `hide` collapses every trace
  /// out of the view. Default is show. Distinct from [reasoningEffort], which
  /// decides if/ how much the model thinks.
  bool _showReasoning = true;
  bool get showReasoning => _showReasoning;

  /// Fresh read of the reasoning DISPLAY switch (show/hide). Called when the
  /// model quick-config opens so the trace-visibility reflects the live value
  /// (loadModelConfig is one-shot and only reads the effort).
  Future<void> refreshReasoningDisplay() async {
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('config.get', {
        'key': 'reasoning',
        'session_id': _activeSessionId ?? '',
      });
      final d = (res['display'] ?? '').toString();
      final visible = d != 'hide';
      if (visible != _showReasoning) {
        _setShowReasoning(visible);
        if (!_disposed) _notify();
      }
    } catch (_) {
      // Best-effort: keep the current value.
    }
  }

  /// Sticky "this transcript was just (re)opened — scroll to the newest
  /// message" flag consumed by the conversation view.
  ///
  /// It is STICKY on purpose: the jump can only happen after the transcript is
  /// actually hydrated and laid out, and hydration arrives in a LATER
  /// notification than the one that flips the session id (resume returns the
  /// session id, clears the transcript, hydrates, THEN notifies). A one-shot
  /// per-session-id trigger measured a still-empty list (maxScrollExtent 0),
  /// no-oped, and was never retried — which is why reopened conversations
  /// landed at the top instead of the last message. The UI consumes the flag
  /// on the first notification where the list actually has scrollable content;
  /// until then every later notification retries it. A fresh conversation
  /// (empty transcript) consumes it immediately.
  bool _pendingJumpToBottom = false;
  bool get pendingJumpToBottom => _pendingJumpToBottom;

  /// The UI calls this after performing (or intentionally skipping) the jump.
  void consumeJumpToBottom() {
    if (_pendingJumpToBottom) {
      _pendingJumpToBottom = false;
    }
  }

  @visibleForTesting
  set reasoningEffortForTest(String v) {
    _reasoningEffort = v;
    _notify();
  }

  @visibleForTesting
  void resetModelConfigLoadedForTest() {
    _modelConfigLoaded = false;
  }

  /// Pull the session's live thinking/fast config. Fire-and-forget; the menu
  /// renders '—' placeholders until the first read lands.
  ///
  /// `config.get reasoning` returns `{value: <effort>, display: show|hide}` —
  /// the EFFORT (minimal/low/medium/high/xhigh/max/ultra/none) is in `value`;
  /// `display` is the separate show/hide visibility switch. The generic
  /// `configGet` helper prefers `display`, which would be wrong here, so read
  /// the raw value directly.
  Future<void> loadModelConfig() async {
    if (_modelConfigLoaded) return;
    _modelConfigLoaded = true;
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('config.get', {
        'key': 'reasoning',
        'session_id': _activeSessionId ?? '',
      });
      final v = res['value'];
      if (v is String && v.isNotEmpty) _reasoningEffort = v;
      // Also seed the trace-visibility (display: show/hide) so the first open
      // of the menu reflects whether traces are currently shown.
      final d = (res['display'] ?? '').toString();
      if (d.isNotEmpty) _setShowReasoning(d != 'hide');
      final f = await _client.request('config.get', {
        'key': 'fast',
        'session_id': _activeSessionId ?? '',
      });
      final fv = (f['value'] ?? f['display'])?.toString() ?? '';
      if (fv.isNotEmpty) _fastMode = fv;
    } catch (_) {
      // Best-effort: the session.info echo will correct these live anyway.
    }
    if (!_disposed) _notify();
  }

  /// Re-read the `reasoning` config authoritatively and refresh BOTH local
  /// mirrors: [reasoningEffort] (the `value`, = the model's thinking level) and
  /// [showReasoning] (the `display`, = whether traces render). Used after any
  /// `config.set reasoning` so a quick-config effort change and a Settings
  /// display change can't desync the two, and the transcript updates live.
  Future<void> _resyncReasoning() async {
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('config.get', {
        'key': 'reasoning',
        'session_id': _activeSessionId ?? '',
      });
      final v = res['value'];
      if (v is String) {
        final effort = v.isEmpty ? '' : v;
        if (effort != _reasoningEffort) _reasoningEffort = effort;
      }
      final d = (res['display'] ?? '').toString();
      if (d.isNotEmpty) _setShowReasoning(d != 'hide');
    } catch (_) {
      // Best-effort: the session.info echo keeps the effort mirror live too.
    }
  }

  /// Toggle trace VISIBILITY (the gateway `reasoning` display switch:
  /// `config.set reasoning show|hide`). Distinct from [setReasoning], which
  /// sets the effort level (whether the model thinks at all). The gateway
  /// writes `display.show_reasoning` (global) AND the active session's
  /// `show_reasoning`, then reports back the normalized word. The store
  /// mirrors it locally immediately and re-reads authoritatively (via
  /// [_resyncReasoning]) so the transcript re-derives every message's
  /// `effectiveReasoning` live. Display-only: the raw trace text always stays
  /// in `ChatMessage.reasoning`, so hiding never destroys anything and
  /// re-showing restores every trace.
  Future<String> setReasoningDisplay(bool show) async {
    _setShowReasoning(show);
    _notify();
    return configSet('reasoning', show ? 'show' : 'hide');
  }

  /// Set the session's reasoning effort ('' = profile default, 'none' =
  /// thinking off, or one of [reasoningLevels]). Session-scoped: the
  /// gateway's `config.set reasoning` writes the session runtime, applies it
  /// to the live agent for the NEXT turn, and emits a `session.info` echo.
  Future<String> setReasoning(String level) async {
    _reasoningEffort = level;
    _notify();
    return configSet('reasoning', level);
  }

  /// Toggle fast (priority service tier) on or off, session-scoped.
  Future<String> setFast(bool enabled) async {
    // Normalized local vocabulary: 'fast' on, 'normal' off (config.get fast
    // reports these; fastEnabled compares against 'fast').
    _fastMode = enabled ? 'fast' : 'normal';
    _notify();
    return configSet('fast', enabled ? 'fast' : 'normal');
  }

  // ── Picker UI persistence (bookmarks + open/closed state) ─────────
  // Stored per connected gateway so different gateways keep separate picker
  // layouts. Keyed by the gateway base URL (not the credential path, which
  // can differ across hosts).
  static const _pfx = 'talaria.modelpicker.';
  String _pickerKey = '';
  Future<SharedPreferences> _prefs() async {
    // Key the picker state to the gateway host so different gateways keep
    // separate bookmarks and layouts.
    final host = Uri.tryParse(config.baseUrl)?.host ?? config.baseUrl.trim();
    _pickerKey = '$_pfx$host.';
    return SharedPreferences.getInstance();
  }

  final Set<String> _bookmarked = {};
  Set<String> get bookmarked => Set.unmodifiable(_bookmarked);
  final Set<String> _collapsedProviders = {};
  Set<String> get collapsedProviders => Set.unmodifiable(_collapsedProviders);
  bool _pickerPrefsLoaded = false;
  bool _pickerPrefsLoading = false;
  int _bookmarkRevision = 0;
  int _collapseRevision = 0;

  /// Load the picker's persisted bookmarks + collapsed-state for this gateway.
  /// Best-effort: a missing/corrupt preference file simply yields a fresh
  /// picker. Idempotent (a second call is a no-op once loaded).
  Future<void> loadPickerState() async {
    if (_pickerPrefsLoaded || _pickerPrefsLoading) return;
    _pickerPrefsLoading = true;
    final bookmarkRevision = _bookmarkRevision;
    final collapseRevision = _collapseRevision;
    try {
      final prefs = await _prefs();
      final bm = prefs.getStringList('${_pickerKey}bookmarks') ?? const [];
      if (bookmarkRevision == _bookmarkRevision) {
        _bookmarked
          ..clear()
          ..addAll(bm);
      }
      final col = prefs.getStringList('${_pickerKey}collapsed') ?? const [];
      if (collapseRevision == _collapseRevision) {
        _collapsedProviders
          ..clear()
          ..addAll(col);
      }
      _pickerPrefsLoaded = true;
    } catch (_) {
      // Persistence is best-effort; keep any in-memory choices intact.
    } finally {
      _pickerPrefsLoading = false;
      _notify();
    }
  }

  Future<void> _savePickerPrefs() async {
    try {
      final prefs = await _prefs();
      await prefs.setStringList('${_pickerKey}bookmarks', _bookmarked.toList());
      await prefs.setStringList(
          '${_pickerKey}collapsed', _collapsedProviders.toList());
    } catch (_) {
      // Persistence is best-effort; the in-memory state is the source of truth.
    }
  }

  /// Bookmark (or un-bookmark) a model by `provider:slug` key. Bookmarked
  /// models float to the top of the picker, above every provider group.
  void toggleBookmark(String modelKey) {
    _bookmarkRevision++;
    if (_bookmarked.contains(modelKey)) {
      _bookmarked.remove(modelKey);
    } else {
      _bookmarked.add(modelKey);
    }
    unawaited(_savePickerPrefs());
    _notify();
  }

  /// Remember whether a provider category is collapsed. `null` means "default
  /// (open)". Persisted so the picker restores the user's layout on return.
  void setProviderCollapsed(String providerSlug, bool collapsed) {
    _collapseRevision++;
    if (collapsed) {
      _collapsedProviders.add(providerSlug);
    } else {
      _collapsedProviders.remove(providerSlug);
    }
    unawaited(_savePickerPrefs());
    _notify();
  }

  bool isProviderCollapsed(String providerSlug) =>
      _collapsedProviders.contains(providerSlug);

  /// Models the user bookmarked, in bookmark order (top-to-bottom).
  List<ModelOption> get bookmarkedModels {
    final byKey = {for (final m in _models) '${m.provider ?? ''}:${m.slug}': m};
    final out = <ModelOption>[];
    for (final k in _bookmarked) {
      final m = byKey[k];
      if (m != null) out.add(m);
    }
    return out;
  }

  /// Models grouped by provider, with the live-current group pinned to the
  /// top and first-seen order preserved for the rest. Powers the settings'
  /// per-provider collapsible categories (a flat list is hard to navigate once
  /// several providers are linked).
  List<ProviderGroup> get providerGroups {
    final bySlug = <String, ProviderGroup>{};
    final order = <String>[];
    for (final m in _models) {
      final key = (m.provider?.isNotEmpty ?? false) ? m.provider! : '_default';
      ProviderGroup? g = bySlug[key];
      if (g == null) {
        g = ProviderGroup(
          slug: key == '_default' ? 'models' : key,
          name: (m.providerName?.isNotEmpty ?? false)
              ? m.providerName!
              : (key == '_default' ? 'Models' : key),
          models: [],
        );
        bySlug[key] = g;
        order.add(key);
      }
      g.models.add(m);
    }
    final groups = order.map((k) => bySlug[k]!).toList();
    // Pin the live-current group to the top so the active model is visible
    // first, keeping first-seen order for the rest. A stable partition (NOT
    // List.sort, which is unstable in Dart and would reshuffle non-current
    // providers non-deterministically).
    final currentGroups = groups.where(providerIsCurrent).toList();
    final rest = groups.where((g) => !providerIsCurrent(g)).toList();
    return [...currentGroups, ...rest];
  }

  List<ProfileInfo> _profiles = [];
  List<ProfileInfo> get profiles => List.unmodifiable(_profiles);

  StreamSubscription<GatewayEvent>? _eventSub;
  bool _disposed = false;

  // ── Connection ─────────────────────────────────────────────────────

  Future<ProbeResult> probe() => _http.testConnection();

  Future<void> connect() async {
    _connectError = null;
    notifyListeners();
    try {
      await _client.connect();
      // Pull the session roster for the picker, then start on a FRESH
      // conversation by default. The old behavior auto-resumed the most
      // recent stored session, which made the app open to a stale
      // conversation on first launch and re-open the same one whenever a
      // backgrounded socket reconnected. Past sessions remain one tap
      // away in the Sessions sheet.
      await loadSessions();
      final res = await _client.request(
          'session.create', {'close_on_disconnect': false, 'hidden': false});
      final sid = res['session_id'] as String? ?? '';
      if (sid.isEmpty) {
        // Gateway returned no id (e.g. transient); fall back to a local
        // draft so the composer still works and the first prompt lazily
        // creates the session.
        await _newSessionDraft();
        return;
      }
      _activeSessionId = sid;
      _verifiedLiveSessionId = sid;
      _activeStoredSessionId = null;
      _messages.clear();
      _transcriptEpoch++;
      _streaming = false;
      _statusLine = '';
      _resetTrackedStatus();
      // Keep the process alive so an idle backgrounded socket is not torn
      // down by the OS (the foreground service is the keep-alive, not a
      // turn lifetime).
      unawaited(_fg.start());
      if (!_disposed) notifyListeners();
    } catch (e) {
      _connectError = e.toString();
      _conn = GwConnectionState.error;
      notifyListeners();
      rethrow;
    }
  }

  void _onState(GwConnectionState s) {
    _conn = s;
    if (s == GwConnectionState.reconnecting) {
      _streaming = false;
      _statusLine = 'Connection lost — reconnecting…';
      _recovered = true;
    }
    if (s == GwConnectionState.open && _recovered) {
      // Came back after a reconnect: refresh the roster and keep the process
      // alive. Deliberately does NOT re-resume the active session — re-running
      // session.resume on every reconnect is what made the app snap back to a
      // stale conversation after backgrounding. The current conversation is
      // preserved (its live session id still exists on the gateway), and any
      // events missed while offline are re-delivered by the replay watermark.
      _recovered = false;
      unawaited(_reloadAfterReconnect());
    }
    if (s == GwConnectionState.closed) {
      // Manual teardown (user disconnect / dispose): drop the keep-alive.
      _streaming = false;
      _statusLine = '';
      unawaited(_fg.stop());
    } else if (s == GwConnectionState.error) {
      // Transient dial failure during a reconnect episode. Keep the process
      // alive so the backoff retry can recover the socket in the background;
      // the keep-alive foreground service must NOT be dropped here.
      _streaming = false;
    }
    if (s != GwConnectionState.open) {
      // A dropped socket detaches the runtime id on the gateway, so the id we
      // were handed is no longer evidence of a live session.
      _verifiedLiveSessionId = null;
    }
    if (s == GwConnectionState.open) {
      // Global sessions.changed frames have no replay watermark. If another
      // client committed while this socket was offline, force one read-only
      // history refresh when the connection recovers.
      if (_activeSessionId != null) _sessRefreshPending = true;
      _scheduleSessionRefresh();
      // A turn may have been running while the socket was down (another
      // client's turn, or this one's events replayed): reconcile the local
      // streaming flag against the authoritative status right away.
      _lastStatusPollAt = 0;
      unawaited(reconcileActiveTurnStatus());
    }
    if (!_disposed) notifyListeners();
  }

  bool _recovered = false;

  Future<void> _reloadAfterReconnect() async {
    if (_client.state != GwConnectionState.open) return;
    // The socket is back: clear the reconnect banner. It was set on the
    // `reconnecting` transition and never cleared before, so a recovered
    // view could show "Connected" in the header and "Connection lost —
    // reconnecting…" at the bottom of the transcript at the same time.
    _statusLine = '';
    await loadSessions();
    // Keep the socket alive while the app is backgrounded.
    unawaited(_fg.start());
    if (!_disposed) notifyListeners();
  }

  /// The gateway DETACHES a session's runtime when a client's WebSocket
  /// disconnects and orphans/reaps it shortly after (server.py `_sess_nowait`
  /// documents the protocol: a stale runtime id gets 4001 "session not found"
  /// and "the client should session.resume the STORED id"). After a
  /// backgrounded phone reconnects, the store's `_activeSessionId` is
  /// typically exactly such a stale id — the transcript still shows the
  /// reloaded conversation, but every runtime-scoped RPC (prompt.submit,
  /// session.active_list, session.interrupt) is rejected until this recovery
  /// re-attaches it under a fresh runtime id.
  ///
  /// Silent on purpose: this is plumbing, not a user navigation — the
  /// transcript must not flash a reload spinner or re-jump. The resume's
  /// `pendingJumpToBottom` is consumed immediately (the view is already
  /// showing this conversation). Failures are swallowed.
  ///
  /// Throttled: a conversation whose stored session the gateway can no longer
  /// resume must not re-issue an RPC on every reconcile tick (`sessions.changed`
  /// fires ~2/s), so at most one automatic attempt is made per
  /// [_staleRecoveryCooldown].
  static const _staleRecoveryCooldown = Duration(seconds: 10);
  DateTime? _lastStaleRecoveryAt;
  bool _recoveringStale = false;

  bool _staleRecoveryDue() {
    if (_recoveringStale) return false;
    final last = _lastStaleRecoveryAt;
    if (last == null) return true;
    return DateTime.now().difference(last) >= _staleRecoveryCooldown;
  }

  /// Re-attach a stored conversation whose runtime id no longer resolves.
  /// Returns true when a live session was established (or a re-attach is
  /// already in flight and owns it), false when the attempt failed — callers
  /// that MUST have a live session (a model switch) treat false as "cannot
  /// target this conversation" rather than sending a request that the gateway
  /// will answer with a success envelope while applying nothing.
  Future<bool> _recoverStaleActiveSession(String storedId) async {
    if (storedId.isEmpty) return false;
    if (_client.state != GwConnectionState.open) return false;
    // A re-resume in flight (user or previous 4001) already owns the
    // transcript transition — a racing duplicate would clear it twice.
    if (_loadingSession || _recoveringStale || _disposed) return true;
    _recoveringStale = true;
    _lastStaleRecoveryAt = DateTime.now();
    try {
      // resumeSession reports whether it actually established a live session;
      // it handles its own failures, so its return value (not an exception) is
      // the signal a caller needs.
      final ok = await resumeSession(storedId, silent: true);
      _pendingJumpToBottom = false;
      return ok;
    } catch (_) {
      // Best-effort; the cooldown gates the next attempt.
      return false;
    } finally {
      _recoveringStale = false;
    }
  }

  // ── Event wiring ───────────────────────────────────────────────────

  void _wireEvents() {
    _eventSub = _client.events.listen(_onEvent);
  }

  void _onEvent(GatewayEvent ev) {
    // Only events for the active session drive the transcript; session
    // roster events are global.
    final sid = ev.sessionId;
    final isActive = !_loadingSession && sid != null && sid == _activeSessionId;

    switch (ev.type) {
      case 'message.start':
        if (isActive) {
          _ensureAssistantTail();
          _streaming = true;
        }
        break;
      case 'message.delta':
        if (isActive) {
          _ensureAssistantTail().appendText(ev.text);
        }
        break;
      case 'message.interim':
        if (isActive) {
          final m = _ensureAssistantTail();
          final authoritative = ev.text;
          // The interim event carries the authoritative text for the sealed
          // segment. already_streamed=true means the deltas already painted it,
          // so this is a REPLACE of that segment: `setText` targets the last
          // TEXT part even when a `tool.start` for the action it introduced
          // landed in between (appending there printed the sentence twice, once
          // on each side of the tool block). already_streamed=false means the
          // segment was never streamed, so it has to be added. Either way the
          // thinking → tool → text ORDER in m.parts is preserved, so a sealed
          // "thought / action / commentary" round renders in the order it
          // actually happened (round 14 ordering fix).
          // Skip when the prose ALREADY ends with this segment: it is on
          // screen, so adding it again would double it. This also covers any
          // gateway that omits the flag (the desktop has the same guard in
          // `mergeFinalAssistantText`).
          if (authoritative.isNotEmpty && !m.text.endsWith(authoritative)) {
            if (ev.payload['already_streamed'] == true) {
              m.setText(authoritative);
            } else {
              m.appendText(authoritative);
            }
          }
          m.pending = false;
        }
        break;
      case 'message.complete':
        if (isActive) {
          // The turn payload carries the authoritative usage, including the
          // current context occupancy when the engine reports one.
          final nextContext = _usageFrom(ev.payload);
          if (nextContext != _context) {
            _context = nextContext;
          }
          final m = _messages.isEmpty ? null : _messages.last;
          if (m != null && m.role == 'assistant') {
            if (ev.text.isNotEmpty) m.setText(ev.text);
            m.pending = false;
          }
          _finishTurn();
        }
        break;
      case 'thinking.delta':
      case 'reasoning.delta':
        if (isActive) {
          final m = _ensureAssistantTail();
          m.appendReasoning(ev.text);
          m.effectiveReasoning = _showReasoning ? m.reasoning : '';
        }
        break;
      case 'status.update':
        if (isActive) {
          final kind = (ev.payload['kind'] ?? '').toString();
          // Context compaction rewrites this session's history, so a
          // `session.history` read taken while it runs can come back short or
          // empty. Track it and defer transcript pulls until it reports done.
          if (kind == 'compacting' || kind == 'compressing') {
            _compacting = true;
            _sessRefreshPending = true;
            if (kind == 'compressing') {
              // The gateway streams this only when 4+ messages are being
              // rewritten. If the user's request already announced the start,
              // the flag makes this a no-op instead of a second toast.
              _announceCompressionStart(detail: ev.text);
            }
          } else if (kind == 'compacted' || kind == 'compressed') {
            _compacting = false;
            _compressing = false;
            _sessRefreshPending = true;
            _scheduleSessionRefresh();
          }
          // Only MEANINGFUL kinds keep a status line: the agent also relays
          // internal narration ("Session is free; loading the latest
          // transcript…") that the desktop never surfaces.
          if (_meaningfulStatusKinds.contains(kind)) {
            _statusLine = ev.text.isNotEmpty ? ev.text : ev.name;
          }
        }
        break;
      case 'tool.start':
      case 'tool.generating':
        if (isActive) {
          final m = _ensureAssistantTail();
          final t = ToolActivity.fromEvent(ev.payload);
          if (ev.type == 'tool.generating') t.state = ToolState.generated;
          // Deduplicate by tool_id GLOBALLY across the transcript, not just
          // the current message: a re-emitted event (reconnect replay) or a
          // late `tool.generating` for an EARLIER segment's tool must not
          // mint a duplicate chip in the newest segment. If the tool already
          // exists anywhere, drop the re-emit.
          final tid = t.toolId;
          if (tid != null && tid.isNotEmpty && _findToolGlobal(tid) != null) {
            break;
          }
          m.addTool(t);
        }
        break;
      case 'tool.progress':
        if (isActive) {
          final p = ev.text;
          if (p.isNotEmpty) {
            // Locate the tool GLOBALLY by tool_id (not just in the newest
            // message): a progress line can arrive after a `message.interim`
            // has sealed the segment the tool belongs to, so the owner may be
            // an earlier assistant message. A no-id progress falls back to the
            // newest message's last tool.
            final tid = ev.payload['tool_id'] as String?;
            ToolActivity? t;
            if (tid != null && tid.isNotEmpty) {
              t = _findToolGlobal(tid);
            } else {
              final m = _messages.isEmpty ? null : _messages.last;
              t = (m != null && m.tools.isNotEmpty) ? m.tools.last : null;
            }
            if (t != null) t.preview = p;
          }
        }
        break;
      case 'tool.complete':
        if (isActive) {
          // Locate the tool GLOBALLY by tool_id. This is the root cause of the
          // "stuck gray box": a `tool.complete` arriving after a later segment
          // was appended used to search only `_messages.last`, miss the
          // tool, and leave that chip in `running` forever. Searching the whole
          // transcript guarantees the owning (possibly sealed) segment's chip
          // is flipped to done/error.
          final tid = ev.payload['tool_id'] as String?;
          ToolActivity? t;
          if (tid != null && tid.isNotEmpty) {
            t = _findToolGlobal(tid);
          } else {
            final m = _messages.isEmpty ? null : _messages.last;
            t = (m != null && m.tools.isNotEmpty) ? m.tools.last : null;
          }
          if (t != null) {
            // Backend sends error as a string message, not boolean.
            t.state = (ev.payload['error'] != null)
                ? ToolState.error
                : ToolState.done;
            final summary = ev.payload['summary'] as String?;
            if (summary != null) t.summary = summary;
            // A tool that produced or downloaded a picture names it in the
            // result, and the result is what the gateway sends a client. Only
            // fetchable sources are kept, so the row never promises an image
            // this device cannot load.
            final resultImages = fetchableImageSources(ev.payload['result']);
            if (resultImages.isNotEmpty) t.images = resultImages;
            // A tool that produced or downloaded a picture names it in the
            // result, and the result is what the gateway sends a client. Only
            // fetchable sources are kept, so the row never promises an image
            // this device cannot load.
          }
        }
        break;
      case 'todo.updated':
        if (isActive) _statusLine = 'Updating plan…';
        break;
      case 'clarify.request':
      case 'approval.request':
        if (sid == null || sid == _activeSessionId) {
          _pendingRequest = ev;
          _statusLine = 'Waiting for your input…';
          _pushNotification(
            title: 'Hermes needs input',
            body: _requestSummary(ev),
            tag: 'req-${ev.seq ?? _activeSessionId}',
          );
        }
        break;
      case 'clarify.expire':
      case 'approval.expire':
        // The gateway retired the request: its deadline passed, or another
        // client answered it. The desktop handles this; without it the card sat
        // on screen forever, because a reply is rejected as "no pending clarify
        // request" and every resume re-armed the card.
        {
          final expiring = (ev.payload['request_id'] ?? '').toString();
          final current =
              (_pendingRequest?.payload['request_id'] ?? '').toString();
          final sameSid = sid == null || sid == _activeSessionId;
          if (expiring.isNotEmpty && current.isNotEmpty) {
            if (expiring == current) {
              _pendingRequest = null;
              _clarifyAnswers.clear();
            }
          } else if (sameSid) {
            _pendingRequest = null;
            _clarifyAnswers.clear();
          }
        }
        break;
      case 'approval.respond':
      case 'clarify.respond':
        _pendingRequest = null;
        break;
      case 'session.info':
      case 'session.usage':
        if (sid == _activeSessionId) {
          final nextContext = _usageFrom(ev.payload);
          if (nextContext != _context) {
            _context = nextContext;
          }
          final model = ev.payload['model'] as String?;
          if (model != null && model.isNotEmpty) {
            setLiveModel(model,
                provider: ev.payload['provider'] is String
                    ? ev.payload['provider'] as String
                    : null);
          }
          // The session's effective reasoning effort echoes back on every
          // session.info (and after any config.set reasoning): keep the
          // header menu's Thinking state live.
          final effort = ev.payload['reasoning_effort'];
          if (effort is String) {
            if (effort != _reasoningEffort) {
              _reasoningEffort = effort;
              _notify();
            }
          }
        }
        break;
      case 'sessions.changed':
        // Global broadcast: the gateway fires this for EVERY connected
        // client whenever the session DB moves — including turns driven by
        // other clients (desktop, dashboard, CLI), which never push their
        // message.delta events to this socket. This is the only signal the
        // app gets that another client touched a conversation, so debounce
        // and re-pull the active transcript. Our own streaming turn is
        // skipped: its deltas already arrive live, and a mid-stream
        // re-hydrate would clobber the optimistic bubble.
        _onSessionsChanged();
        break;
      case 'error':
        if (isActive) {
          final m = _ensureAssistantTail();
          m.error = ev.text;
          _finishTurn();
        }
        break;
      case 'voice.transcript':
        // Gateway-side VAD push-to-talk finished a capture. Auto-send the
        // transcript into the active session (desktop voice parity). Stop
        // phrases and no-speech limits are control signals, not prompts.
        {
          final stop = ev.payload['stop_phrase'] == true;
          final noSpeech = ev.payload['no_speech_limit'] == true;
          final text = ev.text;
          if (!stop &&
              !noSpeech &&
              text.trim().isNotEmpty &&
              _client.state == GwConnectionState.open) {
            _voiceOn = false;
            unawaited(send(text));
          }
        }
        break;
      default:
        break;
    }
    // Deferred only for the per-character content kinds while the reader is away
    // from the newest end (see _deferContentUpdate). The model is already
    // updated; setReaderAway(false) paints it when they come back.
    if (isActive && !_deferContentUpdate(ev)) notifyListeners();
  }

  /// True while the transcript is scrolled AWAY from the newest end. Owned by
  /// the view (the follow latch's owner), read here to decide whether a
  /// per-character content delta needs to reach the UI at all.
  ///
  /// Why defer: re-laying out the transcript for every streamed character is
  /// what drags the content under a reader's eyes. Each delta grows the newest
  /// end, the layout shifts, and the read-hold's post-layout compensation then
  /// moves it back - two phases per character, which reads as an up/down jitter
  /// on top of the drift. A reader who is away from the newest end does not need
  /// those characters painted anyway: they are off the bottom of the viewport.
  /// Clearing the flag notifies ONCE, rendering everything that accumulated.
  bool _readerAway = false;
  bool get readerAway => _readerAway;

  void setReaderAway(bool away) {
    if (away == _readerAway) return;
    _readerAway = away;
    // Coming back: paint the backlog this deferral accumulated.
    if (!away && !_disposed) notifyListeners();
  }

  /// Kinds that arrive once PER CHARACTER (or per progress tick) while a turn
  /// streams. Only these are deferred; everything structural - a new message, a
  /// tool starting, a plan update, the turn ending - still repaints immediately,
  /// so a reader is never left staring at a frozen transcript.
  static const Set<String> _perCharacterKinds = {
    'message.delta',
    'thinking.delta',
    'reasoning.delta',
    'tool.progress',
  };

  bool _deferContentUpdate(GatewayEvent ev) =>
      _readerAway && _streaming && _perCharacterKinds.contains(ev.type);

  GatewayEvent? _pendingRequest;
  GatewayEvent? get pendingRequest => _pendingRequest;
  @visibleForTesting
  set pendingRequest(GatewayEvent? value) {
    _pendingRequest = value;
    if (!_disposed) notifyListeners();
  }

  // ── Cross-client sync (sessions.changed) ──────────────────────────

  /// Debounce timer for `sessions.changed` refreshes. The gateway broadcasts
  /// this event to every connected client whenever the session DB moves —
  /// including turns driven by other clients (desktop, CLI, dashboard).
  Timer? _sessRefreshTimer;
  bool _sessRefreshPending = false;
  bool _sessRefreshInFlight = false;

  void _onSessionsChanged() {
    // Always refresh the roster so new titles/activity show up in the
    // Sessions sheet — that's cheap and unconditional.
    unawaited(loadSessions());

    // Also refresh the authoritative live statuses: the gateway fired this
    // because a session moved (a turn started/finished, possibly on ANOTHER
    // client). The reconcile refreshes the per-session dots and, if a turn is
    // in flight, arms the watchdog. The 1.5s throttle inside the reconcile
    // keeps this cheap even during a burst of DB writes.
    unawaited(reconcileActiveTurnStatus());

    // A turn may have ended (possibly on ANOTHER client): re-read the active
    // session's goal so the persistent bar tracks set/park/pause/done/clear.
    unawaited(refreshGoal());

    // Never discard a signal merely because this client is temporarily busy.
    // _finishTurn() and resumeSession's finally block retry the pending pull.
    _sessRefreshPending = true;
    _scheduleSessionRefresh();
  }

  void _scheduleSessionRefresh() {
    if (!_sessRefreshPending || _sessRefreshInFlight) return;
    if (_activeSessionId == null || _streaming || _loadingSession) return;
    if (_client.state != GwConnectionState.open) return;

    _sessRefreshTimer?.cancel();
    _sessRefreshTimer = Timer(const Duration(milliseconds: 750), () {
      unawaited(_refreshActiveFromHistory());
    });
  }

  /// Pull the latest transcript for the active session via the read-only
  /// `session.history` RPC. Pulls are serialized so an older response can
  /// never land after a newer one and roll the transcript backward.
  Future<void> _refreshActiveFromHistory() async {
    final sid = _activeSessionId;
    if (sid == null || _streaming || _loadingSession) return;
    if (_client.state != GwConnectionState.open || _sessRefreshInFlight) return;
    if (_compacting) {
      // The durable transcript is mid-rewrite; a read now can observe a
      // half-applied state and blank the view. Wait for `compacted`, which
      // arms the pending pull again.
      _sessRefreshPending = true;
      return;
    }

    _sessRefreshPending = false;
    _sessRefreshInFlight = true;
    final gen = _selection; // guard against a mid-flight session switch
    try {
      final res = await _client.request('session.history', {'session_id': sid});
      if (_disposed || gen != _selection || _activeSessionId != sid) return;
      if (_streaming || _loadingSession) {
        _sessRefreshPending = true;
        return;
      }

      final msgs = res['messages'];
      if (msgs is! List) return;

      final fresh = <ChatMessage>[];
      for (final m in msgs) {
        if (m is! Map) continue;
        final role = (m['role'] ?? '') as String;
        if (role != 'user' && role != 'assistant') continue;
        final content = m['text']?.toString() ?? '';
        // A reasoning-only assistant row (kept by the gateway so "Thinking…"
        // survives a reload) has no text but must not be dropped.
        final reasoning = role == 'assistant'
            ? (m['reasoning'] ?? m['reasoning_content'])?.toString() ?? ''
            : '';
        // Authoring time (Unix seconds) — drives the transcript's time-category
        // section breaks. Accept the gateway's `timestamp` or a `ts` alias.
        final tsRaw = m['timestamp'] ?? m['ts'];
        final time = tsRaw is num && tsRaw > 0
            ? DateTime.fromMillisecondsSinceEpoch((tsRaw * 1000).round())
            : null;
        if (content.isEmpty && reasoning.isEmpty) continue;
        final msg = ChatMessage(
            role: role, text: content, reasoning: reasoning, time: time);
        // Respect the trace VISIBILITY gate on rehydrate: the raw trace
        // stays in reasoning (re-show restores it), but a hydrated row must
        // not resurrect a hidden trace (effectiveReasoning defaults to the
        // raw text from the constructor).
        msg.effectiveReasoning = _showReasoning ? reasoning : '';
        fresh.add(msg);
      }

      if (_sameTranscript(fresh, _messages)) return;
      _mergeTextTranscript(fresh);
      notifyListeners();
    } catch (_) {
      // Best-effort. A later sessions.changed signal retries; do not create a
      // self-sustaining polling loop after one failed read.
    } finally {
      _sessRefreshInFlight = false;
      _scheduleSessionRefresh();
    }
  }

  /// Preserve existing message objects (tool chips, reasoning, pending/error
  /// UI state) whenever the durable history only updates text or appends rows.
  /// Replace only the suffix whose role sequence genuinely diverged.
  ///
  /// An EMPTY [fresh] list when a transcript is already on screen is never a
  /// real "the conversation is now empty" — `session.history` reports no rows
  /// while a live record's display history is still hydrating, and a session
  /// row may not exist yet for a fresh draft. Merging that empty read used to
  /// `removeRange(0, length)` the whole transcript and leave the view BLANK.
  /// Treat it as a transient read and keep what the reader is looking at.
  void _mergeTextTranscript(List<ChatMessage> fresh) {
    if (fresh.isEmpty && _messages.isNotEmpty) return;
    if (fresh.length == _messages.length) {
      var sameRoles = true;
      for (var i = 0; i < fresh.length; i++) {
        if (fresh[i].role != _messages[i].role) {
          sameRoles = false;
          break;
        }
      }
      if (sameRoles) {
        for (var i = 0; i < fresh.length; i++) {
          _messages[i].setTextParts([fresh[i].text]);
        }
        return;
      }
    }

    var prefix = 0;
    while (prefix < fresh.length &&
        prefix < _messages.length &&
        fresh[prefix].role == _messages[prefix].role &&
        fresh[prefix].text == _messages[prefix].text) {
      prefix++;
    }
    _messages.removeRange(prefix, _messages.length);
    _messages.addAll(fresh.skip(prefix));
    // The list under the reader has changed shape, so any pixel measurement the
    // view is holding no longer describes this transcript.
    _transcriptEpoch++;
  }

  static bool _sameTranscript(List<ChatMessage> a, List<ChatMessage> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].role != b[i].role || a[i].text != b[i].text) return false;
    }
    return true;
  }

  void _finishTurn() {
    if (_streaming) {
      _streaming = false;
      _statusLine = '';
      _compacting = false;
      // The turn is over — refresh the authoritative dot state so the
      // sidebar shows idle (best-effort; sessions.changed covers it too).
      unawaited(reconcileActiveTurnStatus());
      // Keep the keep-alive foreground service running: the socket must stay
      // connected in the background so background task execution / late events
      // are not missed. The service is dropped only on an explicit close
      // (see _onState), not when a turn completes. Refresh the notification
      // back to the idle "connected" state now that the turn is done.
      unawaited(_fg.start(
          title: 'Hermes connected',
          text: 'Keeping your connection to the gateway alive.'));
      final last = _messages.isEmpty ? null : _messages.last;
      if (last != null && last.role == 'assistant' && last.text.isNotEmpty) {
        _pushNotification(
          title: 'Hermes replied',
          body: last.text.length > 120
              ? '${last.text.substring(0, 120)}…'
              : last.text,
          tag: 'done-${_activeSessionId}',
        );
      }
      // A turn just ended: re-read the goal, since the agent may have set,
      // parked, paused, or achieved it (or the user just ran `/goal …`).
      unawaited(refreshGoal());
    }
    _scheduleSessionRefresh();
  }

  void _pushNotification(
      {required String title, required String body, String? tag}) {
    // Fire and forget; notifier handles init state. Carry the STORED session
    // id as the tap payload — main._routeNotification resumes it. Without a
    // payload the whole tap-to-open path was dead (id always null). A fresh
    // draft has no stored id yet and simply does not route.
    unawaited(_notifier.push(
        title: title, body: body, tag: tag, sessionId: _activeStoredSessionId));
  }

  // ── Transcript helpers ─────────────────────────────────────────────

  ChatMessage _ensureAssistantTail() {
    if (_messages.isEmpty ||
        _messages.last.role != 'assistant' ||
        !_messages.last.pending) {
      _messages
          .add(ChatMessage(role: 'assistant', pending: true, time: DateTime.now()));
    }
    return _messages.last;
  }

  /// Find a [ToolActivity] by [toolId] ANYWHERE in the transcript.
  ///
  /// Tool events (`tool.progress`/`tool.complete`) are matched by tool_id. A
  /// `message.interim` seals the current segment (sets `pending=false`) and the
  /// next event may append a FRESH assistant segment, so a late event for an
  /// earlier tool no longer belongs in `_messages.last`. Searching the whole
  /// transcript returns the tool's true owner (which may be a sealed, earlier
  /// message) — this is what stops tool chips from getting stuck in
  /// `running`. Returns null when the id is unknown.
  ToolActivity? _findToolGlobal(String toolId) {
    for (final m in _messages) {
      for (final t in m.tools) {
        if (t.toolId == toolId) return t;
      }
    }
    return null;
  }

  Future<void> _newSessionDraft() async {
    ++_attachGen;
    ++_selection;
    await _detachPending(
      sessionId: _activeSessionId,
      timeout: const Duration(seconds: 20),
    );
    _activeSessionId = null;
    _verifiedLiveSessionId = null;
    _messages.clear();
    _transcriptEpoch++;
    _streaming = false;
    _statusLine = '';
    _resetTrackedStatus();
    _activeGoal = null;
    notifyListeners();
  }

  // ── Session ops ────────────────────────────────────────────────────

  Future<void> loadSessions() async {
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('session.list', {'limit': 200});
      final list = res['sessions'];
      final rows = (list is List ? list : const <Map<String, dynamic>>[])
          .whereType<Map<String, dynamic>>()
          .map(SessionRow.fromJson)
          .toList();
      // The gateway broadcasts `sessions.changed` on every DB write (and on
      // the 500ms mtime poll that can fire without a change), so this pull
      // runs often. Re-assigning an identical roster on every pull notified
      // every store listener — including the transcript's rebuild. Skip when
      // nothing changed.
      if (_rosterEqual(_sessions, rows)) return;
      _sessions
        ..clear()
        ..addAll(rows);
      if (!_disposed) notifyListeners();
    } catch (_) {
      // Roster load is best-effort.
    }
  }

  /// Same rows in the same order: id + title + preview + timestamp.
  static bool _rosterEqual(List<SessionRow> a, List<SessionRow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.title != y.title ||
          x.preview != y.preview ||
          x.startedAt != y.startedAt ||
          x.messageCount != y.messageCount) {
        return false;
      }
    }
    return true;
  }

  /// Test seam: install roster rows directly (same mapping as [loadSessions])
  /// without a gateway round-trip. Used by the segmentation/widget tests.
  @visibleForTesting
  void seedSessionsForTest(List<Map<String, dynamic>> rows) {
    _sessions
      ..clear()
      ..addAll(rows.map(SessionRow.fromJson));
    if (!_disposed) notifyListeners();
  }

  /// Returns true when a LIVE session was established (the gateway handed back
  /// a runtime id). Callers that MUST have a switchable target treat false as
  /// "this conversation cannot be targeted yet" rather than sending a request
  /// that the gateway answers with a success envelope while applying nothing.
  Future<bool> resumeSession(String id, {bool silent = false}) async {
    if (_client.state != GwConnectionState.open) return false;
    final generation = ++_selection;
    ++_attachGen;
    _loadingSession = true;
    _pendingRequest = null;
    _statusLine = '';
    var established = false;
    if (!silent) notifyListeners();
    try {
      // Detach the outgoing session's gateway images BEFORE switching.
      // On success the local refs are removed; on failure they are
      // PRESERVED (with a visible error) so a still-queued image is
      // never silently lost.
      final detachResult = await _detachPending(
        sessionId: _activeSessionId,
        timeout: const Duration(seconds: 20),
      );
      if (_disposed || generation != _selection) return false;
      if (!detachResult && _pendingAttachments.isNotEmpty) {
        _fail('Could not clear previous attachments: detach failed');
        return false;
      }
      final res = await _client.request('session.resume', {'session_id': id});
      if (_disposed || generation != _selection) return false;
      final sid = res['session_id'];
      if (sid is! String || sid.isEmpty)
        throw GatewayError('Resume returned no live session ID');
      _activeSessionId = sid;
      _verifiedLiveSessionId = sid;
      _activeStoredSessionId =
          (res['resumed'] ?? res['session_key'] ?? id).toString();
      _messages.clear();
      _transcriptEpoch++;
      _resetTrackedStatus();
      // A request card belonging to the OUTGOING session is stale the moment
      // the conversation switches — answering it from the new session would
      // send the reply to the wrong session_id.
      _pendingRequest = null;
      _hydrateFromResume(res);
      established = true;
    } catch (e) {
      if (_disposed || generation != _selection) return false;
      // A failed resume must not discard the pending attachments —
      // their refs are still queued in the gateway and the user is
      // still on (or returned to) the old session.
      _fail('Could not resume: ${_shortError(e)}');
    } finally {
      if (!_disposed && generation == _selection) {
        _loadingSession = false;
        // A (re)open is a deliberate "take me to the newest message" event.
        // Arm the sticky jump flag; the view consumes it once the transcript
        // has scrollable content (hydration lands in this same batch). A
        // SILENT resume is plumbing (stale-runtime recovery), not a
        // navigation — it must not yank a reader's scroll position.
        _pendingJumpToBottom = !silent;
        _scheduleSessionRefresh();
        // Goal bar is per-session: drop the outgoing one and re-read the new
        // session's (it may carry its own active goal).
        clearGoal();
        unawaited(refreshGoal());
        unawaited(_refreshContextUsage());
        notifyListeners();
      }
    }
    return established;
  }

  void _hydrateFromResume(Map<String, dynamic> res) {
    final messages = res['messages'];
    final hydratedRows = messages is List ? messages.length : 0;
    if (messages is List && messages.isNotEmpty) {
      for (final m in messages) {
        if (m is! Map) continue;
        final role = (m['role'] ?? '') as String;
        if (role != 'user' && role != 'assistant') continue;
        final content = (m['text']?.toString() ?? '');
        final reasoning = role == 'assistant'
            ? (m['reasoning'] ?? m['reasoning_content'])?.toString() ?? ''
            : '';
        final tsRaw = m['timestamp'] ?? m['ts'];
        final time = tsRaw is num && tsRaw > 0
            ? DateTime.fromMillisecondsSinceEpoch((tsRaw * 1000).round())
            : null;
        if (content.isEmpty && reasoning.isEmpty) continue;
        final msg = ChatMessage(
            role: role, text: content, reasoning: reasoning, time: time);
        // Same trace-visibility gate as the history hydrator.
        msg.effectiveReasoning = _showReasoning ? reasoning : '';
        _messages.add(msg);
      }
    }
    final info = res['info'];
    if (info is Map && info['model'] is String) {
      setLiveModel(info['model'] as String,
          provider:
              info['provider'] is String ? info['provider'] as String : null);
    }
    // The resumed session's effective reasoning effort (session.info carries
    // it; a per-session override made elsewhere must show in the header menu).
    if (info is Map && info['reasoning_effort'] is String) {
      _reasoningEffort = info['reasoning_effort'] as String;
      _modelConfigLoaded = true;
    }
    // A resume that landed with NO rows must not leave the view blank with no
    // retry path: a live record whose display history is still hydrating (or a
    // stored id whose rows have not been read back yet) answers with an empty
    // `messages` list plus a truthful `message_count`/`hydrating`. Arm the
    // read-only history pull so the transcript fills in instead of staying
    // empty until some unrelated `sessions.changed` happens to arrive.
    final reportedCount = res['message_count'];
    final expectedRows = reportedCount is num ? reportedCount.toInt() : 0;
    if (hydratedRows == 0 &&
        (expectedRows > 0 ||
            res['hydrating'] == true ||
            res['messages_omitted'] == true)) {
      _sessRefreshPending = true;
    }
    // A resume may land on a turn that is STILL running (started on another
    // client, or this one's own turn whose events replay). Reflect it so the
    // spinner, Stop, and mid-turn Send are all live — the replayed stream
    // owns the text from here.
    if (res['running'] == true) {
      _streaming = true;
      _statusLine = 'Working…';
    } else {
      _streaming = false;
      _statusLine = '';
    }
    // The gateway replays unresolved input requests on resume
    // (pending_clarify / pending_approval) — a session parked on a clarify
    // or approval would otherwise look idle here while its agent waits until
    // timeout, and there would be no card to answer it from.
    _pendingRequest = null;
    final pendingClarify = res['pending_clarify'];
    final pendingApproval = res['pending_approval'];
    final sid = _activeSessionId ?? '';
    if (pendingClarify is Map<String, dynamic>) {
      _pendingRequest =
          GatewayEvent(type: 'clarify.request', sessionId: sid, payload: pendingClarify);
      // A batch clarify replays the answers already locked, so a reconnecting
      // client restores its tick state instead of re-asking everything.
      _clarifyAnswers.clear();
      final locked = pendingClarify['answers'];
      if (locked is Map) {
        locked.forEach((k, v) => _clarifyAnswers[k.toString()] = v.toString());
      }
      _statusLine = 'Waiting for your input…';
      _pushNotification(
        title: 'Hermes needs input',
        body: pendingClarify['question']?.toString() ?? 'Answer the question',
        tag: 'req-resume-clarify',
      );
    } else if (pendingApproval is Map<String, dynamic>) {
      _pendingRequest =
          GatewayEvent(type: 'approval.request', sessionId: sid, payload: pendingApproval);
      _statusLine = 'Waiting for your input…';
      _pushNotification(
        title: 'Hermes needs input',
        body: pendingApproval['command']?.toString() ?? 'Approve this action',
        tag: 'req-resume-approval',
      );
    }
  }

  Future<void> createSession() async {
    if (_client.state != GwConnectionState.open || _creatingSession) return;
    _creatingSession = true;
    if (!_disposed) notifyListeners();
    final generation = ++_selection;
    ++_attachGen;
    try {
      final res = await _client.request(
          'session.create', {'close_on_disconnect': false, 'hidden': false});
      // A late/late-cancelled create must not clobber a newer user
      // selection (e.g. a resume that started while this create was
      // in flight).
      if (_disposed || generation != _selection) return;
      final sid = res['session_id'] as String?;
      if (sid == null || sid.isEmpty) {
        throw GatewayError('session.create returned no session ID');
      }
      // Detach the outgoing session's gateway images BEFORE switching.
      // On success the refs are removed; on failure they are preserved
      // (with a visible error) so no queued image is silently lost.
      final oldSid = _activeSessionId;
      final detachResult = await _detachPending(
        sessionId: oldSid,
        timeout: const Duration(seconds: 20),
      );
      if (_disposed || generation != _selection) return;
      if (!detachResult && _pendingAttachments.isNotEmpty) {
        _fail('Could not start new session: detach failed');
        notifyListeners();
        return;
      }
      _activeSessionId = sid;
      _verifiedLiveSessionId = sid;
      // A newly created conversation has no resumed/persisted session key yet.
      // Keeping the previous key here made title/roster UI claim the new chat
      // was still the old stored conversation.
      _activeStoredSessionId = null;
      _messages.clear();
      _transcriptEpoch++;
      _streaming = false;
      _resetTrackedStatus();
      // Fresh transcript — nothing to scroll to yet; consume any pending jump
      // so a later first-message doesn't retrigger an open-jump.
      _pendingJumpToBottom = false;
      await loadSessions();
      if (!_disposed) notifyListeners();
    } catch (e) {
      if (_disposed || generation != _selection) return;
      _fail('Could not create session: ${_shortError(e)}');
      if (!_disposed) notifyListeners();
    } finally {
      _creatingSession = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Delete a stored session. [id] is the STORED session key (the roster
  /// row's id — `session.list`/`session.delete` both live in stored-key
  /// space, NOT the runtime sid).
  ///
  /// Deleting the conversation you are currently viewing requires finalizing
  /// its runtime session first: the gateway refuses to delete a live session
  /// (4023 "cannot delete an active session" — an FK would trip on the
  /// agent's next flush). The desktop does exactly this (close the runtime,
  /// reset to a fresh draft, then delete), so we mirror it. Failures surface
  /// through the status line and the returned flag — a delete that does
  /// nothing with no explanation was the bug this replaces (the old code
  /// guarded against the RUNTIME sid — a different id space that never
  /// matches a stored key — and swallowed every error).
  Future<bool> deleteSession(String id) async {
    if (_client.state != GwConnectionState.open) {
      _fail('Not connected');
      if (!_disposed) notifyListeners();
      return false;
    }
    final isViewing =
        id == _activeStoredSessionId || id == _activeSessionId;
    if (isViewing) {
      final runtime = _activeSessionId;
      if (runtime != null && runtime.isNotEmpty) {
        // Finalize first; best-effort (a not-found close is fine — the
        // delete RPC will say if the session is still live).
        try {
          await _client.request('session.close', {'session_id': runtime});
        } catch (_) {}
        // Reset the local view to a fresh draft BEFORE attempting the
        // delete, so a failed delete cannot leave us pointing at a
        // half-deleted, runtime-less session. The roster row survives the
        // failure and re-resumes normally.
        _activeSessionId = null;
        _activeStoredSessionId = null;
        _messages.clear();
      _transcriptEpoch++;
        _streaming = false;
        _statusLine = '';
        _activeGoal = null;
        _resetTrackedStatus();
      }
    }
    try {
      await _client.request('session.delete', {'session_id': id});
      _sessions.removeWhere((s) => s.id == id);
      if (!_disposed) notifyListeners();
      await loadSessions();
      return true;
    } catch (e) {
      _fail('Could not delete: ${_shortError(e)}');
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  /// Rename a session. [id] is the stored session key. A titleless rename
  /// (empty [title]) is a no-op on the client side.
  Future<void> setTitle(String id, String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    try {
      final res = await _client
          .request('session.title', {'session_id': id, 'title': t});
      final returned = res['title']?.toString() ?? t;
      final idx = _sessions.indexWhere((s) => s.id == id);
      if (idx != -1) {
        _sessions[idx] = _sessions[idx].copyWithTitle(returned);
      }
    } catch (e) {
      _fail(_shortError(e));
    }
    if (!_disposed) notifyListeners();
  }

  /// Hide/unhide a session from the default roster (stays resumable by id).
  Future<void> setHidden(String id, bool hidden) async {
    try {
      await _client
          .request('session.set_hidden', {'session_id': id, 'hidden': hidden});
      if (hidden) _sessions.removeWhere((s) => s.id == id);
      await loadSessions();
    } catch (e) {
      _fail(_shortError(e));
    }
    if (!_disposed) notifyListeners();
  }

  /// Compress the active session's context. Busy sessions refuse (4009); a
  /// held compression lock returns a soft result. Resolves the outcome string
  /// for UI surfacing, or null when no active session.
  Future<String?> compressSession({String? storedId}) async {
    // Default target: the ACTIVE conversation. A roster row passes its stored
    // id — the old call-site dropped it, so "Compress context" on a row
    // compressed whatever was on screen, not the row clicked.
    var sid = _activeSessionId;
    if (storedId != null && storedId.isNotEmpty && storedId != _activeStoredSessionId) {
      // The live roster may be cold (it is normally loaded by Settings):
      // refresh it once so the stored-key → runtime-sid lookup can resolve.
      if (_activeList.isEmpty) await loadActiveList();
      final row =
          _activeList.firstWhere((a) => a.id == storedId || a.sessionKey == storedId, orElse: () => const ActiveRow(id: ''));
      if (row.id.isEmpty) {
        return 'Not a live conversation — open it first to compress it';
      }
      sid = row.id;
    }
    if (sid == null || sid.isEmpty) return null;
    try {
      // Acknowledge BEFORE the request: session.compress blocks until the
      // rewrite is done, so a notice fired afterwards would look like a
      // second completion toast. The gateway's own `compressing` status
      // (4+ messages) can no longer double-announce: _compressing is now set.
      _announceCompressionStart();
      final res =
          await _client.request('session.compress', {'session_id': sid});
      final locked = res['lock_held'] == true;
      _compressing = false;
      _statusLine = locked
          ? (res['message']?.toString() ?? 'Compression lock held')
          : 'Compressed';
      if (!_disposed) notifyListeners();
      return locked
          ? (res['message']?.toString() ?? 'Compression lock held')
          : 'Compressed';
    } catch (e) {
      final msg = _shortError(e);
      _compressing = false;
      _statusLine = msg;
      if (!_disposed) notifyListeners();
      return msg;
    }
  }

  /// Move a stored session's working directory. [id] is the stored
  /// `session_key`; [cwd] the target directory.
  Future<String?> moveWorkspace(String id, String cwd) async {
    try {
      final res = await _client
          .request('session.workspace.move', {'session_key': id, 'cwd': cwd});
      final moved = res['cwd']?.toString() ?? cwd;
      _statusLine = 'Workspace → $moved';
      return moved;
    } catch (e) {
      final msg = _shortError(e);
      _statusLine = msg;
      return msg;
    }
  }

  /// Live TUI sessions in this process (distinct from the DB-backed [sessions]
  /// roster). Used by the desktop's multi-session footer; populates [activeList].
  Future<void> loadActiveList() async {
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('session.active_list',
          {'current_session_id': _activeSessionId ?? ''});
      final list = res['sessions'];
      _activeList
        ..clear()
        ..addAll((list is List ? list : const <Map<String, dynamic>>[])
            .whereType<Map<String, dynamic>>()
            .map(ActiveRow.fromJson));
      if (!_disposed) notifyListeners();
    } catch (_) {
      // Best-effort; the roster is the primary surface.
    }
  }

  // ── Prompting ──────────────────────────────────────────────────────

  /// Map a gateway `session.active_list` status onto the desktop's dot
  /// states (see [activeSessionState]).
  static String _dotStateForStatus(String? status) => switch (status) {
        'working' || 'starting' => 'working',
        'waiting' => 'needs-input',
        _ => 'idle',
      };

  /// Throttle for [reconcileActiveTurnStatus] (gateway polls are cheap, but
  /// several event paths can trigger it in quick succession).
  bool _activeSessionSeenLive = false;

  /// Test seam: clear the reconcile throttle so a deliberate reconcile is not
  /// swallowed by the connect-time one (mirrors what interrupt() does inline).
  @visibleForTesting
  void resetStatusPollThrottleForTest() => _lastStatusPollAt = 0;

  /// Reconcile the optimistic [streaming] flag against the gateway's
  /// authoritative `session.active_list` status, and refresh the per-session
  /// dot states. The local flag goes true on send and clears on
  /// message.complete — if a terminal event is ever lost (socket blip,
  /// gateway restart, another client's /interrupt), it stays true forever,
  /// which is the "says working but isn't, Stop does nothing" state. When
  /// the gateway reports the active session idle (or no longer live), the
  /// stale local flag is dropped. A session the gateway reports working
  /// without a local turn (started on another client) is marked working so
  /// the UI is honest.
  Future<void> reconcileActiveTurnStatus() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastStatusPollAt < 1500) return;
    _lastStatusPollAt = now;
    final sid = _activeSessionId;
    if (sid == null || sid.isEmpty) return;
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request(
          'session.active_list', {'current_session_id': sid});
      if (_disposed || _activeSessionId != sid) return;
      final list = res['sessions'];
      if (list is! List) return;
      final states = <String, String>{};
      String? activeStatus;
      for (final row in list) {
        if (row is! Map) continue;
        final id = (row['session_id'] ?? row['id'] ?? '').toString();
        final status = (row['status'] ?? '').toString();
        final dot = _dotStateForStatus(status);
        if (id.isNotEmpty) states[id] = dot;
        final stored = (row['session_key'] ?? '').toString();
        if (stored.isNotEmpty && stored != id) states[stored] = dot;
        if (id == sid) activeStatus = status;
      }
      _sessionDotStates
        ..clear()
        ..addAll(states);
      if (activeStatus != null) {
        _activeSessionSeenLive = true;
        _lastGatewayStatus = activeStatus;
        if (!_streaming &&
            (activeStatus == 'working' || activeStatus == 'starting')) {
          // A turn started elsewhere (another client, a queued-prompt drain,
          // cron): reflect it — its events will keep the flag alive.
          _streaming = true;
          _statusLine =
              activeStatus == 'starting' ? 'Starting…' : 'Working…';
        } else if (_streaming && activeStatus == 'idle') {
          // Authoritative source says the turn is over. A lost terminal
          // event is repaired here; a queued follow-up turn re-marks
          // working on the next poll when the drain starts.
          _streaming = false;
          _statusLine = '';
        }
      } else if (_streaming && _activeSessionSeenLive) {
        // The session is no longer a live gateway session at all (finalized,
        // or the gateway process restarted): the local flag is stale.
        _streaming = false;
        _statusLine = '';
      }
      if (activeStatus == null &&
          !_streaming &&
          !_loadingSession &&
          _messages.isNotEmpty &&
          _activeStoredSessionId != null &&
          _activeStoredSessionId!.isNotEmpty &&
          _staleRecoveryDue()) {
        // The conversation on screen is NOT in the gateway's live session
        // table: its runtime was reaped (WS detach / TTL / LRU) or the
        // gateway process restarted. The transcript still shows it, but
        // every runtime-scoped RPC would 4001. Re-attach via the stored id —
        // the gateway's documented recovery — so the next send, the Stop
        // button, and the status dot all work again. Silent: no spinner, no
        // scroll jump, no banner. Throttled so a stored session the gateway
        // can no longer resume cannot spin RPCs on every reconcile.
        unawaited(_recoverStaleActiveSession(_activeStoredSessionId!));
      }
      if (!_disposed) notifyListeners();
    } catch (_) {
      // Best-effort; the next poll retries.
    }
    // Event-driven reconciliation: a turn that just ended on ANY client
    // wrote the session DB, so the reconcile sees it on this broadcast.
  }

  /// Reset the tracked-status state when the active session identity changes.
  void _resetTrackedStatus() {
    _activeSessionSeenLive = false;
    _lastGatewayStatus = '';
    _compacting = false;
    // Context occupancy is per conversation.
    _context = ContextUsage.unknown;
    // A parked clarify/approval belongs to the OUTGOING session.
    _clarifyAnswers.clear();
    // Reasoning/fast are SESSION-scoped: a different conversation may have a
    // different override, so force a re-read of the new session's values.
    _modelConfigLoaded = false;
    _reasoningEffort = '';
    _fastMode = '';
  }

  /// Submit a message. Returns true when it reached the gateway (including
  /// the busy-queued / steered / redirected mid-turn statuses) and false when
  /// it did not — in which case the optimistic transcript entry is removed
  /// (no ghost message) and the status line carries the failure.
  ///
  /// A 4001 ("session not found") on the first attempt is not a user-facing
  /// error: it means the runtime id went stale (the gateway reaped it after a
  /// WS detach, an idle TTL, or LRU eviction) and the documented recovery is
  /// `session.resume` on the STORED id (server.py `_sess_nowait`). We re-attach
  /// silently and retry ONCE so a send after a background disconnect lands
  /// instead of failing. A second failure is surfaced.
  /// Send [text] to the active session. When [asQueue] is set, the
  /// `queued: true` flag is passed so the gateway FORCES queue mode even if
  /// `display.busy_input_mode` is interrupt or steer: a "run after" message
  /// (`/queue`) must never become a live correction of a running turn
  /// (gateway `session_auto_continue._handle_busy_submit`). A plain mid-turn
  /// send (no flag) keeps the session's busy mode, like the desktop.
  Future<bool> send(String text, {bool asQueue = false}) async {
    if (_sending) return false;
    _sending = true;
    _notify();
    try {
      return await _sendWithAttachments(text, asQueue: asQueue);
    } catch (e) {
      _fail(_shortError(e));
      return false;
    } finally {
      _sending = false;
      _notify();
    }
  }

  Future<bool> _sendWithAttachments(String text, {required bool asQueue}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && pendingAttachments.isEmpty) return false;
    if (_client.state != GwConnectionState.open) {
      _connectError = 'Not connected';
      notifyListeners();
      return false;
    }
    // Ensure a session exists (draft -> real on first prompt).
    final sid = await _ensureSession();
    if (sid == null || sid.isEmpty || _disposed) return false;
    final generation = _attachGen;
    for (final image in List<PendingAttachment>.of(_queuedImages.values)) {
      final ref = await attachImageBytes(image.bytes!, filename: image.filename);
      if (_disposed || generation != _attachGen || sid != _activeSessionId) return false;
      if (!_pendingAttachments.contains(ref)) return false;
      _queuedImages.remove(image.ref);
    }
    // Prepend file refs so the agent can resolve staged workspace files.
    final fileRefs =
        _pendingAttachments.where((r) => r.startsWith('@file:')).join(' ');
    final fullText = fileRefs.isEmpty ? trimmed : '$fileRefs $trimmed'.trim();
    // Track the optimistic row by IDENTITY: the stale-runtime recovery below
    // rehydrates the transcript (dropping it), and the failure path must be
    // able to remove exactly this row — never a look-alike.
    final optimistic =
        ChatMessage(role: 'user', text: fullText, time: DateTime.now());
    _messages.add(optimistic);
    _streaming = true;
    _statusLine = 'Thinking…';
    notifyListeners();
    // Snapshot the attachment refs being submitted so we remove ONLY these
    // after success — not refs added by a concurrent attach while in flight.
    final snapshot = List<String>.from(_pendingAttachments);
    Object? failure;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await _client.request('prompt.submit', {
          'session_id': _activeSessionId,
          'text': fullText,
          if (asQueue) 'queued': true,
        });
        // Remove only the snapshotted refs; refs added during submit survive.
        for (final ref in snapshot) {
          _removeAttachment(ref);
        }
        // Keep the process alive while the turn streams in the background and
        // refresh the keep-alive notification so the user sees work in
        // progress.
        unawaited(_fg.start(
            title: 'Hermes is working',
            text: 'A turn is running on your gateway.'));
        // A send made while a turn is already running does NOT error — the
        // gateway applies busy_input_mode and returns status "queued",
        // "steered", or "redirected". Reflect which happened so the user
        // knows the mid-turn send took effect.
        // (Re-assert `_streaming`: the stale-runtime recovery above runs a
        // session.resume, and a resume resets the turn flags — without this
        // a recovered send would land with no working indicator and no Stop
        // button.)
        _streaming = true;
        final status = (res['status'] ?? '').toString();
        if (status == 'steered') {
          _statusLine = 'Steer queued — arrives after the next tool call';
        } else if (status == 'redirected') {
          _statusLine = 'Turn redirected';
        } else if (status == 'queued') {
          _statusLine = 'Queued — will run when the current turn finishes';
        } else {
          // "streaming" (fresh turn) — keep the thinking indicator.
          _statusLine = 'Thinking…';
        }
        if (!_disposed) notifyListeners();
        return true;
      } catch (e) {
        failure = e;
        final stored = _activeStoredSessionId;
        final staleRuntime = e is GatewayError &&
            e.code == 4001 &&
            attempt == 0 &&
            stored != null &&
            stored.isNotEmpty;
        if (staleRuntime) {
          await _recoverStaleActiveSession(stored);
          if (!_disposed &&
              _client.state == GwConnectionState.open &&
              _activeSessionId != null &&
              _activeSessionId!.isNotEmpty) {
            // The recovery rehydrated the transcript from the gateway, which
            // does not contain this prompt (the submit was rejected, never
            // stored) — put the optimistic row back for the retry so the
            // user's message stays on screen.
            if (!_messages.contains(optimistic)) _messages.add(optimistic);
            continue; // retry once with the fresh runtime id
          }
        }
        break;
      }
    }

    // A failed submit must NOT leave the optimistic user message in the
    // transcript (a ghost the gateway never saw). The composer text is
    // already cleared, so the view learns of the failure through this return
    // value and restores the draft.
    _messages.remove(optimistic);
    _streaming = false;
    _fail(_shortError(failure ?? 'Send failed'));
    if (!_disposed) notifyListeners();
    return false;
  }

  /// Request a hard stop of the active turn (`session.interrupt`).
  ///
  /// Returns true when the gateway accepted the request. The gateway clears
  /// the turn's `running` flag on interrupt, so a follow-up authoritative
  /// status poll confirms the UI returns to idle — this is what makes the
  /// Stop button *do something* instead of being a dead no-op.
  Future<bool> interrupt() async {
    final sid = _activeSessionId;
    if (sid == null || sid.isEmpty) return false;
    if (_client.state != GwConnectionState.open) return false;
    _interrupting = true;
    _notify();
    var ok = false;
    try {
      await _client.request('session.interrupt', {'session_id': sid});
      ok = true;
    } catch (_) {
      ok = false;
    }
    _interrupting = false;
    _notify();
    if (ok) {
      // The gateway is tearing the turn down. Confirm via the authoritative
      // status (bypassing the throttle) so the UI reliably settles to idle,
      // and schedule one more poll in case the first lands before the
      // interrupt has propagated.
      _lastStatusPollAt = 0;
      unawaited(reconcileActiveTurnStatus());
    }
    return ok;
  }

  // ── Slash commands ─────────────────────────────────────────────────

  /// Complete a `/…` token. [text] is the raw composer text under the cursor.
  /// Resolves the item list (`{text, display, meta, kind}`) and the `replace_from`
  /// offset so the UI can swap just the token.
  Future<Map<String, dynamic>> completeSlash(String text) async {
    try {
      return await _client.request('complete.slash', {'text': text});
    } catch (_) {
      return {'items': const <Map<String, dynamic>>[]};
    }
  }

  /// Execute a slash command in the active session (e.g. `/compress`, `/model`)
  /// and resolve the human output text (or an error message). Kept as a thin
  /// string API on top of [execSlashDispatch] for callers that don't care
  /// about the structured directive.
  Future<String> execSlash(String command) async {
    final d = await execSlashDispatch(command);
    return d.display;
  }

  /// Composer prefill staged by a `prefill` dispatch (e.g. `/undo` hands the
  /// backed-up message back for editing instead of resubmitting it).
  String? _composerPrefill;

  /// Take and clear the staged composer prefill, if any.
  String? takeComposerPrefill() {
    final p = _composerPrefill;
    _composerPrefill = null;
    return p;
  }

  /// Alias-expansion depth guard (a misconfigured alias loop must not spin).
  int _aliasDepth = 0;

  /// Execute a slash command AND apply the directive it returns.
  ///
  /// `slash.exec` answers plain `{output: ...}` for worker-executed commands,
  /// but the pending-input built-ins (`/queue`, `/steer`, `/retry`, `/goal`,
  /// `/undo`, …) return a STRUCTURED directive the client must act on — this
  /// is what makes `/queue` and mid-turn commands actually work. Mirrors the
  /// desktop's `parseCommandDispatch` handling:
  ///   - `send`/`skill`: submit `message` as a prompt. Works mid-turn: the
  ///     gateway busy-queues it (`prompt.submit` → `{status: queued}`).
  ///   - `prefill`: stage `message` into the composer ([takeComposerPrefill]).
  ///   - `alias`: re-execute the target command.
  ///   - `exec`: display-only (returned for the snackbar).
  Future<SlashDispatch> execSlashDispatch(String command) async {
    final sid = _activeSessionId;
    final cmd = command.trim();
    if (sid == null || sid.isEmpty || cmd.isEmpty) {
      return SlashDispatch(type: 'exec',
          output: cmd.isEmpty ? '' : 'No active session');
    }
    Map<String, dynamic> res;
    try {
      res = await _client
          .request('slash.exec', {'session_id': sid, 'command': cmd});
    } catch (e) {
      return SlashDispatch(type: 'exec', output: _shortError(e));
    }
    final d = _parseSlashDispatch(res);
    await _applySlashDispatch(d, originalCommand: cmd);
    // Goal commands (`/goal <text>`, `/goal pause|resume|status|clear`) mutate
    // the persistent goal; re-read the canonical state so the bar updates
    // immediately without waiting for the next turn to end.
    if (cmd.trimLeft().toLowerCase().startsWith('goal')) {
      unawaited(refreshGoal());
    }
    return d;
  }

  /// Parse a `slash.exec` result into a [SlashDispatch]. Plain
  /// `{output: ...}` (worker-executed commands) becomes a display-only `exec`.
  static SlashDispatch _parseSlashDispatch(Map<String, dynamic> res) {
    final type = (res['type'] ?? '').toString();
    switch (type) {
      case 'send':
      case 'prefill':
      case 'exec':
      case 'alias':
      case 'skill':
        return SlashDispatch(
          type: type,
          message: (res['message'] ?? '').toString(),
          notice: (res['notice'] ?? '').toString(),
          output: (res['output'] ?? '').toString(),
          target: (res['target'] ?? '').toString(),
        );
      default:
        return SlashDispatch(type: 'exec', output: (res['output'] ?? '').toString());
    }
  }

  Future<void> _applySlashDispatch(SlashDispatch d,
      {required String originalCommand}) async {
    switch (d.type) {
      case 'send':
      case 'skill':
        final msg = d.message.trim();
        if (msg.isEmpty) return;
        if (d.notice.trim().isNotEmpty) {
          // System line so the user sees what happened (e.g. "⊙ Goal set …").
          _statusLine = d.notice.trim();
          _notify();
        }
        // Mid-turn is fine: a busy gateway busy-queues the prompt, and the
        // queued turn's events (message.start … message.complete) drive the
        // streaming UI exactly like a fresh send.
        //
        // /queue (and /q) are stricter than a plain mid-turn send: the
        // gateway's _cmd_queue returns the same `send` directive, but the
        // message must RUN AFTER the current turn. queued: true forces queue
        // mode, so display.busy_input_mode=interrupt/steer cannot redirect or
        // steer it (session_auto_continue: "a 'run after' message must NEVER
        // become a live correction"). Skill kickoffs follow the session's
        // busy mode like plain sends.
        final head = originalCommand
            .trimLeft()
            .split(RegExp(r'\s+'))
            .first
            .toLowerCase();
        final isQueueDirective =
            d.type == 'send' && (head == '/queue' || head == '/q');
        await send(msg, asQueue: isQueueDirective);
        break;
      case 'prefill':
        final msg = d.message.trim();
        if (msg.isNotEmpty) _composerPrefill = msg;
        _notify();
        break;
      case 'alias':
        final target = d.target.trim();
        if (target.isEmpty || _aliasDepth >= 4) return;
        // Re-run the alias target with the original argument, like the
        // desktop (`/alias-target <original-arg>`).
        final space = originalCommand.indexOf(' ');
        final arg = space >= 0 ? originalCommand.substring(space + 1).trim() : '';
        _aliasDepth++;
        try {
          await execSlashDispatch(
              '/${target.replaceAll(RegExp(r'^/'), '')}${arg.isNotEmpty ? ' $arg' : ''}');
        } finally {
          _aliasDepth--;
        }
      default:
        // exec / empty: display-only — nothing to apply.
        break;
    }
  }

  // ── Attachments ────────────────────────────────────────────────────

  final List<String> _pendingAttachments = [];
  final Map<String, PendingAttachment> _attachmentDetails = {};
  final Map<String, PendingAttachment> _queuedImages = {};
  int _imageSequence = 0;
  bool _sending = false;
  bool get sendingAttachments => _sending;
  List<String> get pendingAttachments =>
      List.unmodifiable([..._pendingAttachments, ..._queuedImages.keys]);
  List<PendingAttachment> get attachmentDetails => List.unmodifiable([
    for (final ref in _pendingAttachments)
      if (_attachmentDetails[ref] != null) _attachmentDetails[ref]!,
    ..._queuedImages.values,
  ]);

  void queueImage(Uint8List bytes, {required String filename}) {
    ImageAttachmentService.validate(bytes);
    final ref = 'local-image:${++_imageSequence}';
    _queuedImages[ref] = PendingAttachment(ref: ref, filename: filename,
        sizeBytes: bytes.length, bytes: Uint8List.fromList(bytes));
    _notify();
  }

  void _removeAttachment(String ref) {
    _pendingAttachments.remove(ref);
    _attachmentDetails.remove(ref);
  }

  /// In-flight session creation future shared across concurrent callers.
  Future<String?>? _inFlightSessionCreation;

  /// Ensure a live session exists (draft -> real).  Returns the session id,
  /// or null when a lifecycle transition superseded the in-flight creation
  /// before it landed (so callers abort the attach instead of repointing).
  /// Concurrent callers share the same in-flight creation to avoid duplicates.
  Future<String?> _ensureSession() async {
    var sid = _activeSessionId;
    if (sid != null && sid.isNotEmpty) return sid;
    // Share in-flight creation: if another call is already creating a session,
    // await the same future instead of issuing a duplicate request.
    final existing = _inFlightSessionCreation;
    if (existing != null) return existing;
    final future = _createSession();
    _inFlightSessionCreation = future;
    try {
      return await future;
    } finally {
      _inFlightSessionCreation = null;
    }
  }

  Future<String?> _createSession() async {
    // Capture the selection AND disposed state at request time so a late
    // session.create cannot overwrite a newer user selection (resume/create)
    // or repoint the store after it has been disposed.
    final generation = _selection;
    final res = await _client.request(
        'session.create', {'close_on_disconnect': false, 'hidden': false});
    final sid = res['session_id'] as String? ?? '';
    if (_disposed) return sid;
    if (generation != _selection) {
      // A newer lifecycle transition superseded this create. Do NOT steal
      // the active session — the ref, if any, was attached to [sid] and is
      // now orphaned; callers treat a stale create as a failed attach.
      return null;
    }
    _activeSessionId = sid;
    _verifiedLiveSessionId = sid;
    return sid;
  }

  /// Detach all gateway image refs for [sessionId] captured in [refs].
  ///
  /// File refs (`@file:...`) are local-only and never hit the gateway.  All
  /// image detaches run under one [timeout] cap so a dead transport that never
  /// answers cannot hang a lifecycle transition on the default 120s request
  /// timeout.  Returns true when every image ref was detached (or there were
  /// none); false when any image detach failed or the cap was hit — callers
  /// must PRESERVE the pending refs in the false case rather than clear them.
  Future<bool> _detachPending({
    required String? sessionId,
    required Duration timeout,
  }) async {
    final queuedRefs = _queuedImages.keys.toList();
    // Snapshot the refs to detach.  Any ref added while detach is in flight
    // (the "newly added during await" window) is intentionally NOT in this
    // list and survives — it belongs to whatever session is current then.
    final imageRefs = [
      for (final r in _pendingAttachments)
        if (!r.startsWith('@file:')) r
    ];
    if (sessionId == null || sessionId.isEmpty || imageRefs.isEmpty) {
      // Nothing to reach the gateway for; safe to drop the whole list.
      _pendingAttachments.clear();
      _attachmentDetails.clear();
      for (final ref in queuedRefs) {
        _queuedImages.remove(ref);
      }
      return true;
    }
    var allOk = true;
    final deadline = DateTime.now().add(timeout);
    for (final ref in imageRefs) {
      if (_disposed) return false;
      try {
        final remaining = deadline.difference(DateTime.now());
        if (remaining.isNegative) {
          // Cleanup cap reached; treat the rest as undetached.
          allOk = false;
          break;
        }
        await _client
            .request('image.detach', {'session_id': sessionId, 'path': ref},
                remaining.inMilliseconds)
            .timeout(remaining);
      } catch (_) {
        allOk = false;
      }
    }
    if (allOk) {
      // Only the refs we confirmed detached are dropped; racing additions
      // added after the snapshot are left intact.
      for (final ref in imageRefs) {
        _removeAttachment(ref);
      }
      for (final ref in queuedRefs) {
        _queuedImages.remove(ref);
      }
      return true;
    }
    // Preserve the refs so the user (and the gateway's queue) stay in sync.
    return false;
  }

  /// Attach an image from local bytes (the remote path is not gateway-visible,
  /// so bytes ride base64 — the desktop's `image.attach_bytes` path).
  Future<String> attachImageBytes(
    List<int> bytes, {
    String filename = 'image.png',
    String ext = '',
  }) async {
    final attachGen = _attachGen;
    try {
      ImageAttachmentService.validate(bytes);
      final sid = await _ensureSession();
      if (sid == null || sid.isEmpty) {
        // A stale session.create (user switched while it was in flight)
        // returned no usable session — discard the in-flight attach.
        return '';
      }
      final result = await ImageAttachmentService(_client, sessionId: sid)
          .attach(bytes, filename: filename, ext: ext);
      // Guard: generation check catches the case where the user detached
      // the old image, switched session, then switched back to the same
      // stored session — a sid-only check would pass but the generation
      // (bumped by every lifecycle transition) correctly marks the result stale.
      if (attachGen != _attachGen || sid != _activeSessionId) {
        final path = result.path;
        if (path.isNotEmpty) {
          try {
            await _client
                .request('image.detach', {'session_id': sid, 'path': path});
          } catch (_) {}
        }
        return '';
      }
      final ref = result.path;
      if (ref.isNotEmpty) {
        _pendingAttachments.add(ref);
        final copy = Uint8List.fromList(bytes);
        _attachmentDetails[ref] = PendingAttachment(ref: ref, filename: filename,
            sizeBytes: bytes.length, bytes: copy);
        // Retain the bytes under the staged path: that is how the stored
        // transcript will name this image, and a phone cannot fetch a gateway
        // path, so this copy is what lets the user's own photo appear in the
        // conversation instead of a placeholder.
        AttachmentCache.put(ref, copy);
      }
      _notify();
      return ref;
    } catch (e) {
      _notify();
      final error = _shortError(e);
      _fail(error);
      return error;
    }
  }

  /// Attach an arbitrary file (PDF, text, code) via base64 data URL.
  /// Stores the gateway's `ref_text` (`@file:...`) so [send] can prepend it.
  Future<String> attachFileBytes(List<int> bytes,
      {String name = 'file'}) async {
    final attachGen = _attachGen;
    try {
      final sid = await _ensureSession();
      if (sid == null || sid.isEmpty) {
        // A stale session.create (user switched while it was in flight)
        // returned no usable session — discard the in-flight attach.
        return '';
      }
      final res = await _client.request('file.attach', {
        'session_id': sid,
        'data_url': 'data:;base64,${base64Encode(bytes)}',
        'name': name,
      });
      // Guard: generation check catches sid reuse after a detach+re-resume
      // of the same stored session; sid-only misses that case.
      if (attachGen != _attachGen || sid != _activeSessionId) return '';
      // Prefer ref_text (@file:...) for prompt insertion; fall back to path.
      final ref =
          (res['ref_text'] ?? res['ref'] ?? res['path'] ?? res['name'] ?? '')
              .toString();
      if (ref.isNotEmpty) {
        _pendingAttachments.add(ref);
        _attachmentDetails[ref] = PendingAttachment(ref: ref, filename: name,
            sizeBytes: bytes.length);
      }
      _notify();
      return ref;
    } catch (e) {
      _notify();
      return _shortError(e);
    }
  }

  /// Remove a pending attachment.  For image refs (non-`@file:`) this calls
  /// the gateway's `image.detach` to unqueue the image from the next turn.
  /// File refs (`@file:...`) are local-only since the staged file persists in
  /// the workspace.
  Future<void> detachAttachment(String ref) async {
    if (_sending) return;
    if (_queuedImages.remove(ref) != null) {
      _notify();
      return;
    }
    if (ref.startsWith('@file:')) {
      // File refs: local removal only; staged file persists in workspace.
      _removeAttachment(ref);
      _notify();
      return;
    }
    // Image ref: unqueue on the gateway.
    final sid = _activeSessionId;
    if (sid != null && sid.isNotEmpty) {
      try {
        await ImageAttachmentService(_client, sessionId: sid).detach(ref);
      } catch (_) {
        // Gateway failed — keep the chip so the user can retry.
        _fail('Could not detach image');
        _notify();
        return;
      }
    }
    _removeAttachment(ref);
    _notify();
  }

  // ── HUD / status ───────────────────────────────────────────────────

  Map<String, dynamic> _battery = const {};
  Map<String, dynamic> get battery => _battery;
  Map<String, dynamic> _verification = const {};
  Map<String, dynamic> get verification => _verification;
  Map<String, dynamic> _subscription = const {};
  Map<String, dynamic> get subscription => _subscription;

  bool _voiceOn = false;
  bool get voiceOn => _voiceOn;

  /// Recompute the per-message visible reasoning from the live show/hide flag.
  /// Hiding traces is display-only: the raw text stays in [ChatMessage.reasoning],
  /// so flipping the flag back re-reveals every trace. Cheap (O(messages));
  /// only runs when something changed.
  bool _showReasoningDirty = true;
  void _applyReasoningDisplay() {
    if (!_showReasoningDirty) return;
    _showReasoningDirty = false;
    for (final m in _messages) {
      m.effectiveReasoning = _showReasoning ? m.reasoning : '';
    }
  }

  void _setShowReasoning(bool v) {
    if (v == _showReasoning) return;
    _showReasoning = v;
    _showReasoningDirty = true;
    _applyReasoningDisplay();
  }

  void _notify() {
    _applyReasoningDisplay();
    if (!_disposed) notifyListeners();
  }

  /// Poll the gateway's host battery state (read-only, no side effects).
  Future<void> pollBattery() async {
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('system.battery', const {});
      _battery = res;
      _notify();
    } catch (_) {}
  }

  /// Read-only verification evidence for the active session/cwd.
  Future<void> pollVerification() async {
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request(
          'verification.status', {'session_id': _activeSessionId ?? ''});
      final v = res['verification'];
      if (v is Map<String, dynamic>) _verification = v;
      _notify();
    } catch (_) {}
  }

  /// Read-only subscription preview (usage/entitlements) for the profile.
  Future<void> pollSubscription() async {
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('subscription.preview', const {});
      _subscription = res;
      _notify();
    } catch (_) {}
  }

  /// Toggle push-to-talk voice capture on the gateway (desktop voice parity).
  Future<bool> toggleVoice() async {
    if (_client.state != GwConnectionState.open) return _voiceOn;
    try {
      final res = await _client.request('voice.toggle', const {});
      _voiceOn = res['enabled'] == true || res['on'] == true;
      _notify();
    } catch (_) {}
    return _voiceOn;
  }

  /// Answers locked so far for a batch clarify: `question_id -> answer`.
  /// The gateway replays these on resume, and the card renders a tick per
  /// answered question so a multi-question prompt is not answered blind.
  final Map<String, String> _clarifyAnswers = {};
  Map<String, String> get clarifyAnswers => Map.unmodifiable(_clarifyAnswers);

  /// Answer the pending clarify / approval request.
  ///
  /// Gateway contract (verified in `tui_gateway`, `_respond` + `_clarify_block`):
  ///
  ///   * `clarify.respond {request_id, answer}`                single question
  ///   * `clarify.respond {request_id, question_id, answer}`    one batch question
  ///   * `clarify.respond {request_id}`                         cancel a batch
  ///   * `approval.respond {session_id, request_id, choice}`    once|session|always|deny
  ///
  /// `request_id` is MANDATORY. The previous implementation sent only
  /// `session_id`, so every reply was rejected with 4009 "no pending clarify
  /// request", the card was re-armed by the catch, and the prompt sat on screen
  /// forever (and came back on every resume). It was visible as a card whose
  /// question text had fallen back to "Hermes needs your input" and whose only
  /// button was "No".
  Future<void> respondApproval({
    required bool approved,
    String? choice,
    String? questionId,
  }) async {
    final req = _pendingRequest;
    if (req == null) return; // No pending request to answer.
    final requestId = (req.payload['request_id'] ?? '').toString();
    if (requestId.isEmpty) {
      // Without an id the request can never be answered; drop it rather than
      // trapping the user behind a card that cannot be dismissed.
      _pendingRequest = null;
      _clarifyAnswers.clear();
      _fail('That prompt could not be answered (no request id); it was cleared.');
      return;
    }
    final isBatchQuestion = questionId != null && questionId.isNotEmpty;
    final params = <String, dynamic>{
      'session_id': _activeSessionId,
      'request_id': requestId,
    };
    Future<Map<String, dynamic>> Function() send;
    if (req.type == 'approval.request') {
      params['choice'] = choice ?? (approved ? 'once' : 'deny');
      send = () => _client.request('approval.respond', params);
    } else {
      if (isBatchQuestion) params['question_id'] = questionId;
      params['answer'] = choice ?? (approved ? 'yes' : 'no');
      send = () => _client.request('clarify.respond', params);
    }
    // Optimistically drop the card ONLY for a whole-request answer; a single
    // batch question leaves the prompt parked until every question is locked.
    final wasBatchQuestion = isBatchQuestion;
    if (!wasBatchQuestion) {
      _pendingRequest = null;
      _clarifyAnswers.clear();
      _statusLine = '';
      _notify();
    }
    try {
      final res = await send();
      if (wasBatchQuestion) {
        _clarifyAnswers[questionId] = params['answer'].toString();
        final remaining = res['remaining'];
        if (remaining is List && remaining.isNotEmpty) {
          // Other questions still open: keep the card and the ticks.
          _notify();
          return;
        }
        _pendingRequest = null;
        _clarifyAnswers.clear();
        _statusLine = '';
      }
    } catch (e) {
      final gone = e is GatewayError && (e.code == 4009 || e.code == 4002);
      if (gone) {
        // The gateway no longer holds this request (answered elsewhere, or it
        // expired): clear it instead of re-arming a card that cannot be closed.
        _pendingRequest = null;
        _clarifyAnswers.clear();
        _notify();
        return;
      }
      // A real transport failure keeps the card so the user can retry, and
      // says so: a silent swallow would make an approval look confirmed.
      _pendingRequest = req;
      _fail('Reply not sent: ${_shortError(e)}');
    }
    _notify();
  }

  /// Dismiss the pending request without answering it.
  ///
  /// A batch clarify is cancelled by replying with no `question_id`; an
  /// approval is denied. Best-effort: the card is cleared either way, so a
  /// stale prompt can always be closed from the phone.
  Future<void> dismissPendingRequest() async {
    final req = _pendingRequest;
    if (req == null) return;
    final requestId = (req.payload['request_id'] ?? '').toString();
    _pendingRequest = null;
    _clarifyAnswers.clear();
    _statusLine = '';
    _notify();
    if (requestId.isEmpty) return;
    try {
      if (req.type == 'approval.request') {
        await _client.request('approval.respond', {
          'session_id': _activeSessionId,
          'request_id': requestId,
          'choice': 'deny',
        });
      } else {
        // No question_id = cancel-all for a batch; an empty answer for single.
        await _client.request('clarify.respond', {
          'session_id': _activeSessionId,
          'request_id': requestId,
          'answer': '',
        });
      }
    } catch (_) {
      // Dismissal is best-effort: the card is already gone locally.
    }
  }

  // ── Settings data ──────────────────────────────────────────────────

  Future<void> loadModels() async {
    if (_client.state != GwConnectionState.open) return;
    Map<String, dynamic> res = const {};
    String rawCurrent = '';
    try {
      res = await _client.request('model.options');
      final providers = res['providers'];
      // The gateway returns the actual current model at the top level,
      // e.g. {model: "openai/gpt-4o", provider: "openai", providers: [...]}.
      // Use this to mark only the matching model as current, not every model
      // in the current provider.
      rawCurrent = (res['model'] ?? '').toString();
      _models.clear();
      if (providers is List) {
        for (final p in providers) {
          if (p is! Map) continue;
          final providerSlug = (p['slug'] ?? '') as String;
          final providerIsCurrent = p['is_current'] == true;
          final models = p['models'];
          if (models is List) {
            for (final m in models) {
              final ms = m is String
                  ? m
                  : (m is Map ? (m['slug'] ?? m['id'])?.toString() : null);
              if (ms == null || ms.isEmpty) continue;
              // Match against the top-level current model string.
              // Exact full-slug comparison (provider/model) is the primary
              // match.  A bare-model match (rawCurrent == ms) is only
              // accepted when this provider row is marked is_current,
              // preventing same-named models in *other* providers from
              // being flagged current.
              final fullSlug =
                  providerSlug.isNotEmpty ? '$providerSlug/$ms' : ms;
              final isCurrent = rawCurrent.isNotEmpty &&
                  (rawCurrent == fullSlug ||
                      (providerIsCurrent && rawCurrent == ms));
              _models.add(ModelOption(
                slug: ms,
                provider: providerSlug,
                providerName: p['name'] as String?,
                isCurrent: isCurrent,
                authenticated: p['authenticated'] != false,
                bare: ms.startsWith('$providerSlug/')
                    ? ms.substring(ms.indexOf('/') + 1)
                    : ms,
              ));
            }
          }
        }
      }
    } catch (_) {}
    // Seed the live current-model identity from the gateway's authoritative
    // payload so the picker's checkmark is correct on first paint AND keeps
    // moving after in-app switches (the load-time isCurrent flags are stale
    // after that).
    if (rawCurrent.isNotEmpty) {
      setLiveModel(rawCurrent, provider: res['provider'] as String?);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> loadProfiles() async {
    if (_client.state != GwConnectionState.open) return;
    try {
      final res = await _client.request('profiles.list', const {});
      final list = res['profiles'] ?? res;
      _profiles.clear();
      if (list is List) {
        for (final p in list) {
          if (p is Map) {
            _profiles.add(ProfileInfo(
              name: (p['name'] ?? p['id'] ?? '') as String,
              isDefault: p['is_default'] == true || p['name'] == 'default',
              description: (p['description'] ?? '') as String,
            ));
          } else if (p is String && p.isNotEmpty) {
            _profiles.add(ProfileInfo(name: p, isDefault: p == 'default'));
          }
        }
      }
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  // ── Settings (config.get / config.set) ─────────────────────────────

  /// Allowed values for toggle-style config keys (drives the settings UI).
  /// Values must match what the gateway's `config.set` handler accepts and
  /// what `config.get` returns, so the current selection can be highlighted.
  static const configToggles = <String, List<String>>{
    'fast': ['fast', 'normal', 'auto', 'cold'],
    'reasoning': ['show', 'hide', 'full', 'clamp'],
    'approval_mode': ['manual', 'smart', 'off'],
    'details_mode': ['hidden', 'collapsed', 'expanded'],
    'thinking_mode': ['collapsed', 'truncated', 'full'],
    'theme': ['auto', 'light', 'dark'],
  };

  /// Read the current value of a config [key] (e.g. `fast`, `theme`).
  /// Resolves the raw value string, or null if unknown/offline.
  Future<String?> configGet(String key) async {
    if (_client.state != GwConnectionState.open) return null;
    try {
      // Include session_id so session-scoped keys (fast, reasoning) resolve
      // the session-local value rather than the global default.
      final res = await _client.request('config.get', {
        'key': key,
        'session_id': _activeSessionId ?? '',
      });
      // Getters return either {value: ...}, {value: ..., display: ...},
      // or a bare scalar.  The `display` field (used by the reasoning
      // getter) carries the toggle word the UI needs.
      final v = res['display'] ?? res['value'] ?? res[key] ?? res;
      return v?.toString();
    } catch (_) {
      return null;
    }
  }

  /// Set a config [key] to [value]. Resolves a human result string:
  /// the new value on success, or the confirm/error message. The `model`
  /// key drives the live/deferred model switch (see [setModel]).
  Future<String> configSet(String key, String value) async {
    if (_client.state != GwConnectionState.open) return 'Not connected';
    try {
      final res = await _client.request('config.set', {
        'key': key,
        'value': value,
        'session_id': _activeSessionId ?? '',
      });
      if (res['confirm_required'] == true) {
        return 'Confirm required: ${res['confirm_message'] ?? 'expensive model'}';
      }
      final applied = (res['value'] ?? value).toString();
      _statusLine = '$key = $applied';
      // The `reasoning` key carries TWO fields — effort (value) and
      // show/hide display — and either surface (the header quick-config for
      // effort, the Settings toggle for display) writes it. After a successful
      // set, re-read authoritatively so BOTH local mirrors stay correct; an
      // effort change must not clobber the visibility flag or vice-versa.
      if (key == 'reasoning') {
        await _resyncReasoning();
      }
      _notify();
      return applied;
    } catch (e) {
      final msg = _shortError(e);
      _statusLine = msg;
      _notify();
      return msg;
    }
  }

  /// Make sure a model switch's `session_id` names a LIVE gateway session.
  ///
  /// `config.set model` is applied to the live record named by `session_id`.
  /// When that lookup misses, the gateway still answers with a SUCCESS
  /// envelope while validating the pick against a throwaway record — so a
  /// draft (no session yet) or a stale runtime id (reaped after a WS detach)
  /// leaves the conversation on its old model while the header shows the new
  /// one. Create the draft's session / re-attach the reaped runtime first.
  Future<bool> _ensureModelSwitchTarget() async {
    if (_client.state != GwConnectionState.open) return false;

    // A load or re-attach that is already in flight owns the runtime id, and
    // during one the id is either missing (about to be assigned) or the one
    // being replaced. Wait for it to settle BEFORE choosing a branch: picking a
    // model immediately after opening a conversation is exactly this case, and
    // branching early would either pin the outgoing id or create a throwaway
    // draft session for a conversation that is already loading.
    await _awaitSessionSettled();

    final sid = _activeSessionId;
    if (sid == null || sid.isEmpty) {
      // A genuine draft (nothing loading, no session yet): the switch needs a
      // session to pin to, so create one.
      await _ensureSession();
      final created = _activeSessionId;
      return created != null && created.isNotEmpty;
    }

    final liveness = await _targetIsLive(sid);
    if (liveness != false) return true; // live, or unknowable: do not block

    // Known stale (a reaped runtime id): re-attach the STORED conversation. A
    // successful resume hands back a FRESH runtime id, and that id is itself
    // proof the session is live — do not require the live list to already
    // mention it, because the list can lag a resume.
    final stored = _activeStoredSessionId;
    if (stored != null && stored.isNotEmpty) {
      // A successful re-attach IS the proof of liveness: the gateway handed back
      // a runtime id for it. Do not require the live list to already mention
      // that id (the list can lag) nor that the id differ from the stale one.
      final reattached = await _recoverStaleActiveSession(stored);
      await _awaitSessionSettled();
      // A failed re-attach is evidence, not something to paper over: refuse
      // rather than pinning a model to an id the gateway no longer resolves.
      if (!reattached) return false;
      final fresh = _activeSessionId;
      if (fresh == null || fresh.isEmpty) return false;
      return true;
    }

    // No stored key to re-attach (a draft this app created). An id the gateway
    // handed us, with no drop having invalidated it, is live enough to pin to:
    // a brand-new session can be missing from the live list for a moment.
    return sid == _verifiedLiveSessionId;
  }

  /// Live / not-live / unknown for [sid], from the gateway's live session list.
  /// `null` means the list could not be read at all, which must NOT block a
  /// switch: the probe is a guard against a known-bad target, not a gate.
  Future<bool?> _targetIsLive(String sid) async {
    try {
      final res = await _client
          .request('session.active_list', {'current_session_id': sid});
      if (_disposed) return null;
      final list = res['sessions'];
      if (list is! List) return null;
      return list.any((row) =>
          row is Map &&
          ((row['session_id'] ?? row['id'] ?? '').toString() == sid));
    } catch (_) {
      return null;
    }
  }

  /// Wait, bounded, for an in-flight conversation load or stale-session
  /// re-attach to finish. [_recoverStaleActiveSession] refuses to run while
  /// either flag is set, so without this a switch issued during a load would
  /// probe the outgoing id and pin nothing on the gateway.
  Future<void> _awaitSessionSettled({int maxWaitMs = 8000}) async {
    if (!_loadingSession && !_recoveringStale) return;
    _settleWaitCount++;
    final deadline = DateTime.now().add(Duration(milliseconds: maxWaitMs));
    while (!_disposed &&
        (_loadingSession || _recoveringStale) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  int _settleWaitCount = 0;

  /// Test seam: how many times a probe had to wait for an in-flight load or
  /// re-attach to settle before it could name a live session.
  int get settleWaitCountForTest => _settleWaitCount;
  void resetSettleWaitCountForTest() => _settleWaitCount = 0;

  /// Switch the model for the active session via `config.set model`. [value]
  /// may carry provider flags (e.g. `openai/gpt-5`). When the gateway flags
  /// the model as expensive it returns a `confirm_required` result; pass
  /// [confirmExpensive] to approve.
  Future<SetModelResult> setModel(String value,
      {bool confirmExpensive = false, bool retryOnStale = true}) async {
    if (_client.state != GwConnectionState.open) {
      return const SetModelResult(status: SetModelStatus.disconnected);
    }
    // The switch must land on THIS conversation's live record, or the pick
    // pins nowhere (see _ensureModelSwitchTarget). When the target cannot be
    // made live, do NOT send the switch: the gateway answers a success
    // envelope for an unresolvable session while applying nothing, which shows
    // the new model in the header and keeps running the old one.
    final targeted = await _ensureModelSwitchTarget();
    if (_disposed) {
      return const SetModelResult(status: SetModelStatus.disconnected);
    }
    if (!targeted) {
      final msg =
          'The model was not changed: this conversation is not live on the gateway yet. '
          'Try again once it has finished loading.';
      _fail(msg);
      return SetModelResult(status: SetModelStatus.error, error: msg);
    }
    try {
      final res = await _client.request('config.set', {
        'key': 'model',
        'value': value,
        'session_id': _activeSessionId ?? '',
        'confirm_expensive_model': confirmExpensive,
      });
      if (res['confirm_required'] == true) {
        _statusLine =
            'Expensive model: ${res['confirm_message'] ?? 'confirm to continue'}';
        _notify();
        return SetModelResult(
          status: SetModelStatus.confirmRequired,
          value: (res['value'] ?? value).toString(),
          confirmMessage: (res['confirm_message'] ?? '').toString(),
        );
      }
      final applied = (res['value'] ?? value).toString();
      // The gateway always reports a `warning` field and uses it to say the
      // pick could NOT be applied (it runs its selection guards, and on a
      // warning applies nothing while still answering success). Reporting that
      // as applied is how the header ends up disagreeing with the model that
      // actually runs.
      final warning = (res['warning'] ?? '').toString().trim();
      if (warning.isNotEmpty) {
        _fail('Model not changed: $warning');
        return SetModelResult(
          status: SetModelStatus.error,
          value: applied,
          error: warning,
        );
      }
      // Parse the `--provider X` suffix that the gateway returns verbatim
      // (the picker appends it when the model lives under a named provider).
      final parts = applied.split(' --provider ');
      final liveModel = parts.first.trim();
      final liveProvider = parts.length > 1 ? parts.last.trim() : null;
      setLiveModel(liveModel,
          provider: liveProvider != null && liveProvider.isNotEmpty
              ? liveProvider
              : null);
      // `deferred` is the gateway's stashed-while-a-turn-streams path: the pick
      // is applied at the NEXT turn start and the gateway deliberately displays
      // it meanwhile. Show it, but say when it takes effect instead of implying
      // the conversation is already running it.
      if (res['deferred'] == true) {
        _statusLine = 'Model: $applied (applies from the next turn)';
        _notify();
        return SetModelResult(
          status: SetModelStatus.deferred,
          value: applied,
        );
      }
      _statusLine = 'Model: $applied';
      _notify();
      return SetModelResult(
        status: SetModelStatus.success,
        value: applied,
      );
    } catch (e) {
      // The gateway answers 4001 "session not found" when the NAMED session is
      // gone (config.set is session-scoped). That is not a user-facing error:
      // re-attach the stored conversation and retry once, exactly like send()'s
      // stale-runtime recovery.
      final stored = _activeStoredSessionId;
      if (retryOnStale &&
          e is GatewayError &&
          e.code == 4001 &&
          stored != null &&
          stored.isNotEmpty) {
        await _recoverStaleActiveSession(stored);
        if (!_disposed && _client.state == GwConnectionState.open) {
          return setModel(value,
              confirmExpensive: confirmExpensive, retryOnStale: false);
        }
      }
      final msg = _shortError(e);
      _fail(msg);
      return SetModelResult(
        status: SetModelStatus.error,
        error: msg,
      );
    }
  }

  static String _shortError(Object e) {
    // GatewayError.toString() prefixes the message with 'GatewayError(N): '
    // (or 'GatewayError(-): ' when codeless); strip it so status lines and
    // the per-message failure caption read cleanly.
    var s = e.toString();
    final m = RegExp(r'^GatewayError\(([^)]*)\):\s*').firstMatch(s);
    if (m != null) s = s.substring(m.end);
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  Future<void> disconnect() async {
    ++_attachGen;
    _sessRefreshTimer?.cancel();
    _sessRefreshPending = false;
    // Use a short detach cap: if the transport is already dead (e.g.
    // socket closed) the default 120s request timeout would stall the
    // entire disconnect. Refs are PRESERVED (not cleared) on timeout
    // so the user can re-attempt after reconnect; the queued images
    // are still bound to the old session on the gateway.
    await _detachPending(
      sessionId: _activeSessionId,
      timeout: const Duration(seconds: 20),
    );

    // Ordinary Disconnect must leave the GatewayClient reusable — the
    // connection sheet offers Reconnect. dispose() permanently poisons the
    // client and belongs only in ChatStore.dispose() during app teardown.
    _client.close();
    await _fg.stop();
    _conn = GwConnectionState.closed;
    _activeSessionId = null;
    _activeStoredSessionId = null;
    _pendingRequest = null;
    _sessions.clear();
    _messages.clear();
    _activeGoal = null;
    _streaming = false;
    _statusLine = '';
    // Drop the tracked live state so a reconnect to a different gateway
    // never shows dots/status from the previous connection.
    _sessionDotStates.clear();
    _lastGatewayStatus = '';
    _activeSessionSeenLive = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _eventSub?.cancel();
    _sessRefreshTimer?.cancel();
    // Defensive native cleanup for app/model teardown paths that bypass the
    // explicit Disconnect/Quit action. Manifest stopWithTask remains a
    // secondary Android safeguard.
    unawaited(_fg.stop());
    _client.dispose();
    _notifier.dispose();
    if (!_notices.isClosed) unawaited(_notices.close());
    super.dispose();
  }
}
