import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';

import 'config.dart';
import 'http_service.dart';

enum GwConnectionState { idle, connecting, open, closed, error, reconnecting }

/// Event envelope the gateway emits:
/// `{"jsonrpc":"2.0","method":"event","params":{"type":..., "session_id":..., "seq":N, "payload":{...}}}`
class GatewayEvent {
  const GatewayEvent({
    required this.type,
    this.sessionId,
    this.seq,
    this.payload = const {},
  });

  final String type;
  final String? sessionId;
  final int? seq;
  final Map<String, dynamic> payload;

  factory GatewayEvent.fromParams(Map<String, dynamic> p) => GatewayEvent(
        type: (p['type'] ?? '') as String,
        sessionId: p['session_id'] as String?,
        seq: p['seq'] is int ? p['seq'] as int : null,
        payload: p['payload'] is Map<String, dynamic>
            ? p['payload'] as Map<String, dynamic>
            : const {},
      );

  String get text => (payload['text'] ?? '') as String;
  String get name => (payload['name'] ?? '') as String;
}

class GatewayError implements Exception {
  GatewayError(this.message, {this.code, this.data});
  final String message;
  final int? code;
  final Object? data;
  @override
  String toString() => 'GatewayError(${code ?? '-'}): $message';
}

/// JSON-RPC 2.0 client over the Hermes tui_gateway WebSocket sidecar.
///
/// Mirrors apps/shared/src/json-rpc-gateway.ts: request/response pairing by
/// id, `event`-method push frames, `gateway.ping` heartbeat (15s), per-session
/// seq watermarks + `session.events.since` replay on reconnect, and
/// full-jitter exponential backoff auto-reconnect (apps/desktop reconnect-backoff.ts:
/// base 300ms, cap 15s, delay = random * min(cap, base * 2^attempt)).
/// A request FROM the gateway that this client must ANSWER: an approval
/// decision, a sudo password, a secret value.
///
/// The gateway writes these as ordinary JSON-RPC request frames
/// (`{"jsonrpc":"2.0","id":N,"method":"approval","params":{...}}`) and holds
/// the agent until the matching reply arrives or its own timeout fires. They
/// carry an `id` exactly like a response to one of our calls does, which is why
/// a client that treats every id-carrying frame as a response silently drops
/// them and leaves the agent parked.
///
/// The method set is the gateway's `SERVER_REQUESTS` contract
/// (`tui_gateway/contracts/server_requests.py`).
class ServerRequest {
  const ServerRequest({
    required this.id,
    required this.method,
    this.params = const {},
    this.sessionId,
  });

  final Object id;
  final String method;
  final Map<String, dynamic> params;
  final String? sessionId;

  /// The id of the exact approval this resolves.
  String get requestId => (params['request_id'] ?? '').toString();

  /// Choices the gateway will accept, e.g. once/session/always/deny.
  List<String> get approvalChoices {
    final raw = params['choices'];
    if (raw is List) {
      return raw.map((e) => e.toString()).toList(growable: false);
    }
    return const <String>['once', 'deny'];
  }

  /// True when the expected answer is one string under `value`: the sudo
  /// password and secret prompts, and the vault/GUI reads.
  bool get wantsValue => const <String>{
        'sudo',
        'secret',
        'vault.unlock_prompt',
        'vault.save_login',
        'vault.code',
        'terminal.read',
        'preview.read',
        'window.read',
        'preview.act',
        'tour',
      }.contains(method);
}

/// Classify an inbound frame: a request FROM the gateway that we must answer,
/// or null when it is a response to one of our own calls, or an event.
///
/// This one distinction is what the app got wrong. A request and a response both
/// carry `id`; only a request carries `method`. Code that treats every
/// id-carrying frame as a response finds no pending call and returns, which
/// silently drops approvals and sudo prompts while the agent waits for its
/// timeout. Extracted and pure so that mistake stays testable.
ServerRequest? serverRequestFromFrame(Map<String, dynamic> frame) {
  final id = frame['id'];
  if (id == null || (id is! String && id is! int)) return null;
  final method = frame['method'];
  // `event` frames carry params but are one-way notifications, not requests.
  if (method is! String || method == 'event') return null;
  final rawParams = frame['params'];
  final params =
      rawParams is Map<String, dynamic> ? rawParams : const <String, dynamic>{};
  return ServerRequest(
    id: id,
    method: method,
    params: params,
    sessionId: params['session_id'] as String?,
  );
}

