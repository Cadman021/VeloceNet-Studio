//! Small blocking HTTP server for health, status and Prometheus scraping.

use std::io::{ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use super::{metrics, State, NAME, VERSION};

/// Fixed worker pool: a slow or malicious client can pin at most this many
/// threads, no matter how many TCP connections are open.
const HTTP_WORKERS: usize = 8;
const HTTP_QUEUE_DEPTH: usize = 16;
const MAX_HEADER_BYTES: usize = 8 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const IO_TIMEOUT: Duration = Duration::from_secs(3);

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
    accept_handle: Option<thread::JoinHandle<()>>,
    workers: Vec<thread::JoinHandle<()>>,
    sender: Option<SyncSender<TcpStream>>,
}

impl Server {
    pub fn spawn(addr: SocketAddr, state: Arc<State>) -> std::io::Result<Self> {
        let listener = TcpListener::bind(addr)?;
        listener.set_nonblocking(true)?;
        let local = listener.local_addr()?;
        let shutdown = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = mpsc::sync_channel::<TcpStream>(HTTP_QUEUE_DEPTH);
        let receiver = Arc::new(Mutex::new(receiver));

        let mut workers: Vec<thread::JoinHandle<()>> = Vec::with_capacity(HTTP_WORKERS);
        for index in 0..HTTP_WORKERS {
            let worker_state = state.clone();
            let worker_receiver = receiver.clone();
            let worker_shutdown = shutdown.clone();
            let handle = match thread::Builder::new()
                .name(format!("netstudio-http-worker-{index}"))
                .spawn(move || worker_loop(worker_receiver, worker_state, worker_shutdown))
            {
                Ok(handle) => handle,
                Err(error) => {
                    shutdown.store(true, Ordering::SeqCst);
                    drop(sender);
                    for worker in workers {
                        let _ = worker.join();
                    }
                    return Err(error);
                }
            };
            workers.push(handle);
        }

        let accept_sender = sender.clone();
        let flag = shutdown.clone();
        let accept_handle = match thread::Builder::new()
            .name("netstudio-http".to_string())
            .spawn(move || accept_loop(listener, accept_sender, flag))
        {
            Ok(handle) => handle,
            Err(error) => {
                // Do not detach the worker pool if the acceptor could not
                // start: set the flag, wake the workers and join them.
                shutdown.store(true, Ordering::SeqCst);
                drop(sender);
                for worker in workers {
                    let _ = worker.join();
                }
                return Err(error);
            }
        };
        Ok(Self {
            addr: local,
            shutdown,
            accept_handle: Some(accept_handle),
            workers,
            sender: Some(sender),
        })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn stop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        if let Some(handle) = self.accept_handle.take() {
            let _ = handle.join();
        }
        // Dropping the last sender wakes idle workers; join everyone so no
        // connection thread outlives the daemon.
        self.sender.take();
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop();
    }
}

fn accept_loop(listener: TcpListener, sender: SyncSender<TcpStream>, shutdown: Arc<AtomicBool>) {
    while !shutdown.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _peer)) => {
                // Accepted sockets can inherit non-blocking mode from the
                // listener on some platforms; workers need blocking reads
                // with explicit timeouts.
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(REQUEST_TIMEOUT));
                let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
                match sender.try_send(stream) {
                    Ok(()) => {}
                    Err(TrySendError::Full(mut stream)) => {
                        let response = Response::text(
                            503,
                            "Service Unavailable",
                            "server is busy\n".to_string(),
                        );
                        write_response(&mut stream, &response, false);
                    }
                    Err(TrySendError::Disconnected(_)) => break,
                }
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(25));
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(_) => thread::sleep(Duration::from_millis(50)),
        }
    }
}

