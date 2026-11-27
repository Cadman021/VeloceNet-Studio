//! `--health-check`: fetch one URL and report whether it answered 200.
//!
//! A container image without curl or wget still needs a HEALTHCHECK, so the
//! binary can ask its own `/readyz` (or a proxy in front of it) and translate
//! the answer into an exit code. It speaks just enough HTTP/1.1 for that:
//! one GET, read the status line, close. No keep-alive, no chunked bodies, no
//! redirects, no TLS -- an https:// URL is rejected instead of silently
//! checking nothing.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::{Duration, Instant};

/// Generous enough for a loaded VM, short enough for a HEALTHCHECK timeout.
const TIMEOUT: Duration = Duration::from_secs(3);
const MAX_HEAD_BYTES: usize = 16 * 1024;

#[derive(Debug)]
pub struct Target {
    host: String,
    port: u16,
    path: String,
}

impl Target {
    pub fn parse(url: &str) -> Result<Self, String> {
        let rest = url.strip_prefix("http://").ok_or_else(|| {
            format!("unsupported URL {url}: use http://HOST[:PORT]/PATH (https needs a proxy)")
        })?;
        let (authority, path) = match rest.find('/') {
            Some(index) => (&rest[..index], &rest[index..]),
            None => (rest, "/"),
        };
        if authority.is_empty() {
            return Err(format!("invalid URL {url}: missing host"));
        }
        if authority.contains('@') {
            return Err(format!(
                "invalid URL {url}: put the token in --http-token-file, not in the URL"
            ));
        }
        let (host, port) = split_authority(url, authority)?;
        Ok(Self {
            host,
            port,
            path: path.to_string(),
        })
    }

    fn authority(&self) -> String {
        if self.host.contains(':') {
            format!("[{}]:{}", self.host, self.port)
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }
}

fn split_authority(url: &str, authority: &str) -> Result<(String, u16), String> {
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let (host, tail) = rest
            .split_once(']')
            .ok_or_else(|| format!("invalid URL {url}: unterminated IPv6 address"))?;
        let port = match tail {
            "" => 80,
            other => other
                .strip_prefix(':')
                .ok_or_else(|| format!("invalid URL {url}: unexpected text after ]"))?
                .parse()
                .map_err(|_| format!("invalid port in {url}"))?,
        };
        (host.to_string(), port)
    } else if authority.contains(':') {
        let (host, port) = authority.split_once(':').expect("contains a colon");
        if host.contains(':') {
            return Err(format!("invalid URL {url}: write IPv6 hosts as [::1]"));
        }
        let port = port.parse().map_err(|_| format!("invalid port in {url}"))?;
        (host.to_string(), port)
    } else {
        (authority.to_string(), 80)
    };
    if host.is_empty() {
        return Err(format!("invalid URL {url}: missing host"));
    }
    Ok((host, port))
}

/// GETs the target path and returns a one-line description on 200.
pub fn fetch(target: &Target, token: Option<&str>) -> Result<String, String> {
    let started = Instant::now();
    let addresses: Vec<_> = (target.host.as_str(), target.port)
        .to_socket_addrs()
        .map_err(|error| format!("cannot resolve {}: {error}", target.host))?
        .collect();
    let mut failure = format!("no address for {}", target.host);
    let mut stream = None;
    for address in &addresses {
        match TcpStream::connect_timeout(address, TIMEOUT) {
            Ok(connected) => {
                stream = Some(connected);
                break;
            }
            Err(error) => failure = error.to_string(),
        }
    }
    let mut stream =
        stream.ok_or_else(|| format!("cannot connect to {}: {failure}", target.authority()))?;
    stream
        .set_read_timeout(Some(TIMEOUT))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(TIMEOUT))
        .map_err(|error| error.to_string())?;

    let mut request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: netstudio-headless/{}\r\nConnection: close\r\n",
        target.path,
        target.authority(),
        super::VERSION
    );
    if let Some(token) = token {
        request.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .map_err(|error| format!("cannot send the request: {error}"))?;

    let mut buffer = Vec::new();
    let mut chunk = [0u8; 1_024];
    loop {
        let read = stream
            .read(&mut chunk)
            .map_err(|error| format!("cannot read the response: {error}"))?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.windows(4).any(|window| window == b"\r\n\r\n") || buffer.len() >= MAX_HEAD_BYTES {
            break;
        }
    }
    let head = String::from_utf8_lossy(&buffer);
    let status_line = head
        .lines()
        .next()
        .ok_or_else(|| "empty response (is this an HTTP server?)".to_string())?;
    let code: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse().ok())
        .ok_or_else(|| format!("malformed status line: {status_line}"))?;
    if code == 200 {
        return Ok(format!(
            "200 {} in {} ms",
            target.path,
            started.elapsed().as_millis()
        ));
    }
    Err(format!(
        "{} {} answered {code} (expected 200)",
        target.authority(),
        target.path
    ))
}

/// Runs the check and returns the process exit code (0 ok, 1 unhealthy,
/// 2 usage error).
pub fn main(url: &str, token_file: Option<&Path>) -> i32 {
    let target = match Target::parse(url) {
        Ok(target) => target,
        Err(error) => {
            super::log::error(error);
            return super::EXIT_CONFIG;
        }
    };
    let token = match token_file {
        Some(path) => match std::fs::read_to_string(path) {
            Ok(contents) if !contents.trim().is_empty() => Some(contents.trim().to_string()),
            Ok(_) => {
                super::log::error(format!("token file {} is empty", path.display()));
                return super::EXIT_CONFIG;
            }
            Err(error) => {
                super::log::error(format!(
                    "cannot read token file {}: {error}",
                    path.display()
                ));
                return super::EXIT_CONFIG;
            }
        },
        None => std::env::var("NETSTUDIO_HTTP_TOKEN")
            .ok()
            .filter(|token| !token.is_empty()),
    };
    match fetch(&target, token.as_deref()) {
        Ok(summary) => {
            super::log::info(summary);
            super::EXIT_OK
        }
        Err(error) => {
            super::log::error(error);
            super::EXIT_FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hosts_ports_and_paths() {
        let target = Target::parse("http://127.0.0.1:9101/readyz").expect("parse");
        assert_eq!(target.host, "127.0.0.1");
        assert_eq!(target.port, 9101);
        assert_eq!(target.path, "/readyz");

        let bare = Target::parse("http://example.test").expect("parse");
        assert_eq!(bare.port, 80);
        assert_eq!(bare.path, "/");

        let v6 = Target::parse("http://[::1]:9101/healthz").expect("parse");
        assert_eq!(v6.host, "::1");
        assert_eq!(v6.authority(), "[::1]:9101");
    }

    #[test]
    fn rejects_urls_it_cannot_check() {
        for url in [
            "https://127.0.0.1:9101/readyz",
            "127.0.0.1:9101/readyz",
            "http://:9101/readyz",
            "http://user:pass@127.0.0.1:9101/readyz",
            "http://127.0.0.1:notaport/readyz",
            "http://::1:9101/readyz",
            "http://[::1/readyz",
        ] {
            assert!(Target::parse(url).is_err(), "{url} should be rejected");
        }
    }
}