class GatewayClient {
  GatewayClient(this.config, {this.autoReconnect = true})
      : _rng = Random();

  final GatewayConfig config;

  /// When true (default), a non-manual close/error schedules a backoff reconnect.
  /// Set false in tests or when the owner wants to drive reconnection itself.
  final bool autoReconnect;
  final Random _rng;

  /// Invoked before each (re)connect that re-authenticates. The store uses this
  /// to refresh an expired OAuth token in [config.oauthToken] and mint fresh
  /// tickets. Failures are surfaced as connection errors.
  Future<void> Function()? beforeConnect;

  /// Backoff tuning (defaults match the desktop).
  final int baseBackoffMs = 300;
  final int capBackoffMs = 15000;

  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _eventController = StreamController<GatewayEvent>.broadcast();
  final _stateController = StreamController<GwConnectionState>.broadcast();
  final _requestController = StreamController<ServerRequest>.broadcast();

  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  int _idSeq = 0;
  int _hbSeq = 0;
  Timer? _hbTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  DateTime _lastInbound = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, int> _lastSeenSeq = {};
  String? _replayEpoch;
  bool _replayInFlight = false;
  Map<String, List<GatewayEvent>>? _replayHold;
  bool _manualClose = false;
  bool _disposed = false;
  bool _connectInFlight = false;

  /// Shared connection future: the primary connect() returns this, and any
  /// concurrent connect() call made while one is in flight returns the same
  /// future. It completes cleanly only when the socket is actually open, and
  /// with a [GatewayError] on any failure or cancellation — cancellation
  /// therefore never reports a successful open to callers.
  Completer<void>? _connectCompleter;
  int _joinerCount = 0;

  /// Incremented on every new connect attempt and by every close()/dispose().
  /// Every await-continuation in connect() captures the generation it was
  /// created in and re-validates it, and every channel callback
  /// (_onDone/_onError) is generated by an attempt's epoch, so late callbacks
  /// from an orphaned channel and late continuations from a cancelled or
  /// superseded attempt are dead paths.
  int _generation = 0;
  GwConnectionState _state = GwConnectionState.idle;

  GwConnectionState get state => _state;
  Stream<GwConnectionState> get stateChanges => _stateController.stream;

  /// How many reconnect attempts have been made in the current outage episode
  /// (0 = healthy or never disconnected). Reset on a successful open.
  int get reconnectAttempt => _reconnectAttempt;

  /// All gateway events (every type). Subscribe and filter, or use
  /// [eventStreamFor].
  Stream<GatewayEvent> get events => _eventController.stream;

  /// Requests from the gateway that need an ANSWER: approvals, sudo passwords
  /// and secrets. The agent is blocked until each one is answered (see
  /// [respondToServerRequest]).
  Stream<ServerRequest> get serverRequests => _requestController.stream;

