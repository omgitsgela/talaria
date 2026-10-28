import 'dart:async';

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../gateway/config.dart';
import '../gateway/http_service.dart';
import '../gateway/native_oauth.dart';
import '../gateway/oauth_flow.dart';
import '../store/app_model.dart';

/// First-run / reconnect screen. Mirrors the desktop's "Connect to
/// existing Hermes": URL + auth (token or OAuth bearer) + optional
/// proxy headers, with a live probe before committing.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key, required this.model, this.onConnected});

  /// Test seam, matching [httpFactoryForTest]: lets a widget test supply the
  /// token store instead of touching platform secure storage.
  static OAuthTokenStore? oauthStoreForTest;
  final AppModel model;
  final VoidCallback? onConnected;

  /// Test seam: the HTTP prober, so widget tests can drive auth-flow discovery
  /// without a live gateway.
  @visibleForTesting
  static GatewayHttp Function(GatewayConfig config)? httpFactoryForTest;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen>  {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _url;
  late TextEditingController _token;
  late TextEditingController _bearer;
  late TextEditingController _headerName;
  late TextEditingController _headerValue;

  bool _authToken = true;
  bool _probeLoading = false;
  ProbeResult? _probeResult;
  bool _connecting = false;
  bool _nativeAvailable = false;
  bool _oauthLoading = false;
  String _oauthStatus = '';
  String _oauthError = '';

  /// Recorded reason a sign-in is needed, e.g. after a gateway restart ended
  /// the previous session. Empty when nothing is recorded.
  String _reauthReason = '';

  /// The connect screen is RETAINED across a failed Connect (AppModel keeps
  /// the phase at noConnection with the same screen mounted). Without a model
  /// listener the failure landed invisibly: the buttons re-armed but nothing
  /// said WHY, and an auth rejection looked like a silent network mystery.
  String? _connectError;
  bool _authRejected = false;

  late final OAuthTokenStore _oauthStore =
      ConnectionScreen.oauthStoreForTest ?? OAuthTokenStore();

  static const _defaultUrl = 'http://gw.example.internal:9119';

  /// Debounce for the quiet auth-flow discovery that runs while the user types
  /// a URL, so a gateway's sign-in option is known before anything is pressed.
  Timer? _flowDebounce;

  /// Generation guard for discovery: a response must belong to the URL it was
  /// asked for. A slow answer about an OLD URL used to switch the OAuth tab on
  /// for whatever URL the user has typed since.
  int _flowGen = 0;
  String _flowBudgetUrl = '';
  int _flowRetryBudget = 2;

  @override
  void initState() {
    super.initState();
    final c = widget.model.saved;
    _url = TextEditingController(text: c?.url ?? _defaultUrl);
    _token = TextEditingController(text: c?.token ?? '');
    _bearer = TextEditingController(text: c?.oauthToken ?? '');
    _headerName = TextEditingController();
    _headerValue = TextEditingController();
    if (c?.usesOAuth ?? false) _authToken = false;
    widget.model.addListener(_onModelChanged);
    // Seed a failure that already happened before this screen subscribed
    // (the startup dial of a saved config, or a background reconnect that
    // failed while some other screen was up). Without the seed, a rejected
    // credential could fail while the connect screen existed but never
    // reach it.
    _connectError = widget.model.connectError;
    _authRejected = widget.model.needsReauth;
    if (_authRejected) _authToken = false;
    _url.addListener(_onUrlChanged);
    unawaited(_loadReauthState());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_discoverFlows());
    });
  }

  void _onModelChanged() {
    if (!mounted) return;
    // A failed (re)connect from ANY entry point (this screen or a background
    // reconnect) lands here: show what happened, and when the gateway
    // rejected the credential, drive the screen into the sign-in affordance.
    setState(() {
      _connectError = widget.model.connectError;
      _authRejected = widget.model.needsReauth;
      if (_authRejected) {
        _connecting = false;
        _oauthLoading = false;
        _oauthStatus = '';
        _authToken = false;
      }
    });
  }

  /// Read the recorded reason a sign-in is needed for the saved gateway.
  ///
  /// A gateway restart ends the server-side OAuth session, so the stored token
  /// stops working. The token store already records that; this makes the screen
  /// say so, and stops it presenting the dead token as though it were live.
  Future<void> _loadReauthState() async {
    final c = widget.model.saved;
    if (c == null || !c.usesOAuth) return;
    String? reason;
    try {
      reason = await _oauthStore.reauthNeededReason(c.baseUrl);
    } catch (_) {
      return;
    }
    if (!mounted || reason == null || reason.isEmpty) return;
    // Promote to a non-nullable local: a variable captured by the closure
    // below is not promoted by the null check.
    final why = reason;
    setState(() {
      _reauthReason = why;
      _authToken = false;
      // Never show an ended session's token as if it were usable.
      _bearer.clear();
    });
  }

  String get _reauthMessage => switch (_reauthReason) {
        'gateway_restart' || 'session_expired' =>
          'Your signed-in session has ended (a gateway restart or revocation '
              'does this). Sign in again to reconnect.',
        _ =>
          'Your saved sign-in is no longer valid. Sign in again to reconnect.',
      };

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    _flowDebounce?.cancel();
    _url.removeListener(_onUrlChanged);
    _url.dispose();
    _token.dispose();
    _bearer.dispose();
    _headerName.dispose();
    _headerValue.dispose();
    super.dispose();
  }

  GatewayConfig _build() => GatewayConfig(
        url: _url.text.trim(),
        token: _authToken ? _token.text.trim() : '',
        oauthToken: _authToken ? '' : _bearer.text.trim(),
        // The saved connection's proxy headers must survive the screen's own
        // rebuild or a Cloudflare-fronted gateway stops answering at all:
        // every dial after one tap on this screen used to lose them. They
        // are bound to the SAVED origin, though: editing the URL to another
        // host must not ship the old gateway's CF-Access secret to the new
        // one through automatic discovery (or any other _build consumer).
        // Same gateway keeps its headers; a different gateway gets none
        // until the user explicitly supplies them.
        headers: _headersForCurrentUrl(),
      );

  /// Saved proxy headers apply only to the URL they were saved with.
  Map<String, String>? _headersForCurrentUrl() {
    final saved = widget.model.saved;
    if (saved == null || saved.headers.isEmpty) return saved?.headers;
    final typed = GatewayConfig(url: _url.text.trim()).baseUrl;
    return typed == saved.baseUrl ? saved.headers : const <String, String>{};
  }

  GatewayHttp _http(GatewayConfig c) =>
      (ConnectionScreen.httpFactoryForTest ?? GatewayHttp.new)(c);

  void _onUrlChanged() {
    _flowDebounce?.cancel();
    _flowDebounce = Timer(const Duration(milliseconds: 800), () {
      unawaited(_discoverFlows());
    });
  }

  /// Ask the gateway which auth flows it advertises, quietly.
  ///
  /// This is what makes "Sign in with Hermes" available from the moment the
  /// screen knows the gateway, instead of only after pressing Test connection.
  /// Deliberately silent on failure: a background probe must never paint an
  /// error the user did not ask for, and it only ever switches the sign-in
  /// affordance ON.
  Future<void> _discoverFlows() async {
    final url = _url.text.trim();
    // The shipped placeholder host is not a real gateway; probing it would be
    // a guaranteed wasted request.
    if (url.isEmpty || url == _defaultUrl) return;
    // Fresh URL edit: new host gets its own retry budget.
    if (url != _flowBudgetUrl) {
      _flowBudgetUrl = url;
      _flowRetryBudget = 2;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final gen = ++_flowGen;
    final http = _http(_build());
    try {
      // The plain helper swallows transport errors into [] - that made the
      // retry below unreachable for a gateway that is still starting (the
      // exact case the retry exists for). Ask the throwing variant so an
      // unreachable gateway is distinguishable from a gateway that simply
      // advertises no flows.
      final flows = await http.authFlows(throwOnTransportError: true);
      // A slow answer about a URL the user has since edited must not switch
      // the sign-in affordance for whatever URL is in the box now.
      if (!mounted || gen != _flowGen || _url.text.trim() != url) return;
      if (!NativeOAuthService.flowsSupportNativeFlow(flows)) return;
      setState(() {
        _nativeAvailable = true;
        // Only move the user to the OAuth tab if they have not already started
        // entering a session token.
        if (_token.text.trim().isEmpty) _authToken = false;
      });
    } catch (_) {
      // No answer (offline, not a gateway, older build): leave the form
      // alone. One bounded quiet retry — the budget is explicit so a host
      // that never answers is not probed forever every four seconds.
      if (mounted && gen == _flowGen && _flowRetryBudget > 0) {
        _flowRetryBudget--;
        _flowDebounce?.cancel();
        _flowDebounce = Timer(const Duration(seconds: 4), () {
          unawaited(_discoverFlows());
        });
      }
    } finally {
      http.close();
    }
  }

  Future<void> _probe() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _probeLoading = true;
      _probeResult = null;
      _oauthError = '';
    });
    final http = _http(_build());
    try {
      final result = await http.testConnection();
      // Detect whether this gateway advertises the RFC 8252 native flow so
      // we can offer "Sign in with Hermes" instead of a bearer field.
      var native = false;
      try {
        final flows = await http.authFlows();
        native = NativeOAuthService.flowsSupportNativeFlow(flows);
      } catch (_) {
        // The gateway answered health but not /auth/flows (older build or a
        // bot wall). That is NOT evidence against signing in, and it must not
        // leave the probe button stuck in "Probing…" forever — the old code
        // let this exception escape and skip the state update entirely.
      }
      if (!mounted) return;
      setState(() {
        _probeLoading = false;
        _probeResult = result;
        // A failed probe says nothing about auth flows; never erase what
        // discovery already learned (an older gateway may not expose
        // /auth/flows at all, and clearing it hid the sign-in option).
        if (native) _nativeAvailable = true;
        if (native) _authToken = false;
      });
    } finally {
      http.close();
    }
  }

  Future<void> _signInOAuth() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _oauthLoading = true;
      _oauthError = '';
      _oauthStatus = 'Preparing…';
    });
    try {
      final c = _build();
      final resolved = await widget.model.signInOAuth(
        c,
        onStatus: (s) {
          if (mounted) setState(() => _oauthStatus = s);
        },
      );
      if (!mounted) return;
      // The credential is fresh: re-arm the form and let Connect own the
      // connecting state, instead of leaving "Signing in…" painted while the
      // socket handshake runs with nothing enabled.
      setState(() {
        _oauthLoading = false;
        _oauthStatus = '';
        _oauthError = '';
        _connecting = true;
      });
      await widget.model.connect(resolved);
      if (mounted) {
        setState(() => _connecting = false);
        if (widget.model.phase == AppPhase.connected) {
          widget.onConnected?.call();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _oauthLoading = false;
          _oauthError = e.toString().replaceFirst('Exception: ', '');
          _oauthStatus = '';
        });
      }
    }
  }

  Future<void> _connect() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _connecting = true);
    // model.connect() catches internally and stays at noConnection on failure;
    // the model listener then paints the error. But an unreachable host can
    // sit in connect() until the dial timeout elapses - so keep a watchdog:
    // if the model has not moved to connected by then, re-arm this screen and
    // show what the store has recorded.
    final watchdog = Timer(const Duration(seconds: 25), () {
      if (!mounted) return;
      if (widget.model.phase == AppPhase.connected) return;
      setState(() {
        _connecting = false;
        _connectError = widget.model.connectError ??
            'The gateway did not answer. Check the URL and try again.';
      });
    });
    try {
      await widget.model.connect(_build());
      watchdog.cancel();
      if (mounted && widget.model.phase == AppPhase.connected) {
        widget.onConnected?.call();
      }
    } finally {
      watchdog.cancel();
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    _logo(context),
                    const SizedBox(height: 20),
                    Text('Talaria',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700,
                                color: theme.colorScheme.primary)),
                    const SizedBox(height: 4),
                    Text('Connect to a Hermes gateway',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w500,
                                color: theme.colorScheme.onSurface)),
                    const SizedBox(height: 8),
                    // Shared with the splash: one constant, so the two screens
                    // cannot disagree about the app's own one-liner.
                    Text(kAppTagline,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 28),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                    TextFormField(
                      controller: _url,
                      decoration: const InputDecoration(
                          labelText: 'Gateway URL',
                          hintText: 'http://gw.example.internal:9119'),
                      keyboardType: TextInputType.url,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Required';
                        }
                        final u = Uri.tryParse(
                            (v.contains('://') ? v : 'http://$v'));
                        if (u == null || !u.hasAuthority) {
                          return 'Enter a host[:port] or full URL';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('Token')),
                        ButtonSegment(
                            value: false, label: Text('OAuth bearer')),
                      ],
                      selected: {_authToken},
                      onSelectionChanged: (s) =>
                          setState(() => _authToken = s.first),
                    ),
                    const SizedBox(height: 16),
                    if (_authToken) ...[
                      TextFormField(
                        controller: _token,
                        decoration: const InputDecoration(
                            labelText: 'Session token',
                            helperText:
                                'The dashboard X-Hermes-Session-Token (loopback / --insecure gateways).',
                            // Without an explicit cap, Flutter draws a helper on
                            // ONE line and ellipsizes the rest, which hid most
                            // of this explanation on a phone.
                            helperMaxLines: 3),
                        obscureText: true,
                      ),
                      const SizedBox(height: 8),
                      // The screen opens on this tab for most users. A first-
                      // time OAuth user who never learned the tab existed used
                      // to stare at a token field they had no token for. Offer
                      // the browser sign-in from here too.
                      TextButton.icon(
                        key: const ValueKey('token_tab_signin_link'),
                        onPressed: _oauthLoading || _connecting
                            ? null
                            : _signInOAuth,
                        icon: const Icon(Icons.login),
                        label: const Text('Or sign in with Hermes'),
                      ),
                      // A sign-in started from THIS tab needs the same cancel
                      // affordance the OAuth tab has; otherwise an abandoned
                      // browser flow strands the form here.
                      if (_oauthLoading)
                        OutlinedButton.icon(
                          key: const ValueKey('oauth_cancel_button'),
                          onPressed: () async {
                            setState(() {
                              _oauthLoading = false;
                              _oauthStatus = '';
                              _oauthError =
                                  'Sign-in cancelled. Tap sign in with Hermes to try again.';
                            });
                            await widget.model.cancelSignIn();
                          },
                          icon: const Icon(Icons.close),
                          label: const Text('Cancel sign-in'),
                        ),
                      if (_oauthError.isNotEmpty)
                        Text(_oauthError,
                            key: const ValueKey('token_tab_oauth_error'),
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error)),
                    ] else ...[
                      // Signing in is the primary path when the gateway offers
                      // it, but the field below stays: a bearer token minted
                      // elsewhere is a legitimate way in, and hiding the field
                      // for exactly those gateways left no way to use one.
                      // The button is now ALWAYS offered on the OAuth tab.
                      // Gating it on the auth-flows probe was the reported
                      // bug in disguise: the probe needs a working credential,
                      // which is exactly what is missing at first sign-in or
                      // after a restart, so the gateway that most needed a
                      // sign-in button was the one hiding it. If the gateway
                      // truly cannot do the native flow, the attempt answers
                      // with a clear error instead of a missing button.
                      ...[
                        FilledButton.tonalIcon(
                          onPressed:
                              _oauthLoading || _connecting ? null : _signInOAuth,
                          icon: _oauthLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.login),
                          label: Text(_oauthLoading
                              ? _oauthStatus.isEmpty
                                  ? 'Signing in…'
                                  : _oauthStatus
                              : 'Sign in with Hermes'),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _nativeAvailable
                              ? 'Opens the system browser. Talaria catches the loopback callback and stores the token securely on this device.'
                              : 'Opens the system browser for a fresh Hermes sign-in. '
                                  'Talaria answers even when the gateway could not be '
                                  'queried for its sign-in support; if this gateway '
                                  'does not offer browser sign-in, the attempt says so.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                        // A browser flow the user abandoned (closed tab, phone
                        // switched apps) used to strand every button until the
                        // two-minute callback timeout expired. Cancel releases
                        // them at once; the loopback listener closes too.
                        if (_oauthLoading) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            key: const ValueKey('oauth_cancel_button'),
                            onPressed: () async {
                              setState(() {
                                _oauthLoading = false;
                                _oauthStatus = '';
                                _oauthError =
                                    'Sign-in cancelled. Tap Sign in with Hermes to try again.';
                              });
                              await widget.model.cancelSignIn();
                            },
                            icon: const Icon(Icons.close),
                            label: const Text('Cancel sign-in'),
                          ),
                        ],
                        if (_oauthError.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(_oauthError,
                                key: const ValueKey('oauth_error_text'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error)),
                          ),
                        const SizedBox(height: 14),
                      ],
                      if (_reauthReason.isNotEmpty || _authRejected)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            key: const ValueKey('reauth_needed_banner'),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.errorContainer
                                  .withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: theme.colorScheme.error
                                      .withValues(alpha: 0.5)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.lock_reset,
                                    size: 18,
                                    color: theme.colorScheme.error),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(_reauthMessage,
                                      style: theme.textTheme.bodySmall),
                                ),
                              ],
                            ),
                          ),
                        ),
                      TextFormField(
                        controller: _bearer,
                        decoration: InputDecoration(
                            labelText: 'Bearer token',
                            helperText: _nativeAvailable
                                ? 'Or paste an OAuth bearer token you already have instead of signing in.'
                                : 'OAuth bearer token (gated / public gateways). Paste one you already have, or test the connection to see whether this gateway can sign you in.',
                            helperMaxLines: 4),
                        obscureText: true,
                      ),
                    ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => _probe(),
                      icon: _probeLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.network_check),
                      label: Text(_probeLoading
                          ? 'Probing…'
                          : (_probeResult?.ok ?? false)
                              ? 'Reachable — re-probe'
                              : 'Test connection'),
                    ),
                    if (_probeResult != null)
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _probeResult!.ok
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: (_probeResult!.ok
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.error)
                                .withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _probeResult!.ok ? Icons.check_circle : Icons.error,
                              color: _probeResult!.ok
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.error,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(_probeResult!.summary,
                                  style: theme.textTheme.bodySmall),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 20),
                    // The last failed attempt, whatever entry point ran it.
                    // This failure was previously invisible: the buttons
                    // re-armed and nothing explained the rejection, which is
                    // why a dead credential after a gateway restart looked
                    // like a silent unexplained failure.
                    if (_connectError != null && !_connecting)
                      Container(
                        key: const ValueKey('connect_error_banner'),
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: theme.colorScheme.error
                                  .withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            Icon(_authRejected
                                ? Icons.lock_reset
                                : Icons.error_outline,
                                color: theme.colorScheme.error, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _authRejected
                                    ? (_connectError ??
                                        'The gateway rejected your sign-in. Sign in again.')
                                    : _connectError!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: _connecting ? null : _connect,
                      icon: _connecting
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: theme.colorScheme.onPrimary))
                          : const Icon(Icons.rocket_launch),
                      label: Text(_connecting ? 'Connecting…' : 'Connect'),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _logo(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: 96,
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            cs.primary.withValues(alpha: 0.15),
            cs.primary.withValues(alpha: 0.05),
          ],
        ),
        border: Border.all(
          color: cs.primary.withValues(alpha: 0.4),
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Image.asset('assets/logo.png', fit: BoxFit.contain),
      ),
    );
  }
}
