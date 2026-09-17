import 'dart:async';

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../gateway/config.dart';
import '../gateway/http_service.dart';
import '../gateway/native_oauth.dart';
import '../store/app_model.dart';

/// First-run / reconnect screen. Mirrors the desktop's "Connect to
/// existing Hermes": URL + auth (token or OAuth bearer) + optional
/// proxy headers, with a live probe before committing.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key, required this.model, this.onConnected});
  final AppModel model;
  final VoidCallback? onConnected;

  /// Test seam: the HTTP prober, so widget tests can drive auth-flow discovery
  /// without a live gateway.
  @visibleForTesting
  static GatewayHttp Function(GatewayConfig config)? httpFactoryForTest;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
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

  static const _defaultUrl = 'http://gw.example.internal:9119';

  /// Debounce for the quiet auth-flow discovery that runs while the user types
  /// a URL, so a gateway's sign-in option is known before anything is pressed.
  Timer? _flowDebounce;

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
    _url.addListener(_onUrlChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_discoverFlows());
    });
  }

  @override
  void dispose() {
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
      );

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
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final http = _http(_build());
    try {
      final flows = await http.authFlows();
      if (!mounted) return;
      if (!NativeOAuthService.flowsSupportNativeFlow(flows)) return;
      setState(() {
        _nativeAvailable = true;
        // Only move the user to the OAuth tab if they have not already started
        // entering a session token.
        if (_token.text.trim().isEmpty) _authToken = false;
      });
    } catch (_) {
      // No answer (offline, not a gateway, older build): leave the form alone.
    } finally {
      http.close();
    }
  }

  Future<void> _probe() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _probeLoading = true;
      _probeResult = null;
      _nativeAvailable = false;
      _oauthError = '';
    });
    final http = _http(_build());
    try {
      final result = await http.testConnection();
      // Detect whether this gateway advertises the RFC 8252 native flow so
      // we can offer "Sign in with Hermes" instead of a bearer field.
      final flows = await http.authFlows();
      final native = NativeOAuthService.flowsSupportNativeFlow(flows);
      if (!mounted) return;
      setState(() {
        _probeLoading = false;
        _probeResult = result;
        _nativeAvailable = native;
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
      await widget.model.connect(resolved);
      if (mounted) widget.onConnected?.call();
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
    await widget.model.connect(_build());
    if (mounted) widget.onConnected?.call();
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
                    if (_authToken)
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
                      )
                    else ...[
                      // Signing in is the primary path when the gateway offers
                      // it, but the field below stays: a bearer token minted
                      // elsewhere is a legitimate way in, and hiding the field
                      // for exactly those gateways left no way to use one.
                      if (_nativeAvailable) ...[
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
                          'Opens the system browser. Talaria catches the loopback callback and stores the token securely on this device.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                        if (_oauthError.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(_oauthError,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error)),
                          ),
                        const SizedBox(height: 14),
                      ],
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