  /// Answer a [ServerRequest]. Every request must be answered: one that is
  /// ignored leaves the agent waiting for the gateway's own timeout, which
  /// looks to the user like a hung turn.
  void respondToServerRequest(Object id, Map<String, dynamic> result) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    } catch (_) {
      // The socket is gone; the gateway's own timeout resolves it.
    }
  }

  /// Subscribe to one event type, e.g. 'message.delta'.
  Stream<GatewayEvent> eventStreamFor(String type) =>
      _eventController.stream.where((e) => e.type == type);

  /// Subscribe to session-scoped events.
  Stream<GatewayEvent> eventsForSession(String sid) =>
      _eventController.stream.where((e) => e.sessionId == sid);

  void _setState(GwConnectionState s) {
    if (s == _state) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  /// Open the socket. If [isReconnect] is true the state shows `reconnecting`
  /// first (so the UI can distinguish a fresh connect from a recovery dial).
  /// Every dial-path failure is surfaced as a [GatewayError] and schedules a
  /// backoff reconnect (unless manually closed / disposed / autoReconnect off).
  Future<void> connect({bool isReconnect = false}) async {
    if (_connectInFlight) {
      // Join the in-flight attempt: same future, same success or failure.
      _joinerCount++;
      return _connectCompleter!.future;
    }
    if (_state == GwConnectionState.open) return;
    if (_disposed) {
      throw GatewayError('gateway not connected');
    }
    // Refuse a cleartext destination that is not local BEFORE opening a
    // socket: pointing the app at a public host over plain http would put the
    // session token and every prompt on the wire in the clear. This is a
    // configuration problem, so it is reported rather than retried.
    final refusal = config.cleartextRefusal;
    if (refusal != null) {
      throw GatewayError(refusal);
    }
    _manualClose = false;
    _setState(isReconnect ? GwConnectionState.reconnecting : GwConnectionState.connecting);
    _connectInFlight = true;
    _connectCompleter = Completer<void>();
    final gen = ++_generation;
    try {
      try {
        if (beforeConnect != null) {
          await beforeConnect!();
        }
        // close()/dispose() during auth cancels the whole attempt: no socket,
        // no open state, no reconnect, and callers see an error — a cancelled
        // attempt must not report a successful open.
        if (_disposed || _manualClose || gen != _generation) {
          throw GatewayError('connection cancelled during auth');
        }
        final http = GatewayHttp(config);
        String? ticket;
        try {
          ticket = await http.mintWsTicket();
        } finally {
          http.close();
        }
        if (_disposed || _manualClose || gen != _generation) {
          throw GatewayError('connection cancelled during auth');
        }
        // A reconnect replaces the channel + subscription: cancel the old
        // one first so a late done/error from a replaced channel cannot
        // reach its handler as a stale callback (generation guards cover
        // await continuations; this kills the event source itself).
        _sub?.cancel();
        _sub = null;
        _channel = IOWebSocketChannel.connect(
          Uri.parse(config.wsUrl(ticket: ticket)),
          headers: {
            for (final e in config.authHeaders.entries) e.key: e.value,
          },
        );
        // Subscribe before awaiting ready so a fast `gateway.ready` is not lost.
        _sub = _channel!.stream.listen(_onMessage,
            onDone: _onDone, onError: _onError);
        await _channel!.ready.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        _cleanupChannel();
        final wrapped = GatewayError('WebSocket connection timed out');
        _failReconnect(wrapped, gen);
        throw wrapped;
      } catch (e) {
        final cancellation = e is GatewayError &&
            e.message == 'connection cancelled during auth';
        _cleanupChannel();
        if (cancellation) rethrow; // already torn down; do not schedule
        final wrapped =
            e is GatewayError ? e : GatewayError('WebSocket connection failed: $e');
        _failReconnect(wrapped, gen);
        throw wrapped;
      }
      // Continuation of the ready-await: close()/dispose() can land between
      // the socket accepting and ready completing. Without this check the
      // state would advance to open unguarded.
      if (_disposed || _manualClose || gen != _generation) {
        _cleanupChannel();
        throw GatewayError('connection cancelled during handshake');
      }
      _setState(GwConnectionState.open);
      _lastInbound = DateTime.now();
      _reconnectAttempt = 0;
      unawaited(_fetchReplay(gen));
    } finally {
      _connectInFlight = false;
      final c = _connectCompleter;
      _connectCompleter = null;
      final hadJoiners = _joinerCount > 0;
      _joinerCount = 0;
      if (c != null && !c.isCompleted) {
        if (hadJoiners && _state != GwConnectionState.open) {
          // Joiners observe the shared future's error; the primary
          // already got the rethrown exception directly.
          c.completeError(GatewayError('gateway connect failed'));
        } else {
          c.complete();
        }
      }
    }
  }

  void _failReconnect(GatewayError e, int gen) {
    // Superseded generation (a newer attempt started) or a closed/disposed
    // client: this failure — whether a live one or a stale callback from an
    // orphaned channel — must not touch state or schedule a reconnect on a
    // closed stream. In-flight pending requests are deliberately NOT
    // rejected here: a normal reconnect must not wipe them; they are
    // rejected only by close()/dispose().
    if (gen != _generation || _manualClose || _disposed) {
      if (gen == _generation) _setState(GwConnectionState.closed);
      return;
    }
    _setState(GwConnectionState.error);
    _scheduleReconnect();
  }

  /// Full-jitter exponential backoff delay for reconnect [attempt] (0-indexed),
  /// in the range `[0, min(cap, base * 2^attempt))`. Matches the desktop.
  Duration reconnectDelay(int attempt) {
    final safe = attempt < 0 ? 0 : attempt;
    // 2**safe cannot overflow in practice (would need ~30 attempts to exceed
    // the cap), and the min against cap keeps the ceiling bounded.
    var ceiling = baseBackoffMs;
    for (var i = 0; i < safe && ceiling < capBackoffMs; i++) {
      ceiling = (ceiling * 2) > capBackoffMs ? capBackoffMs : (ceiling * 2);
    }
    if (ceiling > capBackoffMs) ceiling = capBackoffMs;
    final ms = ceiling == 0 ? 0 : _rng.nextInt(ceiling);
    return Duration(milliseconds: ms);
  }

  /// Schedule a backoff reconnect. No-op on manual close, disposed clients, or
  /// when auto-reconnect is disabled. Bumping [_generation] orphans the failed
  /// channel's pending onDone/onError callbacks so a late stream event can
  /// never re-trigger teardown on a closed client.
  void _scheduleReconnect() {
    if (_manualClose || _disposed || !autoReconnect) {
      _setState(GwConnectionState.closed);
      return;
    }
    ++_generation;
    _reconnectTimer?.cancel();
    final attempt = _reconnectAttempt++;
    _setState(GwConnectionState.reconnecting);
    final delay = reconnectDelay(attempt);
    final gen = _generation;
    _reconnectTimer = Timer(delay, () {
      if (gen != _generation || _manualClose || _disposed) return;
      // A failed dial re-schedules itself via _failReconnect, so swallow the
      // rejection here — we must not double-schedule.
      unawaited(connect(isReconnect: true).catchError((Object _) {}));
    });
  }

  /// Teardown shared by close() and dispose(): cancels all timers, cancels the
  /// stream subscription, closes the socket, and bumps the generation so every
  /// in-flight connect() continuation and orphaned channel callback becomes a
  /// no-op.
  void _stopAndOrphan() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopHeartbeat();
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    ++_generation;
  }

  void close() {
    _manualClose = true;
    _stopAndOrphan();
    _setState(GwConnectionState.closed);
    _rejectAll(GatewayError('gateway closed'));
  }

  /// Detach an in-use channel (and its heartbeat/subscription) after the
  /// attempt that opened it has already failed or been cancelled. Does not
  /// bump the generation — the caller owns the failure path.
  void _cleanupChannel() {
    _stopHeartbeat();
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _onDone() {
    if (_manualClose || _disposed) return;
    _stopHeartbeat();
    _rejectAll(GatewayError('WebSocket closed'));
    _scheduleReconnect();
  }

  void _onError(Object e) {
    if (_manualClose || _disposed) return;
    _stopHeartbeat();
    _rejectAll(GatewayError('WebSocket error: $e'));
    _scheduleReconnect();
  }

  void _onMessage(dynamic raw) {
    _lastInbound = DateTime.now();
    final text = raw is String ? raw : utf8.decode(raw as List<int>);
    dynamic frameRaw;
    try {
      frameRaw = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (frameRaw is! Map<String, dynamic>) return;

    // Request frame FROM the gateway. It carries an `id` exactly like a
    // response to one of our calls does, so this test has to come FIRST: the
    // old code treated every id-carrying frame as a response, found no matching
    // pending call, and returned — silently discarding approvals and sudo
    // prompts while the agent sat waiting for its timeout. A response never
    // carries `method`.
    final asRequest = serverRequestFromFrame(frameRaw);
    if (asRequest != null) {
      _requestController.add(asRequest);
      return;
    }

    // Request/response frame.
    final id = frameRaw['id'];
    if (id != null && (id is String || id is int)) {
      if (frameRaw.containsKey('error')) {
        final err = frameRaw['error'];
        final call = _pending.remove(id.toString());
        if (call != null && err is Map) {
          call.completeError(GatewayError(
            (err['message'] ?? 'Hermes RPC failed').toString(),
            code: err['code'] is int ? err['code'] as int : null,
            data: err['data'],
          ));
        }
        return;
      }
      final call = _pending.remove(id.toString());
      if (call != null) {
        call.complete(
            frameRaw['result'] is Map<String, dynamic>
                ? frameRaw['result'] as Map<String, dynamic>
                : <String, dynamic>{'result': frameRaw['result']});
      }
      return;
    }

    // Event frame.
    if (frameRaw['method'] == 'event' &&
        frameRaw['params'] is Map<String, dynamic>) {
      final ev = GatewayEvent.fromParams(frameRaw['params'] as Map<String, dynamic>);
      if (ev.type == 'gateway.ready') {
        final payload = ev.payload;
        // Tell the gateway this client ANSWERS server->client requests. Without
        // it the gateway fails every approval / sudo / secret request fast:
        // `client.capabilities` in tui_gateway/methods_voice.py states that "a
        // WebSocket client that never sends it gets every such request failed
        // fast instead of stalling the agent". That is why no approval prompt
        // ever appeared in the app while the desktop showed one. The
        // advertisement is per CONNECTION, so it is re-sent on every ready,
        // which covers reconnects.
        unawaited(_advertiseCapabilities());
        // Start the liveness ping UNCONDITIONALLY. The gateway implements
        // `gateway.ping` (tui_gateway/ws.py), but it does not advertise
        // `heartbeat: true`, so gating on that flag meant the timer never ran
        // and a silently dropped network left the app believing it was still
        // connected, with no teardown and therefore no reconnect.
        _startHeartbeat();
        if (payload['replay_epoch'] is String) {
          _adoptReplayEpoch(payload['replay_epoch'] as String);
        }
      }
      final sid = ev.sessionId;
      if (_replayHold != null &&
          sid != null &&
          ev.seq != null &&
          _replayHold!.containsKey(sid)) {
        _replayHold![sid]!.add(ev);
        return;
      }
      _recordSeq(ev);
      _dispatch(ev);
    }
  }

  void _recordSeq(GatewayEvent ev) {
    final sid = ev.sessionId;
    final seq = ev.seq;
    if (sid == null || seq == null) return;
    final prev = _lastSeenSeq[sid] ?? 0;
    if (seq > prev) _lastSeenSeq[sid] = seq;
  }

  Future<void> _fetchReplay(int gen) async {
    if (_replayInFlight || _lastSeenSeq.isEmpty) return;
    _replayInFlight = true;
    _replayHold = {
      for (final s in _lastSeenSeq.keys) s: <GatewayEvent>[],
    };
    try {
      for (final entry in Map<String, int>.from(_lastSeenSeq).entries) {
        // Generation guard on every replay step: a close/dispose (or a newer
        // attempt) mid-replay stops the fetch instead of issuing requests
        // against a dead channel.
        if (gen != _generation || _disposed || _manualClose) return;
        try {
          final res = await request(
            'session.events.since',
            {'session_id': entry.key, 'last_seen': entry.value},
            10000,
          );
          final events = res['events'];
          if (events is List) {
            for (final e in events) {
              if (e is Map && e['type'] != null) {
                _dispatchIfNewer(GatewayEvent(
                  type: e['type'] as String,
                  sessionId: e['session_id'] as String?,
                  seq: e['seq'] is int ? e['seq'] as int : null,
                  payload: e['payload'] is Map<String, dynamic>
                      ? e['payload'] as Map<String, dynamic>
                      : const {},
                ));
              }
            }
          }
        } catch (_) {
          // Replay is best-effort.
        }
      }
    } finally {
      _flushReplayHold();
      _replayInFlight = false;
    }
  }

  void _dispatchIfNewer(GatewayEvent ev) {
    final sid = ev.sessionId;
    final seq = ev.seq;
    if (sid != null && seq != null) {
      final prev = _lastSeenSeq[sid] ?? 0;
      if (seq <= prev) return;
      _lastSeenSeq[sid] = seq;
    }
    _dispatch(ev);
  }

  void _adoptReplayEpoch(String epoch) {
    if (_replayEpoch == epoch) return;
    if (_replayEpoch != null) _lastSeenSeq.clear();
    _replayEpoch = epoch;
  }

  void _flushReplayHold() {
    final parked = _replayHold;
    _replayHold = null;
    if (parked == null) return;
    for (final list in parked.values) {
      for (final ev in list) {
        _dispatchIfNewer(ev);
      }
    }
  }

  void _dispatch(GatewayEvent ev) {
    if (!_eventController.isClosed) _eventController.add(ev);
  }

  /// JSON-RPC request. Resolves with the `result` object.
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
    int timeoutMs = 120000,
  ]) async {
    final ch = _channel;
    if (ch == null || _state != GwConnectionState.open) {
      throw GatewayError('gateway not connected');
    }
    final id = 'r${++_idSeq}';
    // Serialize BEFORE registering the pending completer: a synchronous
    // jsonEncode failure (e.g. a non-JSON parameter) must propagate straight
    // to the caller without ever completing a completer that no await is
    // attached to — that is what would surface as an unhandled async error.
    final frame;
    try {
      frame = jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
    } catch (e) {
      throw GatewayError('request serialization failed: $e');
    }
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    var cancelled = false;
    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      if (_pending.remove(id) != null) {
        cancelled = true;
        completer.completeError(
            GatewayError('request timed out after ${timeoutMs ~/ 1000}s: $method'));
      }
    });
    try {
      ch.sink.add(frame);
      final result = await completer.future;
      // The success path removes the pending entry, so this only reaps the
      // timer resource that would otherwise run until timeoutMs.
      timer.cancel();
      return result;
    } catch (e) {
      timer.cancel();
      if (!cancelled) {
        _pending.remove(id);
        if (!completer.isCompleted) {
          completer.completeError(e is GatewayError ? e : GatewayError('$e'));
        }
      }
      rethrow;
    }
  }

  /// Tell the gateway this client can answer server->client requests.
  ///
  /// Best-effort on purpose: a gateway older than this method answers an error,
  /// which is not worth surfacing, and the connection is unaffected either way.
  Future<void> _advertiseCapabilities() async {
    try {
      await request('client.capabilities', {'server_requests': true});
    } catch (_) {
      // Older gateway, or a transient failure: nothing to do.
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _lastInbound = DateTime.now();
    _hbTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_state != GwConnectionState.open || _channel == null) return;
      if (DateTime.now().difference(_lastInbound) >=
          const Duration(seconds: 45)) {
        // Liveness lost — tear down and let the reconnect loop recover.
        _channel?.sink.close();
        return;
      }
      try {
        _channel!.sink.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': 'heartbeat-${++_hbSeq}',
          'method': 'gateway.ping',
          'params': <String, dynamic>{},
        }));
      } catch (_) {
        _channel?.sink.close();
      }
    });
  }

  void _stopHeartbeat() {
    _hbTimer?.cancel();
    _hbTimer = null;
  }

  void _rejectAll(GatewayError e) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
    _pending.clear();
  }

  Future<void> dispose() async {
    _disposed = true;
    _manualClose = true;
    _stopAndOrphan();
    _setState(GwConnectionState.closed);
    _rejectAll(GatewayError('disposed'));
    await _eventController.close();
    await _stateController.close();
    await _requestController.close();
  }
}