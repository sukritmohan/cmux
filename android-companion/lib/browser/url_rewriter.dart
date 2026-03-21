/// URL classification and Tailscale IP rewriting for the browser pane.
///
/// Local URLs (localhost, 127.0.0.1, 0.0.0.0) are rewritten to the Mac's
/// Tailscale IP so the phone can reach dev servers running on the desktop.
/// External URLs pass through unchanged.
library;

/// Whether a URL targets a local dev server or an external site.
enum UrlClassification { local, external }

/// Checks if [host] is in the Tailscale CGNAT range (100.64.0.0/10).
///
/// This covers addresses 100.64.0.0 through 100.127.255.255.
bool isTailscaleCgnat(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;

  final octets = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
    octets.add(n);
  }

  // 100.64.0.0/10 → first octet == 100, second octet 64–127
  return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
}

/// Extracts the host portion from a URL string, stripping scheme and port.
String _extractHost(String url) {
  var host = url;

  // Strip scheme
  final schemeEnd = host.indexOf('://');
  if (schemeEnd != -1) {
    host = host.substring(schemeEnd + 3);
  }

  // Strip path
  final pathStart = host.indexOf('/');
  if (pathStart != -1) {
    host = host.substring(0, pathStart);
  }

  // Strip port
  final portStart = host.lastIndexOf(':');
  if (portStart != -1) {
    host = host.substring(0, portStart);
  }

  return host;
}

/// Classifies a URL as local (needs Tailscale rewriting) or external.
///
/// Local hosts: localhost, 127.0.0.1, 0.0.0.0, and any Tailscale CGNAT IP.
UrlClassification classifyUrl(String url) {
  final host = _extractHost(url).toLowerCase();

  if (host == 'localhost' || host == '127.0.0.1' || host == '0.0.0.0') {
    return UrlClassification.local;
  }

  if (isTailscaleCgnat(host)) {
    return UrlClassification.local;
  }

  return UrlClassification.external;
}

/// Rewrites a local URL to use the Mac's Tailscale IP.
///
/// Replaces localhost/127.0.0.1/0.0.0.0 with [tailscaleIp].
/// External URLs and already-rewritten Tailscale IPs pass through unchanged.
String rewriteUrl(String url, String tailscaleIp) {
  if (classifyUrl(url) == UrlClassification.external) return url;

  final host = _extractHost(url).toLowerCase();

  // Already a Tailscale IP — no rewrite needed
  if (isTailscaleCgnat(host)) return url;

  // Replace the local host with the Tailscale IP
  return url.replaceFirst(RegExp(r'(localhost|127\.0\.0\.1|0\.0\.0\.0)'), tailscaleIp);
}

/// Parsed URL components for styled rendering in the URL bar.
({String scheme, String host, String path}) parseDisplayUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    return (scheme: '', host: url, path: '');
  }

  final scheme = '${uri.scheme}://';
  final host = uri.host + (uri.hasPort ? ':${uri.port}' : '');
  final path = uri.path + (uri.hasQuery ? '?${uri.query}' : '');

  return (scheme: scheme, host: host, path: path);
}
