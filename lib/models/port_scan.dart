/// TCP port-scan result model + well-known service names.
enum PortState { open, closed, filtered }

class PortScanResult {
  final int port;
  final PortState state;
  final String service;
  final double rttMs;

  const PortScanResult({
    required this.port,
    required this.state,
    required this.service,
    required this.rttMs,
  });
}

/// Parses specs like "80,443,8000-8010" into a sorted, de-duplicated port
/// list. Returns null when the spec is malformed or exceeds [maxPorts].
List<int>? parsePortSpec(String spec, {int maxPorts = 4096}) {
  final ports = <int>{};
  final parts = spec.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
  if (parts.isEmpty) return null;
  for (final part in parts) {
    if (part.contains('-')) {
      final bounds = part.split('-');
      if (bounds.length != 2) return null;
      final from = int.tryParse(bounds[0].trim());
      final to = int.tryParse(bounds[1].trim());
      if (from == null || to == null || from < 1 || to > 65535 || from > to) {
        return null;
      }
      if (to - from + 1 + ports.length > maxPorts) return null;
      for (int p = from; p <= to; p++) {
        ports.add(p);
      }
    } else {
      final p = int.tryParse(part);
      if (p == null || p < 1 || p > 65535) return null;
      if (ports.length + 1 > maxPorts) return null;
      ports.add(p);
    }
    if (ports.length > maxPorts) return null;
  }
  if (ports.isEmpty) return null;
  final sorted = ports.toList()..sort();
  return sorted;
}

/// Best-effort service guess for display purposes only.
String serviceForPort(int port) {
  return _kWellKnownPorts[port] ?? '';
}

const Map<int, String> _kWellKnownPorts = {
  20: 'FTP-data',
  21: 'FTP',
  22: 'SSH',
  23: 'Telnet',
  25: 'SMTP',
  53: 'DNS',
  67: 'DHCP',
  68: 'DHCP',
  69: 'TFTP',
  80: 'HTTP',
  110: 'POP3',
  119: 'NNTP',
  123: 'NTP',
  143: 'IMAP',
  161: 'SNMP',
  194: 'IRC',
  389: 'LDAP',
  443: 'HTTPS',
  445: 'SMB',
  465: 'SMTPS',
  514: 'Syslog',
  587: 'SMTP-sub',
  636: 'LDAPS',
  993: 'IMAPS',
  995: 'POP3S',
  1433: 'MSSQL',
  1521: 'Oracle',
  1723: 'PPTP',
  3306: 'MySQL',
  3389: 'RDP',
  5432: 'Postgres',
  5900: 'VNC',
  6379: 'Redis',
  8080: 'HTTP-alt',
  8443: 'HTTPS-alt',
  27017: 'MongoDB',
};
