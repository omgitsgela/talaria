import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'native_oauth.dart';

/// Encrypted store for native-OAuth token sets, keyed by gateway URL.
///
/// Mirrors the desktop's native-token-store: one entry per gateway base URL,
/// written with flutter_secure_storage (EncryptedSharedPreferences on Android).
class OAuthTokenStore {
  OAuthTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _keyPrefix = 'talaria.oauth.';

  /// Serialized rejection-cleanup/fresh-session path. A rejection-cleanup
  /// clear and a fresh sign-in's save used to race: the clear
  /// (fire-and-forget) could land AFTER the save and delete the brand-new
  /// credential, silently logging the user back out. Cleanups chain through
  /// this future in issue order; [save] deliberately does NOT queue behind a
  /// slow cleanup (a sign-in must never be hostage to storage I/O for an
  /// already-dead token) — instead every DELETE is guarded by the revision
  /// check below, across its own await, at the exact moment the destructive
  /// write would land.
  Future<void> _writes = Future<void>.value();

  /// Bumped the MOMENT a save is issued (not when its I/O completes), so a
  /// delete that captured the revision before a newer sign-in can see across
  /// its own await that a fresher credential was recorded in the meantime —
  /// even when the save lands WHILE the delete is mid-flight.
  int _revision = 0;

  String _keyFor(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return '${_keyPrefix}${uri.scheme}://${uri.host}:${uri.port}$path';
  }

  Future<NativeTokenSet?> load(String baseUrl) async {
    try {
      final raw = await _storage.read(key: _keyFor(baseUrl));
      if (raw == null || raw.isEmpty) return null;
      return NativeTokenSet.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt/legacy entry: drop so the next sign-in starts clean.
      await deleteTokenRecord(baseUrl);
      return null;
    }
  }

  /// Run [op] after every previously-issued cleanup op. Cleanup ordering
  /// matches issuance order; a failing op does not poison the chain.
  Future<void> _chain(Future<void> Function() op) {
    final written = _writes.then((_) => op());
    _writes = written.catchError((Object _) {});
    return written;
  }

  /// A save is recorded the INSTANT it is issued: the revision bumps
  /// synchronously and the storage write runs immediately — a sign-in is
  /// never hostage to storage I/O for an already-dead token. Any delete that
  /// was in flight at that moment sees the revision move across its own
  /// await and skips destroying the credential it no longer owns.
  Future<void> save(String baseUrl, NativeTokenSet set) async {
    ++_revision;
    await _storage.write(
        key: _keyFor(baseUrl), value: jsonEncode(set.toJson()));
    // A successful sign-in is the only thing that clears the "sign in
    // again" state. A guarded cleanup that got superseded skips its marker
    // write too, so a fresh sign-in cannot end up falsely marked.
    await clearReauthNeeded(baseUrl);
  }

  // ── Why a sign-in is needed (gateway restarts end a session) ──────
  // A gateway restart ends the server-side OAuth session, so the stored token
  // stops working. The app already detected that (a 401 `session_expired` on
  // refresh drops the token set), but nothing told the SIGN-IN SCREEN, which
  // kept pre-filling the dead token from the config with no explanation. The
  // reason is recorded here so the screen can say what happened.
  static const _reauthPrefix = 'talaria.reauth.';

  String _reauthKeyFor(String baseUrl) => '$_reauthPrefix${_keyFor(baseUrl)}';

  /// Record that [baseUrl] needs a fresh sign-in, and why.
  Future<void> markReauthNeeded(String baseUrl, String reason) async {
    try {
      await _storage.write(key: _reauthKeyFor(baseUrl), value: reason);
    } catch (_) {
      // Best effort: the screen falls back to the generic wording.
    }
  }

