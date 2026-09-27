/// When the app may speak plain HTTP, and when it must not.
///
/// Talaria is a client for a gateway the user points it at, and a self-hosted
/// Hermes gateway on a LAN is normally plain `http://`. That makes a blanket
/// "no cleartext" rule unusable, and a blanket "allow cleartext" rule is what
/// Google's published guidance warns against: cleartext enabled application-wide
/// sends the session token and every prompt in the clear wherever the app is
/// pointed.
///
/// So the rule is by HOST: a private, loopback or link-local destination may be
/// plain http, because that traffic never leaves the local network; anything
/// reachable on the public internet must be https. That keeps a LAN gateway
/// working while closing the case that actually matters.
///
/// Note the deliberate leniency for naming conventions rather than only literal
/// IPs: self-hosted boxes are usually reached as a bare hostname (`autumn`) or
/// under a private-use suffix (`.local`, `.lan`, `.internal`, `.home.arpa`),
/// none of which resolve on the public internet.
library;

/// True when [host] is a destination where plain http is acceptable: loopback,
/// an RFC 1918 / link-local address, or a name that cannot resolve publicly.
bool isPrivateGatewayHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;

  // Strip an IPv6 zone index (`fe80::1%wlan0`) and any brackets.
  var bare = h;
  if (bare.startsWith('[') && bare.endsWith(']')) {
    bare = bare.substring(1, bare.length - 1);
  }
  final pct = bare.indexOf('%');
  if (pct >= 0) bare = bare.substring(0, pct);

  // IPv4-mapped IPv6 (`::ffff:192.168.1.5`) must not be a way to smuggle a
  // public address past the IPv4 checks.
  if (bare.startsWith('::ffff:')) bare = bare.substring(7);

  // An IPv6 literal is judged ONLY by the IPv6 rules. The bare-hostname rule
  // further down must never apply to one: a public address such as
  // `2606:4700::1111` contains no dot, and treating it as a LAN hostname would
  // let it through as cleartext. (Found by the round-48 tests.)
  if (bare.contains(':')) return _isPrivateIpv6(bare);

  if (bare == 'localhost' || bare.endsWith('.localhost')) return true;
  if (_isPrivateIpv4(bare)) return true;

  // Private-use naming. A bare name with no dot cannot resolve on the public
  // internet; the suffixes below are reserved for private networks.
  if (!bare.contains('.')) return true;
  for (final suffix in const <String>[
    '.local',
    '.lan',
    '.internal',
    '.home',
    '.home.arpa',
  ]) {
    if (bare.endsWith(suffix)) return true;
  }
  return false;
}

bool _isPrivateIpv4(String h) {
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return false;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
    octets.add(n);
  }
  final a = octets[0];
  final b = octets[1];
  if (a == 127) return true; // loopback 127.0.0.0/8
  if (a == 10) return true; // 10.0.0.0/8
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a == 192 && b == 168) return true; // 192.168.0.0/16
  if (a == 169 && b == 254) return true; // link-local 169.254.0.0/16
  return false;
}

bool _isPrivateIpv6(String h) {
  if (!h.contains(':')) return false;
  if (h == '::1' || h == '0:0:0:0:0:0:0:1') return true; // loopback
  final first = h.split(':').first;
  if (first.isEmpty) return false;
  if (first.startsWith('fe8') ||
      first.startsWith('fe9') ||
      first.startsWith('fea') ||
      first.startsWith('feb')) {
    return true; // link-local fe80::/10
  }
  if (first.startsWith('fc') || first.startsWith('fd')) {
    return true; // unique local fc00::/7
  }
  return false;
}

/// The scheme to assume when someone types a gateway address with no scheme.
/// Private destinations keep plain http (how a self-hosted gateway runs);
/// anything else is assumed to be https rather than silently sent in the clear.
String defaultSchemeForHost(String host) =>
    isPrivateGatewayHost(host) ? 'http' : 'https';

/// Why this gateway URL must not be used, or null when it is acceptable.
/// Only the cleartext case is judged here.
String? cleartextRefusalFor(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.toLowerCase().startsWith('https://')) return null;

  final uri = Uri.tryParse(trimmed.contains('://') ? trimmed : 'http://$trimmed');
  final host = uri?.host ?? '';
  if (host.isEmpty) {
    return 'That does not look like a gateway address. Use a hostname or an IP.';
  }
  if (isPrivateGatewayHost(host)) return null;

  return 'Talaria will not send your token or your prompts over plain http to '
      '$host, because that traffic leaves your network in the clear. Use '
      'https://$host, or point it at a private or LAN address instead.';
}
