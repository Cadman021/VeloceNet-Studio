//! HTTP/HTTPS probes: TTFB (reported as the sample RTT), response status,
//! and — for HTTPS — the peer certificate's days-to-expiry.
//!
//! Design notes:
//! - Blocking (std TcpStream + sync rustls `StreamOwned`): callers run it
//!   inside `spawn_blocking`, matching the ICMP probe pattern.
//! - TLS uses the ring backend (already in the tree via boringtun) with a
//!   **capturing verifier** that accepts any certificate and records it:
//!   a monitor must still measure TTFB and report the notAfter date for
//!   expired/self-signed certs instead of refusing to connect.
//! - TTFB is measured from just before TCP connect to the first response
//!   byte, so it includes DNS(skip), connect, TLS handshake and server
//!   think-time — the number operators expect from an HTTP check.
//! - Success = a parsed status line with code < 400; 4xx/5xx count as
//!   failures but still report the code so the UI can show "HTTP 503".

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use parking_lot::Mutex;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{
    ClientConfig, ClientConnection, DigitallySignedStruct, Error as TlsError, SignatureScheme,
    StreamOwned,
};

use super::tcp::ProbeResult;

/// Accepts every presented certificate after recording the chain, so the
/// probe can report the notAfter date even for expired/self-signed certs.
#[derive(Debug)]
struct CapturingVerifier {
    certs: Mutex<Vec<CertificateDer<'static>>>,
    schemes: Vec<SignatureScheme>,
}

impl ServerCertVerifier for CapturingVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        let mut store = self.certs.lock();
        store.clear();
        store.push(end_entity.clone().into_owned());
        store.extend(intermediates.iter().map(|c| c.clone().into_owned()));
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        // Signature check skipped deliberately: the verifier never gates
        // the handshake — this probe measures reachability, not trust.
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes.clone()
    }
}

/// Blocking HTTP(S) probe. `tls` selects HTTPS. `path` must start with '/'
/// (falls back to "/" otherwise); it may include a query string.
pub fn probe_http_sync(
    host: &str,
    port: u16,
    tls: bool,
    path: &str,
    timeout_ms: u32,
) -> ProbeResult {
    let started = Instant::now();
    let total = Duration::from_millis(timeout_ms.clamp(1, 60_000) as u64);

    let remaining = || total.checked_sub(started.elapsed());

    // Resolve (part of the budget, like the TCP probe).
    let host_port = format_host_port(host, port);
    let addrs: Vec<SocketAddr> = match host_port.to_socket_addrs() {
        Ok(iter) => iter.collect(),
        Err(e) => return ProbeResult::failure(format!("DNS resolution failed: {}", e)),
    };
    if addrs.is_empty() {
        return ProbeResult::failure("No IP address resolved for host");
    }

    // Try every resolved address within the budget (IPv6-first hosts that
    // only listen on v4 must not fail the probe).
    let mut stream = None;
    let mut last_error = String::from("Connection timed out");
    for addr in &addrs {
        let Some(rem) = remaining().filter(|r| *r > Duration::from_millis(5)) else {
            return ProbeResult::failure("Timeout during resolution");
        };
        match TcpStream::connect_timeout(addr, rem) {
            Ok(s) => {
                stream = Some(s);
                break;
            }
            Err(e) => last_error = format!("Connect failed: {}", e),
        }
    }
    let Some(tcp) = stream else {
        return ProbeResult::failure(last_error);
    };

    if let Some(rem) = remaining() {
        let _ = tcp.set_read_timeout(Some(rem));
        let _ = tcp.set_write_timeout(Some(rem));
    }

    if tls {
        probe_over_tls(tcp, &host_port, path, started, timeout_ms)
    } else {
        probe_over_plain(tcp, &host_port, path, started, timeout_ms)
    }
}