  /// The recorded reason a sign-in is needed, or null when none is recorded.
  Future<String?> reauthNeededReason(String baseUrl) async {
    try {
      final raw = await _storage.read(key: _reauthKeyFor(baseUrl));
      return (raw == null || raw.isEmpty) ? null : raw;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearReauthNeeded(String baseUrl) async {
    try {
      await _storage.delete(key: _reauthKeyFor(baseUrl));
    } catch (_) {}
  }

  /// The single destructive token-record delete. Every guarded cleanup and
  /// every explicit teardown routes through here (via _guardedDelete), so a
  /// test seam can slow down deletion itself — modelling asynchronous storage
  /// completion on the real production path, not a bypassed public API.
  ///
  /// The ownership check runs at the moment of the WRITE, after every await
  /// this delete (or a slow seam's own awaits) has taken: if a newer save was
  /// issued while the delete was mid-flight, the write is skipped instead of
  /// erasing the replacement credential. A check only AFTER the destructive
  /// write would be too late.
  Future<void> deleteTokenRecord(String baseUrl,
      {int expectedRevision = -1}) async {
    if (expectedRevision >= 0 && _revision != expectedRevision) return;
    try {
      await _storage.delete(key: _keyFor(baseUrl));
    } catch (_) {}
  }

  /// The guarded token-record delete. [expectedRevision] is captured by the
  /// caller BEFORE the delete begins; across the delete's own await, if a
  /// newer [save] was issued in the meantime (revision moved), this delete
  /// was based on stale knowledge and refuses to destroy the replacement
  /// credential. Returns whether the record was actually removed.
  Future<bool> _guardedDelete(String baseUrl, int expectedRevision) async {
    // Synchronous pre-check: a save issued before this delete even started.
    if (_revision != expectedRevision) return false;
    await deleteTokenRecord(baseUrl, expectedRevision: expectedRevision);
    // Post-check decides the bookkeeping (e.g. whether to record a reauth
    // reason): a superseded delete skipped its write, so it must not leave a
    // stale "sign in again" marker for a credential it no longer owned.
    if (_revision != expectedRevision) return false;
    return true;
  }

  Future<void> clear(String baseUrl) {
    final rev = _revision;
    return _chain(() async {
      await _guardedDelete(baseUrl, rev);
    });
  }

  /// Explicit new-session teardown: remove the old stored credential and its
  /// reauth marker as one critical section.
  Future<void> beginFreshSession(String baseUrl) {
    final rev = _revision;
    return _chain(() async {
      await _guardedDelete(baseUrl, rev);
      await clearReauthNeeded(baseUrl);
    });
  }

  /// Staleness-safe rejection cleanup (the serialized, ordered version of
  /// "this dial was rejected — drop the credential it presented"): loads the
  /// currently stored set inside the critical section and drops it ONLY if it
  /// is still the rejected one, with the revision guard wrapping the actual
  /// delete across its await. A cleanup queued before a newer sign-in runs
  /// first (ordered) and then skips; a late cleanup that races a save skips
  /// instead of deleting the fresh credential.
  Future<void> invalidateRejected(
    String baseUrl, {
    required String expectedAccessToken,
    required String reason,
  }) {
    final rev = _revision;
    return _chain(() async {
      final current = await load(baseUrl);
      if (current != null && current.accessToken != expectedAccessToken) {
        // A newer credential is on record: this rejection is stale evidence
        // about an older one. Do not touch storage or the reauth marker.
        return;
      }
      final deleted = await _guardedDelete(baseUrl, rev);
      if (deleted) {
        // Only mark "sign in again" for a credential this cleanup actually
        // retired. A skipped delete leaves the fresh sign-in unmarked.
        await markReauthNeeded(baseUrl, reason);
      }
    });
  }
}

/// Runs the full RFC 8252 native sign-in against a gateway that advertises
/// `native_pkce`:
///   1. Bind a loopback HTTP listener on 127.0.0.1:<ephemeral>.
///   2. Generate the PKCE pair + CSRF state, build /auth/native/authorize.
///   3. Open the system browser (caller-provided [openBrowser]).
///   4. Receive the redirect, validate state, redeem the code via
///      POST /auth/native/token {code, code_verifier}.
///   5. Persist the token set in secure storage, return it.
///
/// Pure logic (PKCE, URL building, callback parsing, token parsing) lives in
/// [NativeOAuthService]; this class owns only the I/O coordination.
class OAuthFlowRunner {
  OAuthFlowRunner({
    required this.store,
    http.Client? httpClient,
    Duration timeout = const Duration(minutes: 2),
  }) : _http = httpClient ?? http.Client(),
       _timeout = timeout;

  final OAuthTokenStore store;
  final http.Client _http;
  final Duration _timeout;

  /// The interactive sign-in currently in flight, so the UI can cancel an
  /// abandoned browser flow instead of leaving the button disabled for the
  /// full timeout.
  HttpServer? _activeServer;
  Completer<Uri>? _pendingCallback;

  /// Per-flow cancellation token. Cancel releases the flow at EVERY await
  /// (browser launch, callback wait, token exchange) and blocks the final
  /// save — a cancelled sign-in can never silently complete into a stored
  /// session after the user gave up.
  Completer<void>? _activeCancel;
  static const _cancelledMessage =
      'Sign-in cancelled. Tap Sign in to try again.';

  /// Tear down an in-flight [signIn]: the waiter fails with "Sign-in
  /// cancelled" and the loopback listener closes, so the user regains the
  /// buttons immediately instead of staring at "Opening browser…" for two
  /// minutes.
  Future<void> cancelActiveSignIn() async {
    // Complete the per-flow token (releases every _cancelable await, including
    // one stuck inside openBrowser) and error the callback waiter. Do NOT
    // close the loopback server from here: signIn's own finally closes it, and
    // closing it out from under that finally races sub.cancel.
    final cancel = _activeCancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    final pending = _pendingCallback;
    if (pending != null && !pending.isCompleted) {
      // completeError also errors OUR await of callback.future below; the
      // caller here must not see it — signIn's own catch reports the
      // cancellation to the UI.
      pending.completeError(const OAuthException(_cancelledMessage));
      pending.future.catchError((Object _) => Uri.parse('about:blank'));
    }
  }

  /// Run [op], but fail with the cancellation message as soon as the flow's
  /// cancel token completes — whichever side wins the race.
  Future<T> _cancelable<T>(Completer<void> cancel, Future<T> Function() op) {
    if (cancel.isCompleted) throw const OAuthException(_cancelledMessage);
    return Future.any<T>([
      op(),
      cancel.future
          .then<T>((_) => throw const OAuthException(_cancelledMessage)),
    ]);
  }

  /// True when the gateway advertises the native PKCE flow.
  Future<bool> supportsNativeFlow(GatewayConfig config) async {
    final flows = await _statusFlows(config);
    return NativeOAuthService.flowsSupportNativeFlow(flows);
  }

  Future<List<String>> _statusFlows(GatewayConfig config) async {
    try {
      final res = await _http
          .get(Uri.parse(config.httpUrl('/api/status')),
              headers: config.headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body);
      final flows = body is Map ? body['auth_flows'] : null;
      if (flows is! List) return const [];
      return flows.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Run the sign-in. [openBrowser] must launch the system browser at [url]
  /// (e.g. via url_launcher). Resolves with the stored token set; throws
  /// [OAuthException] on any failure.
  Future<NativeTokenSet> signIn(
    GatewayConfig config, {
    required Future<void> Function(Uri url) openBrowser,
    FutureOr<String> Function(String status)? onStatus,
  }) async {
    final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4, 0);
    _activeServer = server;
    final port = server.port;
    final verifier = NativeOAuthService.generateVerifier();
    final challenge = NativeOAuthService.challengeFromVerifier(verifier);
    final state = NativeOAuthService.generateState();
    final redirectUri = Uri.parse('http://127.0.0.1:$port/callback');
    final authorizeUrl = NativeOAuthService.buildAuthorizeUrl(
      baseUrl: config.baseUrl,
      challenge: challenge,
      redirectUri: redirectUri.toString(),
      state: state,
    );

    final callback = Completer<Uri>();
    _pendingCallback = callback;
    final cancel = Completer<void>();
    _activeCancel = cancel;
    late StreamSubscription sub;
    sub = server.listen((req) async {
      final path = req.uri.path;
      if (path != '/callback') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      if (!callback.isCompleted) callback.complete(req.uri);
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><body><h3>Talaria sign-in received.</h3>'
          '<p>You can close this tab and return to the app.</p></body></html>');
      await req.response.close();
    });

    try {
      onStatus?.call('Opening browser for Hermes sign-in…');
      // A browser launch that hangs (custom tab never resolves) must not
      // strand the flow: cancel releases the caller from THIS await too.
      await _cancelable(cancel, () => openBrowser(authorizeUrl));
      final callbackUri = await _cancelable(
          cancel,
          () => callback.future.timeout(_timeout, onTimeout: () =>
              throw const OAuthException(
                  'Timed out waiting for the browser sign-in callback')));

      onStatus?.call('Exchanging code for tokens…');
      final code = NativeOAuthService.parseLoopbackCallback(
          callbackUri: callbackUri, expectedState: state);

      final tokenBody = await _cancelable(
          cancel,
          () => _http
              .post(
                NativeOAuthService.buildTokenUrl(config.baseUrl),
                headers: {
                  'content-type': 'application/json',
                  ...config.headers,
                },
                body: jsonEncode({
                  'code': code,
                  'code_verifier': verifier,
                }),
              )
              .timeout(const Duration(seconds: 20)));
      if (tokenBody.statusCode != 200) {
        throw OAuthException(
            'Gateway token endpoint returned HTTP ${tokenBody.statusCode}');
      }
      final parsed = jsonDecode(tokenBody.body);
      if (parsed is! Map<String, dynamic>) {
        throw const OAuthException('Malformed token response');
      }
      final tokens = NativeOAuthService.parseTokenResponse(parsed);
      // A cancel that landed during the exchange must not persist a session
      // the user explicitly abandoned.
      if (cancel.isCompleted) throw const OAuthException(_cancelledMessage);
      await store.save(config.baseUrl, tokens);
      return tokens;
    } finally {
      await sub.cancel();
      await server.close(force: true);
      if (_pendingCallback == callback) _pendingCallback = null;
      if (_activeServer == server) _activeServer = null;
      if (_activeCancel == cancel) _activeCancel = null;
    }
  }

  /// Refresh an expired/soon-expired token set via
  /// POST /auth/native/refresh {refresh_token, provider}. The gateway
  /// rotates the refresh token on success; on a 401 `session_expired`
  /// body it clears the stored set so the next connect starts fresh.
  Future<NativeTokenSet?> refresh(
    String baseUrl,
    NativeTokenSet set, {
    FutureOr<String> Function(String status)? onStatus,
    Map<String, String> headers = const {},
  }) async {
    if (set.refreshToken.isEmpty) return null;
    onStatus?.call('Refreshing session…');
    final http.Response res;
    try {
      res = await _http
          .post(
            NativeOAuthService.buildRefreshUrl(baseUrl),
            headers: {
              'content-type': 'application/json',
              ...headers,
            },
            body: jsonEncode({
              'refresh_token': set.refreshToken,
              'provider': set.provider,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on OAuthException {
      rethrow;
    } catch (e) {
      // A transport failure (timeout, DNS, socket) is NOT evidence the
      // credential is dead. The old code let this crash out of resolveToken
      // so an unreachable refresh endpoint prevented the interactive
      // fallback. Treat it like "refresh did not produce tokens" and let the
      // caller fall through to a browser sign-in.
      throw const OAuthException(
          'Could not reach the gateway to refresh the session');
    }
    if (res.statusCode == 401) {
      // Say exactly what the server said. Attributing every 401 to a gateway
      // restart was false: the gate distinguishes `session_expired` (the
      // session is known to be over — a restart is the usual cause) from
      // other rejections. The screen renders both wordings honestly.
      var reason = 'credential_rejected';
      try {
        final body = jsonDecode(res.body);
        if (body is Map && body['error'] == 'session_expired') {
          reason = 'session_expired';
        }
      } catch (_) {}
      // Session expired — drop the stale set and record why, so the sign-in
      // screen can explain it instead of showing a token that no longer works.
      // Bound to THIS set: a late 401 for an old refresh attempt must not
      // delete a credential the user signed in with in the meantime.
      await store.invalidateRejected(baseUrl,
          expectedAccessToken: set.accessToken, reason: reason);
      return null;
    }
    if (res.statusCode != 200) {
      throw OAuthException(
          'Token refresh failed (HTTP ${res.statusCode}); sign in again');
    }
    final parsed = jsonDecode(res.body);
    if (parsed is! Map<String, dynamic>) {
      throw const OAuthException('Malformed refresh response');
    }
    final refreshed = NativeOAuthService.parseTokenResponse(parsed);
    await store.save(baseUrl, refreshed);
    return refreshed;
  }

  Future<void> signOut(GatewayConfig config) async {
    await store.clear(config.baseUrl);
    // A deliberate sign-out is not a reason to show a "sign in again" banner.
    await store.clearReauthNeeded(config.baseUrl);
  }

  /// Resolve an effective access token for [config] using the desktop's
  /// "stored -> refreshed -> interactive" chain:
  ///   1. A stored token set that is still valid is used as-is.
  ///   2. A stored set that is expired/soon-expired is refreshed (rotation);
  ///      a 401 drops it.
  ///   3. Otherwise run the interactive browser sign-in.
  /// [openBrowser] launches the system browser; [onStatus] gets status lines.
  ///
  /// [forceInteractive] skips steps 1-2 entirely. Without it, a stored token
  /// that merely LOOKS valid returned immediately and the browser never
  /// opened - which is exactly the field complaint "Sign in doesn't take me
  /// to the sign-in page". A token the gateway has rejected server-side (a
  /// restart revokes the session behind it) still looks valid locally, so an
  /// explicit sign-in must always reach the browser. Automatic recovery keeps
  /// using the cached chain; only explicit actions pass the flag.
  Future<NativeTokenSet> resolveToken(
    GatewayConfig config, {
    required Future<void> Function(Uri url) openBrowser,
    FutureOr<String> Function(String status)? onStatus,
    bool forceInteractive = false,
  }) async {
    final base = config.baseUrl;
    if (forceInteractive) {
      // Starting a new session invalidates the old stored set first, so a
      // later automatic dial can never resurrect the credential the user
      // just replaced. One chained critical section: a queued rejection
      // cleanup can never interleave between the clear and the marker clear.
      await store.beginFreshSession(base);
      return signIn(config, openBrowser: openBrowser, onStatus: onStatus);
    }
    final stored = await store.load(base);
    if (stored != null) {
      if (!NativeOAuthService.tokenNeedsRefresh(stored,
          nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
        return stored;
      }
      try {
        final refreshed = await refresh(base, stored, onStatus: onStatus, headers: config.headers);
        if (refreshed != null) return refreshed;
        // 401 path already cleared the stale set — fall through to re-auth.
      } on OAuthException {
        // Refresh endpoint unreachable / errored; fall through to re-auth.
      }
    }
    return signIn(config, openBrowser: openBrowser, onStatus: onStatus);
  }
}