fn worker_loop(
    receiver: Arc<Mutex<mpsc::Receiver<TcpStream>>>,
    state: Arc<State>,
    shutdown: Arc<AtomicBool>,
) {
    loop {
        if shutdown.load(Ordering::Relaxed) {
            break;
        }
        let job = {
            let receiver = receiver
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            receiver.recv_timeout(Duration::from_millis(200))
        };
        match job {
            Ok(stream) => handle_connection(stream, &state),
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReadError {
    Incomplete,
    TooLarge,
    Timeout,
}

fn handle_connection(mut stream: TcpStream, state: &State) {
    let request = match read_request(&mut stream) {
        Ok(request) => request,
        Err(error) => {
            let response = match error {
                ReadError::TooLarge => Response::text(
                    413,
                    "Payload Too Large",
                    "request header exceeds 8192 bytes\n".to_string(),
                ),
                ReadError::Timeout => Response::text(
                    408,
                    "Request Timeout",
                    "request was not completed in time\n".to_string(),
                ),
                ReadError::Incomplete => Response::text(
                    400,
                    "Bad Request",
                    "malformed or incomplete HTTP request\n".to_string(),
                ),
            };
            write_response(&mut stream, &response, false);
            return;
        }
    };

    let line = request.lines().next().unwrap_or("");
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("");
    let version = parts.next().unwrap_or("");
    if method.is_empty()
        || target.is_empty()
        || !target.starts_with('/')
        || !version.starts_with("HTTP/1.")
        || parts.next().is_some()
    {
        let response = Response::text(
            400,
            "Bad Request",
            "malformed or incomplete HTTP request\n".to_string(),
        );
        write_response(&mut stream, &response, false);
        return;
    }

    let path = target.split("?").next().unwrap_or("");
    let path = path.split("#").next().unwrap_or("");
    let head_only = method.eq_ignore_ascii_case("HEAD");
    let response = if method.eq_ignore_ascii_case("GET") || head_only {
        route(path, state)
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

fn read_request(stream: &mut TcpStream) -> Result<String, ReadError> {
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let mut data = Vec::with_capacity(1_024);
    let mut chunk = [0u8; 1_024];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ReadError::Timeout);
        }
        let _ = stream.set_read_timeout(Some(remaining));
        match stream.read(&mut chunk) {
            Ok(0) => return Err(ReadError::Incomplete),
            Ok(read) => {
                data.extend_from_slice(&chunk[..read]);
                if data.windows(4).any(|window| window == b"\r\n\r\n") {
                    break;
                }
                if data.len() > MAX_HEADER_BYTES {
                    return Err(ReadError::TooLarge);
                }
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(error)
                if error.kind() == ErrorKind::WouldBlock || error.kind() == ErrorKind::TimedOut =>
            {
                return Err(ReadError::Timeout);
            }
            Err(_) => return Err(ReadError::Incomplete),
        }
    }
    if data.len() > MAX_HEADER_BYTES {
        return Err(ReadError::TooLarge);
    }
    String::from_utf8(data).map_err(|_| ReadError::Incomplete)
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
    fn status_exposes_failure_reason_and_fallback() {
        let state = State::new(1);
        let mut tracker = TargetMetricTracker::new(
            7,
            "Broken".to_string(),
            "broken.invalid".to_string(),
            443,
            "HTTPS".to_string(),
        );
        tracker.record_probe(crate::stats::ProbeSample {
            success: false,
            rtt_ms: -1.0,
            http_status: None,
            cert_days_left: None,
            error_kind: Some(crate::stats::ProbeErrorKind::Dns),
            error: Some("DNS resolution failed: no such host".to_string()),
            tcp_fallback: true,
        });
        state.update(vec![tracker.snapshot()]);
        let server = start(state);
        let status = request(&server, "GET", "/api/v1/status");
        let json: serde_json::Value = serde_json::from_str(body(&status)).expect("json");
        assert_eq!(
            json["targets"][0]["last_error"],
            "DNS resolution failed: no such host"
        );
        assert_eq!(json["targets"][0]["last_error_kind"], "dns");
        assert_eq!(json["targets"][0]["tcp_fallback"], true);
    }

    #[test]
    fn malformed_and_oversized_requests_get_400_and_413() {
        let server = start(State::new(1));
        let malformed = raw_request(&server, b"not-a-request\r\n\r\n");
        assert!(malformed.starts_with("HTTP/1.1 400"), "{malformed}");
        let incomplete = raw_request(&server, b"GET / HTTP/1.1\r\nX: y\r\n");
        assert!(incomplete.starts_with("HTTP/1.1 400"), "{incomplete}");
        let oversized = format!(
            "GET / HTTP/1.1\r\nX-Pad: {}\r\n\r\n",
            "a".repeat(MAX_HEADER_BYTES)
        );
        let too_large = raw_request(&server, oversized.as_bytes());
        assert!(too_large.starts_with("HTTP/1.1 413"), "{too_large}");
    }

    fn raw_request(server: &Server, bytes: &[u8]) -> String {
        let mut stream = TcpStream::connect(server.addr()).expect("connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        let _ = stream.write_all(bytes);
        let _ = stream.shutdown(std::net::Shutdown::Write);
        let mut response = String::new();
        let _ = stream.read_to_string(&mut response);
        response
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