fn probe_over_plain(
    tcp: TcpStream,
    host_port: &str,
    path: &str,
    started: Instant,
    timeout_ms: u32,
) -> ProbeResult {
    let mut stream = tcp;
    let request = build_request(host_port, path);
    if let Err(e) = stream.write_all(request.as_bytes()) {
        return timed_or_failed(e, "HTTP write failed");
    }
    read_response(&mut stream, started, timeout_ms, None)
}

fn probe_over_tls(
    tcp: TcpStream,
    host_port: &str,
    path: &str,
    started: Instant,
    timeout_ms: u32,
) -> ProbeResult {
    let server_name = match ServerName::try_from(host_of(host_port).to_string()) {
        Ok(name) => name,
        Err(_) => return ProbeResult::failure("Invalid host name for TLS"),
    };

    let verifier = Arc::new(CapturingVerifier {
        certs: Mutex::new(Vec::new()),
        schemes: rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes(),
    });
    let config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier.clone())
        .with_no_client_auth();

    let conn = match ClientConnection::new(Arc::new(config), server_name) {
        Ok(c) => c,
        Err(e) => return ProbeResult::failure(format!("TLS setup failed: {}", e)),
    };

    let mut stream = StreamOwned::new(conn, tcp);
    let request = build_request(host_port, path);
    if let Err(e) = stream.write_all(request.as_bytes()) {
        return timed_or_failed(e, "TLS handshake failed");
    }

    // Certificate dates are known as soon as the handshake finished (the
    // verifier ran during write_all above).
    let cert_days = verifier
        .certs
        .lock()
        .first()
        .and_then(|der| cert_days_left(der.as_ref()).ok());

    read_response(&mut stream, started, timeout_ms, cert_days)
}

/// Reads until the status line is complete; TTFB is stamped on the first
/// byte that arrives.
fn read_response<S: Read>(
    stream: &mut S,
    started: Instant,
    timeout_ms: u32,
    cert_days: Option<i64>,
) -> ProbeResult {
    let mut buf = [0u8; 2048];
    let mut acc: Vec<u8> = Vec::with_capacity(2048);
    let mut ttfb_ms: Option<f64> = None;

    loop {
        match stream.read(&mut buf) {
            Ok(0) => break, // EOF before a full status line
            Ok(n) => {
                if ttfb_ms.is_none() {
                    ttfb_ms = Some(started.elapsed().as_secs_f64() * 1000.0);
                }
                acc.extend_from_slice(&buf[..n]);
                if acc.windows(2).any(|w| w == b"\r\n") || acc.len() >= 8192 {
                    break;
                }
                if started.elapsed() > Duration::from_millis(timeout_ms as u64) {
                    break;
                }
            }
            Err(e) if is_timeout(&e) => {
                return ProbeResult::http(
                    false,
                    -1.0,
                    None,
                    cert_days,
                    Some("HTTP probe timed out".to_string()),
                );
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                return ProbeResult::http(
                    false,
                    -1.0,
                    None,
                    cert_days,
                    Some(format!("HTTP read failed: {}", e)),
                );
            }
        }
    }

    let Some(ttfb) = ttfb_ms else {
        return ProbeResult::http(
            false,
            -1.0,
            None,
            cert_days,
            Some("Connection closed before any response".to_string()),
        );
    };

    match parse_status_line(&acc) {
        Some(status) if status < 400 => {
            ProbeResult::http(true, ttfb, Some(status), cert_days, None)
        }
        Some(status) => ProbeResult::http(
            false,
            -1.0,
            Some(status),
            cert_days,
            Some(format!("HTTP {}", status)),
        ),
        None => ProbeResult::http(
            false,
            -1.0,
            None,
            cert_days,
            Some("Invalid HTTP response".to_string()),
        ),
    }
}

fn timed_or_failed(e: std::io::Error, context: &str) -> ProbeResult {
    if is_timeout(&e) {
        ProbeResult::failure(format!("{}: timed out", context))
    } else {
        ProbeResult::failure(format!("{}: {}", context, e))
    }
}

