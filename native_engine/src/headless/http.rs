//! Small blocking HTTP server for health, status and Prometheus scraping.

use std::io::{ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use super::{metrics, State, NAME, VERSION};

struct Response {
    status: u16,
    reason: &'static str,
    content_type: &'static str,
    body: Vec<u8>,
    allow: Option<&'static str>,
}

impl Response {
    fn text(status: u16, reason: &'static str, body: String) -> Self {
        Self {
            status,
            reason,
            content_type: "text/plain; charset=utf-8",
            body: body.into_bytes(),
            allow: None,
        }
    }

    fn json(body: String) -> Self {
        Self {
            status: 200,
            reason: "OK",
            content_type: "application/json; charset=utf-8",
            body: body.into_bytes(),
            allow: None,
        }
    }
}

pub struct Server {
    addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

impl Server {
    pub fn spawn(addr: SocketAddr, state: Arc<State>) -> std::io::Result<Self> {
        let listener = TcpListener::bind(addr)?;
        listener.set_nonblocking(true)?;
        let local = listener.local_addr()?;
        let shutdown = Arc::new(AtomicBool::new(false));
        let flag = shutdown.clone();
        let handle = thread::Builder::new()
            .name("netstudio-http".to_string())
            .spawn(move || {
                while !flag.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((stream, _peer)) => {
                            let state = state.clone();
                            let _ = thread::Builder::new()
                                .name("netstudio-http-conn".to_string())
                                .spawn(move || handle_connection(stream, state));
                        }
                        Err(error) if error.kind() == ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(50));
                        }
                        Err(_) => thread::sleep(Duration::from_millis(100)),
                    }
                }
            })?;
        Ok(Self {
            addr: local,
            shutdown,
            handle: Some(handle),
        })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn stop(&mut self) {
        self.shutdown.store(true, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop();
    }
}

fn handle_connection(mut stream: TcpStream, state: Arc<State>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let Some(request) = read_request(&mut stream) else {
        return;
    };
    let line = request.lines().next().unwrap_or("");
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("");
    let path = target.split("?").next().unwrap_or("");
    let path = path.split("#").next().unwrap_or("");
    let head_only = method.eq_ignore_ascii_case("HEAD");
    let response = if method.eq_ignore_ascii_case("GET") || head_only {
        route(path, &state)
    } else {
        Response {
            allow: Some("GET, HEAD"),
            ..Response::text(
                405,
                "Method Not Allowed",
                "method not allowed\n".to_string(),
            )
        }
    };
    write_response(&mut stream, &response, head_only);
}

fn read_request(stream: &mut TcpStream) -> Option<String> {
    let mut data = Vec::with_capacity(1_024);
    let mut chunk = [0u8; 1_024];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => {
                data.extend_from_slice(&chunk[..read]);
                if data.len() >= 8_192 || data.windows(4).any(|window| window == b"\r\n\r\n") {
                    break;
                }
            }
            Err(error)
                if error.kind() == ErrorKind::WouldBlock || error.kind() == ErrorKind::TimedOut =>
            {
                break;
            }
            Err(_) => return None,
        }
    }
    if data.is_empty() {
        None
    } else {
        Some(String::from_utf8_lossy(&data).into_owned())
    }
}

fn route(path: &str, state: &State) -> Response {
    match path {
        "/" | "/index.html" => Response::text(
            200,
            "OK",
            format!(
                "{NAME} {VERSION}\n\nGET /healthz\nGET /readyz\nGET /metrics\nGET /api/v1/status\n"
            ),
        ),
        "/healthz" => Response::text(200, "OK", "ok\n".to_string()),
        "/readyz" => {
            if state.ready() {
                Response::text(200, "OK", "ready\n".to_string())
            } else {
                Response::text(503, "Service Unavailable", "starting\n".to_string())
            }
        }
        "/metrics" => Response {
            content_type: "text/plain; version=0.0.4; charset=utf-8",
            ..Response::text(200, "OK", metrics::render(&state.stats(), VERSION))
        },
        "/api/v1/status" => Response::json(format!("{}\n", state.snapshot().to_json())),
        _ => Response::text(404, "Not Found", "not found\n".to_string()),
    }
}

