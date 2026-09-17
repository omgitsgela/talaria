import 'package:flutter/material.dart';

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
  }

  @override
  void dispose() {
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

  Future<void> _probe() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _probeLoading = true;
      _probeResult = null;
      _nativeAvailable = false;
      _oauthError = '';
    });
    final http = GatewayHttp(_build());
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
                    Text(
                        'Chat, live tool activity, sessions, and models — driven over the gateway WebSocket API.',
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
                                'The dashboard X-Hermes-Session-Token (loopback / --insecure gateways).'),
                        obscureText: true,
                      )
                    else if (_nativeAvailable)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed:
                                _oauthLoading || _connecting ? null : _signInOAuth,
                            icon: _oauthLoading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2))
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
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          if (_oauthError.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(_oauthError,
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(color: theme.colorScheme.error)),
                            ),
                        ],
                      )
                    else
                      TextFormField(
                        controller: _bearer,
                        decoration: const InputDecoration(
                            labelText: 'Bearer token',
                            helperText:
                                'OAuth bearer token (gated / public gateways). Minted by the native sign-in flow.'),
                        obscureText: true,
                      ),
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
      child: Icon(Icons.flight_takeoff,
          size: 48, color: cs.primary),
    );
  }
}