fn is_timeout(e: &std::io::Error) -> bool {
    matches!(
        e.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    )
}

fn build_request(host_port: &str, path: &str) -> String {
    let path = if path.starts_with('/') { path } else { "/" };
    format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: VeloceNetStudio/{}\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        path,
        host_port,
        env!("CARGO_PKG_VERSION")
    )
}

/// "host:port", bracketing IPv6 literals; the port is omitted for the
/// scheme defaults so the Host header stays canonical.
fn format_host_port(host: &str, port: u16) -> String {
    let host = host.trim();
    let bracketed = if host.contains(':') && !host.starts_with('[') {
        format!("[{}]", host)
    } else {
        host.to_string()
    };
    if port == 80 || port == 443 {
        bracketed
    } else {
        format!("{}:{}", bracketed, port)
    }
}

/// Strips a trailing :port (and IPv6 brackets) for the TLS ServerName.
fn host_of(host_port: &str) -> &str {
    if let Some(rest) = host_port.strip_prefix('[') {
        // [v6]:port or [v6]
        return rest.split(']').next().unwrap_or(rest);
    }
    match host_port.rsplit_once(':') {
        Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => h,
        _ => host_port,
    }
}

/// Parses "HTTP/1.1 200 OK" from the head of a response.
fn parse_status_line(head: &[u8]) -> Option<u16> {
    let line_end = head
        .windows(2)
        .position(|w| w == b"\r\n")
        .or_else(|| head.iter().position(|&b| b == b'\n'))?;
    let line = std::str::from_utf8(&head[..line_end]).ok()?;
    let mut parts = line.split_whitespace();
    let version = parts.next()?;
    if !version.starts_with("HTTP/") {
        return None;
    }
    parts.next()?.parse::<u16>().ok()
}

/// Days until the certificate's notAfter, negative once expired.
fn cert_days_left(der: &[u8]) -> Result<i64, &'static str> {
    let not_after = cert_not_after_unix(der).ok_or("unparseable certificate")?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "clock before epoch")?
        .as_secs() as i64;
    Ok((not_after - now).div_euclid(86_400))
}

/// DER walk to tbsCertificate.validity.notAfter:
/// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE {
///   [0] version?, serialNumber INTEGER, signature SEQUENCE,
///   issuer SEQUENCE, validity SEQUENCE { notBefore, notAfter } ...
fn cert_not_after_unix(der: &[u8]) -> Option<i64> {
    let (tag, cert_body, _) = read_tlv(der)?;
    if tag != 0x30 {
        return None;
    }
    let (tag, tbs, _) = read_tlv(cert_body)?;
    if tag != 0x30 {
        return None;
    }

    let mut rest = tbs;
    let (tag, _, len) = read_tlv(rest)?;
    if tag == 0xA0 {
        // Optional [0] EXPLICIT version (present from v2 on).
        rest = &rest[len..];
    }
    // serialNumber, signature, issuer.
    for _ in 0..3 {
        let (_, _, len) = read_tlv(rest)?;
        rest = &rest[len..];
    }
    let (tag, validity, _) = read_tlv(rest)?;
    if tag != 0x30 {
        return None;
    }
    let (_, _, nb_len) = read_tlv(validity)?; // notBefore (unused)
    let (na_tag, na_body, _) = read_tlv(&validity[nb_len..])?;
    parse_asn1_time(na_tag, na_body)
}

/// DER TLV reader: returns (tag, body, total encoded length).
fn read_tlv(data: &[u8]) -> Option<(u8, &[u8], usize)> {
    let tag = *data.first()?;
    let first_len = *data.get(1)?;
    let (len, header) = if first_len & 0x80 == 0 {
        (first_len as usize, 2usize)
    } else {
        let n = (first_len & 0x7F) as usize;
        if n == 0 || n > 4 {
            return None; // indefinite length is invalid in DER
        }
        let mut len = 0usize;
        for i in 0..n {
            len = (len << 8) | (*data.get(2 + i)? as usize);
        }
        (len, 2 + n)
    };
    let end = header.checked_add(len)?;
    if data.len() < end {
        return None;
    }
    Some((tag, &data[header..end], end))
}