fn write_response(stream: &mut TcpStream, response: &Response, head_only: bool) {
    let mut header = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n",
        response.status,
        response.reason,
        response.content_type,
        response.body.len()
    );
    if let Some(allow) = response.allow {
        header.push_str("Allow: ");
        header.push_str(allow);
        header.push_str("\r\n");
    }
    header.push_str("\r\n");
    let _ = stream.write_all(header.as_bytes());
    if !head_only {
        let _ = stream.write_all(&response.body);
    }
    let _ = stream.flush();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::TargetMetricTracker;

    fn state_with_sample() -> Arc<State> {
        let state = State::new(1);
        let mut tracker = TargetMetricTracker::new(
            1,
            "Local".to_string(),
            "127.0.0.1".to_string(),
            80,
            "TCP".to_string(),
        );
        tracker.record_sample(true, 1.5, None, None);
        state.update(vec![tracker.snapshot()]);
        state
    }

    fn start(state: Arc<State>) -> Server {
        Server::spawn("127.0.0.1:0".parse().expect("loopback"), state).expect("spawn")
    }

    fn request(server: &Server, method: &str, path: &str) -> String {
        let mut stream = TcpStream::connect(server.addr()).expect("connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        let request =
            format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        stream.write_all(request.as_bytes()).expect("write");
        let mut response = String::new();
        stream.read_to_string(&mut response).expect("read");
        response
    }

    fn body(response: &str) -> &str {
        response
            .split_once("\r\n\r\n")
            .map(|(_, body)| body)
            .unwrap_or("")
    }

    #[test]
    fn health_and_index_are_served() {
        let server = start(State::new(1));
        let health = request(&server, "GET", "/healthz");
        assert!(health.starts_with("HTTP/1.1 200 OK\r\n"));
        assert_eq!(body(&health), "ok\n");
        let index = request(&server, "GET", "/");
        assert!(index.contains("netstudio-headless"));
    }

    #[test]
    fn metrics_and_status_report_the_snapshot() {
        let server = start(state_with_sample());
        let metrics = request(&server, "GET", "/metrics");
        assert!(metrics.contains("netstudio_target_up{id=\"1\""));
        assert!(metrics.contains("# TYPE netstudio_target_status gauge"));
        let status = request(&server, "GET", "/api/v1/status");
        let json: serde_json::Value = serde_json::from_str(body(&status)).expect("json");
        assert_eq!(json["schema"], 1);
        assert_eq!(json["targets"][0]["id"], 1);
        assert_eq!(json["targets"][0]["received_count"], 1);
    }

    #[test]
    fn readiness_flips_after_the_first_sample() {
        let server = start(State::new(1));
        let starting = request(&server, "GET", "/readyz");
        assert!(starting.starts_with("HTTP/1.1 503"));
        let state = state_with_sample();
        let server = start(state);
        let ready = request(&server, "GET", "/readyz");
        assert!(ready.starts_with("HTTP/1.1 200"));
    }

    #[test]
    fn head_has_headers_but_no_body() {
        let server = start(State::new(1));
        let response = request(&server, "HEAD", "/healthz");
        assert!(response.contains("Content-Length: 3\r\n"));
        assert_eq!(body(&response), "");
    }

    #[test]
    fn unsupported_methods_and_unknown_paths_are_rejected() {
        let server = start(State::new(1));
        let post = request(&server, "POST", "/metrics");
        assert!(post.starts_with("HTTP/1.1 405"));
        assert!(post.contains("Allow: GET, HEAD"));
        let missing = request(&server, "GET", "/nope");
        assert!(missing.starts_with("HTTP/1.1 404"));
    }
}
