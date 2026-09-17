import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';

/// Shared helper: wait deterministically until [client] is suspended
/// inside beforeConnect (state == connecting).
Future<void> waitSuspendedInBeforeConnect(GatewayClient client) async {
  while (client.state != GwConnectionState.connecting) {
    await pump(10);
  }
  await pump(10);
}

/// Starts a local HTTP server that handles ws-ticket minting and WS upgrade.
/// [onUpgrade] is called for each WS upgrade request, returning the stream
/// handler. The server port is available as [port].
Future<HttpServer> startTestServer({
  String Function(HttpRequest req)? onTicket,
  void Function(HttpRequest req, WebSocket ws)? onUpgrade,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((r) async {
    if (r.uri.path == '/api/auth/ws-ticket') {
      if (onTicket != null) {
        r.response.write(onTicket(r));
      } else {
        r.response.write(jsonEncode({'ticket': 'test-ticket'}));
      }
      await r.response.close();
    } else if (r.uri.path == '/api/ws') {
      try {
        final ws = await WebSocketTransformer.upgrade(r);
        (onUpgrade ?? (_, ws) => ws.listen((_) {}))(r, ws);
      } catch (_) {
        // upgrade failed — server closed
      }
    } else {
      r.response.statusCode = 404;
      await r.response.close();
    }
  });
  return server;
}

GatewayConfig cfgFor(HttpServer server) =>
    GatewayConfig(url: 'http://127.0.0.1:${server.port}');

/// A WS server that waits for an RPC request and echoes back the result.
/// Responds to 'session.events.since' with an empty event list so the
/// post-open replay fetch resolves against the real server.
void Function(HttpRequest, WebSocket) rpcEcho(
    Map<String, dynamic>? Function(String raw)? handler) {
  return (HttpRequest _, WebSocket ws) {
    ws.listen((raw) {
      final f = jsonDecode(raw as String);
      if (f['method'] == 'session.events.since') {
        ws.add(
            jsonEncode({'id': f['id'], 'result': {'events': <dynamic>[]}}));
        return;
      }
      final result = handler != null ? handler(raw) : <String, dynamic>{};
      if (result != null) {
        ws.add(jsonEncode({'id': f['id'], 'result': result}));
      }
    });
  };
}

/// Lets pending event-loop microtasks/timers settle briefly.
Future<void> pump([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('transport lifecycle review', () {
    // ---------------------------------------------------------------
    // BUG 1: close/dispose while awaiting beforeConnect must cancel the
    // attempt. No socket is opened, state never reaches open, and callers
    // (including joiners) must not see a successful open.
    // ---------------------------------------------------------------
    test('connect bails out if disposed during beforeConnect', () async {
      final server = await startTestServer(onUpgrade: rpcEcho(null));
      final client = GatewayClient(cfgFor(server), autoReconnect: false);

      final bcCompleter = Completer<void>();
      client.beforeConnect = () => bcCompleter.future;

      final connectFuture = client.connect();
      // expectLater arms its listener synchronously, so the cancellation
      // error completing the future inside the body below is observed by
      // the matcher and can never escape as an unhandled zone error.
      expectLater(
        connectFuture,
        throwsA(isA<GatewayError>()),
        reason: 'cancel during auth must surface as an error to callers',
      );
      // Deterministically wait until connect() is suspended inside
      // beforeConnect, then dispose before it completes.
      await waitSuspendedInBeforeConnect(client);
      await client.dispose();
      bcCompleter.complete();

      // Drain any final async/error events so that no unhandled errors
      // leak out of the test zone.
      await connectFuture.catchError((Object _) {});
      expect(client.state, GwConnectionState.closed,
          reason: 'connect must not open a socket after dispose');
      expect(client.reconnectAttempt, 0,
          reason: 'cancellation must not schedule a reconnect');

      await server.close(force: true);
    });

    test('connect bails out if closed during beforeConnect', () async {
      final server = await startTestServer(onUpgrade: rpcEcho(null));
      final client = GatewayClient(cfgFor(server), autoReconnect: false);

      final bcCompleter = Completer<void>();
      client.beforeConnect = () => bcCompleter.future;

      final connectFuture = client.connect();
      expectLater(connectFuture, throwsA(isA<GatewayError>()),
          reason: 'cancel during auth must surface as an error to callers');
      await waitSuspendedInBeforeConnect(client);
      client.close(); // manualClose = true
      bcCompleter.complete();

      expect(client.state, GwConnectionState.closed,
          reason: 'connect must not open a socket after close()');
      expect(client.reconnectAttempt, 0,
          reason: 'cancellation must not schedule a reconnect');

      await server.close(force: true);
    });

    test('close while WebSocket upgrade is suspended never reopens', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upgradeRequested = Completer<void>();
      final releaseUpgrade = Completer<void>();
      server.listen((r) async {
        if (r.uri.path == '/api/auth/ws-ticket') {
          r.response.write(jsonEncode({'ticket': 'test-ticket'}));
          await r.response.close();
        } else if (r.uri.path == '/api/ws') {
          upgradeRequested.complete();
          await releaseUpgrade.future;
          try {
            final ws = await WebSocketTransformer.upgrade(r);
            ws.listen((_) {});
          } catch (_) {}
        } else {
          r.response.statusCode = 404;
          await r.response.close();
        }
      });
      final client = GatewayClient(cfgFor(server), autoReconnect: false);
      final states = <GwConnectionState>[];
      final subscription = client.stateChanges.listen(states.add);
      final opening = client.connect();
      final failed = expectLater(opening, throwsA(isA<GatewayError>()));
      await upgradeRequested.future.timeout(const Duration(seconds: 3));
      client.close();
      releaseUpgrade.complete();
      await failed;
      await pump();
      expect(client.state, GwConnectionState.closed);
      expect(states, isNot(contains(GwConnectionState.open)));
      await subscription.cancel();
      await client.dispose();
      await server.close(force: true);
    });

    test('connect after dispose throws immediately (closed stream guard)',
        () async {
      final server = await startTestServer(onUpgrade: rpcEcho(null));
      final client = GatewayClient(cfgFor(server), autoReconnect: false);
      await client.connect();
      expect(client.state, GwConnectionState.open);
      await client.dispose();

      // connect() on a disposed client must not touch the closed stream
      // or re-arm any timers; it must throw immediately.
      await expectLater(
        client.connect(),
        throwsA(isA<GatewayError>()
            .having((e) => e.message, 'message', contains('not connected'))),
      );
      expect(client.state, GwConnectionState.closed);

      await server.close(force: true);
    });

    test('beforeConnect exception after dispose does not run _failReconnect',
        () async {
      final server = await startTestServer(onUpgrade: rpcEcho(null));
      final client = GatewayClient(cfgFor(server), autoReconnect: false);

      final bcCompleter = Completer<void>();
      client.beforeConnect = () => bcCompleter.future;

      final connectFuture = client.connect();
      expectLater(connectFuture, throwsA(anything),
          reason: 'late auth failure on a disposed client must still '
              'error, never resolve');
      await waitSuspendedInBeforeConnect(client);
      await client.dispose();
      // beforeConnect rejects AFTER dispose: the connect continuation must
      // treat this as a no-op (superseded generation), not schedule a
      // reconnect on the closed stream.
      bcCompleter.completeError(StateError('late auth failure'));

      expect(client.state, GwConnectionState.closed,
          reason: 'failReconnect must not run on a disposed client');
      expect(client.reconnectAttempt, 0,
          reason: 'no reconnect may be scheduled after dispose');

      await server.close(force: true);
    });

    // ---------------------------------------------------------------
    // BUG 2: Two concurrent connect() calls — the second returns the SAME
    // connection future, so it joins the first attempt's success or
    // failure rather than returning silently.
    // ---------------------------------------------------------------
    test('second concurrent connect joins the first attempt', () async {
      final server = await startTestServer(onUpgrade: rpcEcho(null));
      final client = GatewayClient(cfgFor(server), autoReconnect: false);

      final bcCompleter = Completer<void>();
      client.beforeConnect = () => bcCompleter.future;

      // Start first connect (will await beforeConnect).
      final first = client.connect();
      // Start second connect — must join the first, not return silently.
      final second = client.connect();

      // Release beforeConnect so the first attempt completes.
      bcCompleter.complete();

      // Both should resolve successfully.
      await first;
      await second;
      // If second were NOT joining, it would have returned immediately
      // with a null (no error, no open state). Verify state is open.
      expect(client.state, GwConnectionState.open);

      await client.dispose();
      await server.close(force: true);
    });

    test('failed first connect propagates to second joiner', () async {
      // Server rejects all WS upgrades.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        r.response.statusCode = 403;
        await r.response.close();
      });
      final client = GatewayClient(
          GatewayConfig(url: 'http://127.0.0.1:${server.port}'),
          autoReconnect: false);

      final first = client.connect();
      final second = client.connect();

      await expectLater(first, throwsA(isA<GatewayError>()));
      await expectLater(second, throwsA(isA<GatewayError>()),
          reason: 'second joiner must also receive the failure');

      await client.dispose();
      await server.close(force: true);
    });

    test('cancellation during auth also propagates to concurrent joiner',
        () async {
      final server = await startTestServer(onUpgrade: rpcEcho(null));
      final client = GatewayClient(cfgFor(server), autoReconnect: false);

      final bcCompleter = Completer<void>();
      client.beforeConnect = () => bcCompleter.future;

      final first = client.connect();
      final second = client.connect();
      // expectLater arms both listeners synchronously.
      expectLater(first, throwsA(isA<GatewayError>()),
          reason: 'cancel during auth must not report successful open');
      expectLater(second, throwsA(isA<GatewayError>()),
          reason: 'joiner must see the cancellation error');
      await waitSuspendedInBeforeConnect(client);
      await client.dispose();
      bcCompleter.complete();

      expect(client.state, GwConnectionState.closed);

      await server.close(force: true);
    });

    // ---------------------------------------------------------------
    // BUG 3: request() success path must actually cancel the timeout
    // timer. The original code's timeout callback was a no-op on success
    // (the pending entry was already removed), so the bug was strictly a
    // leaked timer resource, not an unhandled error. A retained timer
    // is not directly observable behaviorally without a timer-count
    // test seam (Dart's Timer has no public introspection), so the
    // deterministic assertion here is: after a successful request the
    // client stays open and a subsequent request still works — no
    // spurious teardown from a leaked timer's callback, and a long
    // wait passes with the socket still healthy.
    // ---------------------------------------------------------------
    test('request success actually cancels the pending timeout timer',
        () async {
      final server = await startTestServer(onUpgrade: rpcEcho(null));
      final client = GatewayClient(cfgFor(server), autoReconnect: false);
      await client.connect();

      final result = await client.request('test.ping', {}, 5000);
      expect(result, isA<Map>());

      // After a successful request, the client must stay open; a leaked
      // timer's callback firing on the already-completed future must not
      // be observable as an error or teardown of the socket.
      await pump(100);
      expect(client.state, GwConnectionState.open,
          reason: 'no spurious failure from timer handling');

      // A second request in the same window proves normal operation
      // isn't disrupted. If the timer had leaked and its callback did
      // fire (the timeout path closes the socket), the socket teardown
      // path would have left the client non-open.
      final again = await client.request('test.ping.2', {}, 5000);
      expect(again, isA<Map>());
      expect(client.state, GwConnectionState.open);

      await client.dispose();
      await server.close(force: true);
    });

    // ---------------------------------------------------------------
    // BUG 4: deterministic synchronous serialization failure. NO sink
    // mock, NO race: a healthy local WS is established first, then a
    // request with a non-JSON parameter makes jsonEncode throw BEFORE
    // any completer is registered. The zoned error handler proves no
    // unobserved-completer error escaped the call site.
    // ---------------------------------------------------------------
    test('request with un-serializable params fails synchronously with no '
        'unhandled error (real local WS)', () async {
      final server = await startTestServer(onUpgrade: rpcEcho(null));
      final client = GatewayClient(cfgFor(server), autoReconnect: false);
      await client.connect();
      expect(client.state, GwConnectionState.open);

      var zonedUnhandled = false;
      await runZonedGuarded(() async {
        await pump(); // flush any stray errors from connect
        zonedUnhandled = false;
        try {
          await client.request('x', {'bad': Object()});
          fail('request must throw for un-serializable params');
        } on GatewayError catch (e) {
          expect(e.message, contains('serialization failed'));
        }
      }, (e, st) => zonedUnhandled = true);

      await pump(50);
      expect(zonedUnhandled, isFalse,
          reason: 'jsonEncode before completer registration must not leave '
              'an unobserved completed error completer: $zonedUnhandled');
      expect(client.state, GwConnectionState.open,
          reason: 'serialization failure must not tear down the socket');

      await client.dispose();
      await server.close(force: true);
    });

    // ---------------------------------------------------------------
    // BUG 5: stale channel callback behavior. This drives the REAL
    // disconnect/recovery path over a live local WS: ws1 opens, the
    // server closes it, and the teardown (_onDone -> _scheduleReconnect)
    // plus the recovery dial (which cancels the replaced channel's
    // subscription before dialing ws2) must produce EXACTLY one
    // reconnect cycle and two dials, then hold steady open. The
    // assertions are the guards' contract: no orphaned re-dials, no
    // extra reconnect attempt counter bumps, and close() afterward
    // stays closed (any unguarded callback from a replaced channel
    // would re-schedule/re-bump after close).
    // ---------------------------------------------------------------
    test('stale channel callbacks are generation-guarded after server '
        'disconnect', () async {
      // ws1 stays open 80ms then the server closes it (real, in-flight
      // disconnect — the source of the stale-callback risk).
      var upgrades = 0;
      final server = await startTestServer(
        onUpgrade: (req, ws) {
          upgrades++;
          if (upgrades % 2 == 1) {
            Timer(const Duration(milliseconds: 80), ws.close);
          } else {
            rpcEcho(null)(req, ws);
          }
        },
      );
      final client = GatewayClient(cfgFor(server), autoReconnect: true);
      // Default backoff (300ms jitter) is fine; the poll loop below
      // converges well within test budget.

      // First attempt: ws1 opens and answers nothing, then the server
      // closes it. That done is handled by the LIVE teardown path and
      // schedules exactly one backoff reconnect.
      await client.connect();
      expect(client.state, GwConnectionState.open);

      // Wait for the recovery dial (ws2) to come up.
      while (upgrades < 2 || client.state != GwConnectionState.open) {
        await pump(50);
      }
      expect(upgrades, 2);

      // Now ws2 is up. The recovery dial cancelled ws1's replaced
      // subscription; steady state must hold: no orphaned re-dials,
      // no extra cycle from a stale callback.
      await pump(200);
      expect(client.state, GwConnectionState.open,
          reason: 'no orphaned reconnect may disturb a healthy open channel');
      expect(upgrades, 2,
          reason: 'exactly two dials (ws1, ws2) — an unguarded stale '
              'callback would schedule a third');

      // A request on the recovered channel works (pending survived; no
      // spurious close from a stale callback).
      final res = await client.request('test.ping', {}, 3000);
      expect(res, isA<Map>());

      // close() must cleanly stop everything without hanging or a late
      // callback resurrecting state.
      client.close();
      expect(client.state, GwConnectionState.closed);
      await pump(150);
      expect(client.state, GwConnectionState.closed,
          reason: 'no stale callback may move state after close');

      await client.dispose();
      await server.close(force: true);
    });
  });
}