/// UTCTime (0x17, YYMMDDHHMMSSZ) / GeneralizedTime (0x18, YYYYMMDDHHMMSSZ).
fn parse_asn1_time(tag: u8, body: &[u8]) -> Option<i64> {
    let s = std::str::from_utf8(body).ok()?;
    let s = s.strip_suffix('Z')?;
    let (year, rest) = match tag {
        0x17 if s.len() == 12 => {
            let yy: i64 = s[0..2].parse().ok()?;
            // RFC 5280: years 50-99 are 19xx, 00-49 are 20xx.
            (if yy >= 50 { 1900 + yy } else { 2000 + yy }, &s[2..])
        }
        0x18 if s.len() == 14 => (s[0..4].parse().ok()?, &s[4..]),
        _ => return None,
    };
    let month: i64 = rest[0..2].parse().ok()?;
    let day: i64 = rest[2..4].parse().ok()?;
    let hour: i64 = rest[4..6].parse().ok()?;
    let min: i64 = rest[6..8].parse().ok()?;
    let sec: i64 = rest[8..10].parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || min > 59 || sec > 60 {
        return None;
    }
    // Howard Hinnant's days-from-civil.
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hour * 3_600 + min * 60 + sec)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    fn tlv(tag: u8, body: &[u8]) -> Vec<u8> {
        let mut out = vec![tag];
        if body.len() < 0x80 {
            out.push(body.len() as u8);
        } else {
            out.push(0x82);
            out.push((body.len() >> 8) as u8);
            out.push((body.len() & 0xFF) as u8);
        }
        out.extend_from_slice(body);
        out
    }

    fn utc_time(s: &str) -> Vec<u8> {
        tlv(0x17, s.as_bytes())
    }

    #[test]
    fn parse_asn1_time_handles_utc_and_generalized() {
        assert_eq!(parse_asn1_time(0x17, b"700101000000Z"), Some(0));
        assert_eq!(parse_asn1_time(0x17, b"000101000000Z"), Some(946_684_800));
        assert_eq!(
            parse_asn1_time(0x18, b"20300101000000Z"),
            Some(1_893_456_000)
        );
        assert_eq!(parse_asn1_time(0x17, b"491231235959Z"), Some(2_524_607_999));
        assert!(parse_asn1_time(0x17, b"991332000000Z").is_none()); // month 13
        assert!(parse_asn1_time(0x18, b"2030010100000Z").is_none()); // short
    }

    #[test]
    fn cert_not_after_walks_minimal_cert() {
        // SEQUENCE { SEQUENCE { INTEGER serial, SEQ algo, SEQ issuer,
        //   SEQ validity { UTCTime nb, UTCTime na }, SEQ subject } }
        let validity = tlv(
            0x30,
            &[utc_time("240101000000Z"), utc_time("300101000000Z")].concat(),
        );
        let tbs = tlv(
            0x30,
            &[
                tlv(0x02, &[0x01]), // serialNumber
                tlv(0x30, &[]),     // signature algorithm
                tlv(0x30, &[]),     // issuer
                validity,           // validity
                tlv(0x30, &[]),     // subject
            ]
            .concat(),
        );
        let cert = tlv(0x30, &tbs);
        assert_eq!(cert_not_after_unix(&cert), Some(1_893_456_000));

        // Same, but with the optional [0] EXPLICIT version present.
        let v3_tbs = tlv(
            0x30,
            &[
                tlv(0xA0, &tlv(0x02, &[0x02])), // [0] { INTEGER 2 }
                tlv(0x02, &[0x01]),
                tlv(0x30, &[]),
                tlv(0x30, &[]),
                tlv(
                    0x30,
                    &[utc_time("240101000000Z"), utc_time("300101000000Z")].concat(),
                ),
                tlv(0x30, &[]),
            ]
            .concat(),
        );
        let cert_v3 = tlv(0x30, &v3_tbs);
        assert_eq!(cert_not_after_unix(&cert_v3), Some(1_893_456_000));

        assert!(cert_not_after_unix(&[0x30, 0x01, 0x00]).is_none());
        assert!(cert_not_after_unix(b"not der").is_none());
    }

    #[test]
    fn parses_status_lines() {
        assert_eq!(parse_status_line(b"HTTP/1.1 200 OK\r\nX: y\r\n"), Some(200));
        assert_eq!(
            parse_status_line(b"HTTP/1.0 503 Service Unavailable\r\n"),
            Some(503)
        );
        assert_eq!(parse_status_line(b"BOGUS 200 OK\r\n"), None);
        assert_eq!(parse_status_line(b"HTTP/1.1\r\n"), None);
    }

    #[test]
    fn probe_plain_http_loopback_reports_status_and_ttfb() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            if let Ok((mut s, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = s.read(&mut buf);
                let _ = s.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
            }
        });

        let res = probe_http_sync("127.0.0.1", port, false, "/health", 3000);
        assert!(res.success, "probe failed: {:?}", res.error);
        assert_eq!(res.http_status, Some(204));
        assert!(res.rtt_ms > 0.0);
        assert_eq!(res.cert_days_left, None);
    }

    #[test]
    fn probe_plain_http_reports_5xx_as_failure() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            if let Ok((mut s, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = s.read(&mut buf);
                let _ = s.write_all(b"HTTP/1.1 503 Service Unavailable\r\n\r\n");
            }
        });

        let res = probe_http_sync("127.0.0.1", port, false, "/", 3000);
        assert!(!res.success);
        assert_eq!(res.http_status, Some(503));
        assert_eq!(res.error.as_deref(), Some("HTTP 503"));
    }

    #[test]
    fn probe_plain_http_times_out_on_silent_server() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        // Detached on purpose: the accept thread outlives the (short) probe.
        std::thread::spawn(move || {
            if let Ok((_s, _)) = listener.accept() {
                std::thread::sleep(Duration::from_secs(2));
            }
        });

        let res = probe_http_sync("127.0.0.1", port, false, "/", 300);
        assert!(!res.success);
        assert_eq!(res.http_status, None);
        assert!(
            res.error.as_deref().unwrap_or("").contains("timed out"),
            "unexpected error: {:?}",
            res.error
        );
    }

    #[test]
    fn probe_https_loopback_reports_status_and_cert_days() {
        use rcgen::{date_time_ymd, CertificateParams, KeyPair};
        use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};

        let mut params = CertificateParams::new(vec!["localhost".to_string()]).unwrap();
        params.not_before = date_time_ymd(2020, 1, 1);
        params.not_after = date_time_ymd(2030, 1, 1);
        let key = KeyPair::generate().unwrap();
        let cert = params.self_signed(&key).unwrap();

        let expected_days = cert_days_left(cert.der().as_ref()).unwrap();

        let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
        let server_config = Arc::new(
            rustls::ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(vec![cert.der().clone()], key_der)
                .unwrap(),
        );

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            if let Ok((tcp, _)) = listener.accept() {
                let conn = rustls::ServerConnection::new(server_config).unwrap();
                let mut stream = rustls::StreamOwned::new(conn, tcp);
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
                let _ = stream.flush();
            }
        });

        let res = probe_http_sync("127.0.0.1", port, true, "/", 5000);
        assert!(res.success, "probe failed: {:?}", res.error);
        assert_eq!(res.http_status, Some(200));
        let days = res.cert_days_left.expect("cert days missing");
        // Same clock formula on both sides; ±1 day covers a midnight tick.
        assert!(
            (days - expected_days).abs() <= 1,
            "days={} expected≈{}",
            days,
            expected_days
        );
    }
}
