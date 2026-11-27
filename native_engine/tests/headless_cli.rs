//! End-to-end tests for the standalone headless binary.

use std::fs;
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_netstudio-headless")
}

fn temp_dir() -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "netstudio-headless-it-{}-{nanos}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).expect("temp dir");
    dir
}

fn write_config(dir: &std::path::Path, target: Value) -> PathBuf {
    let path = dir.join("targets.json");
    let config =
        serde_json::json!({ "app": "velocenet-studio", "version": 1, "targets": [target] });
    fs::write(&path, serde_json::to_string_pretty(&config).expect("json")).expect("write config");
    path
}

fn run(args: &[&std::ffi::OsStr]) -> std::process::Output {
    Command::new(binary())
        .args(args)
        .output()
        .expect("run headless binary")
}

fn parse_snapshot(stdout: &[u8]) -> Value {
    let text = String::from_utf8_lossy(stdout);
    serde_json::from_str(&text).expect("snapshot json")
}

#[test]
fn once_probes_an_open_port_and_writes_the_snapshot_file() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    let port = listener.local_addr().expect("addr").port();
    let handle = thread::spawn(move || {
        let _ = listener.accept();
    });

    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({
            "id": 1,
            "name": "local",
            "host": "127.0.0.1",
            "port": port,
            "protocol": "TCP",
            "interval_ms": 500,
            "timeout_ms": 2_000
        }),
    );
    let output_path = dir.join("status.json");
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--once".as_ref(),
        "--output".as_ref(),
        output_path.as_os_str(),
        "--log-level=error".as_ref(),
    ]);
    let _ = handle.join();

    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let snapshot = parse_snapshot(&output.stdout);
    assert_eq!(snapshot["type"], "snapshot");
    assert_eq!(snapshot["summary"]["targets"], 1);
    assert_eq!(snapshot["summary"]["down"], 0);
    assert_eq!(snapshot["targets"][0]["sent_count"], 1);
    assert_eq!(snapshot["targets"][0]["received_count"], 1);
    assert!(
        snapshot["targets"][0]["last_checked_epoch_ms"]
            .as_u64()
            .unwrap()
            > 0
    );
    assert!(
        snapshot["targets"][0]["last_sample_age_ms"]
            .as_u64()
            .unwrap()
            < 5_000
    );
    assert_eq!(snapshot["summary"]["stale"], 0);

    let on_disk: Value =
        serde_json::from_str(&fs::read_to_string(&output_path).expect("read output"))
            .expect("json");
    assert_eq!(on_disk["schema"], 1);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn once_text_format_is_human_readable() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    let port = listener.local_addr().expect("addr").port();
    let handle = thread::spawn(move || {
        let _ = listener.accept();
    });

    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({
            "name": "local text",
            "host": "127.0.0.1",
            "port": port,
            "protocol": "TCP",
            "timeout_ms": 2_000
        }),
    );
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--once".as_ref(),
        "--format=text".as_ref(),
        "--no-color".as_ref(),
        "--log-level=error".as_ref(),
    ]);
    let _ = handle.join();

    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("STATUS"));
    assert!(text.contains("ONLINE"));
    assert!(text.contains("local text"));
    assert!(text.contains("1/1"));
    assert!(!text.contains("\"schema\""));
    assert!(!text.contains("\x1b["));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn once_exits_three_when_a_target_is_down() {
    let port = {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        listener.local_addr().expect("addr").port()
    };
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({
            "id": 2,
            "host": "127.0.0.1",
            "port": port,
            "protocol": "TCP",
            "timeout_ms": 300
        }),
    );
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--once".as_ref(),
        "--quiet".as_ref(),
        "--log-level=error".as_ref(),
    ]);
    assert_eq!(
        output.status.code(),
        Some(3),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let snapshot = parse_snapshot(&output.stdout);
    assert_eq!(snapshot["summary"]["down"], 1);
    assert_eq!(snapshot["targets"][0]["last_rtt_ms"], -1.0);
    let kind = snapshot["targets"][0]["last_error_kind"]
        .as_str()
        .unwrap_or_default();
    assert!(matches!(kind, "refused" | "timeout"), "kind: {kind}");
    assert!(!snapshot["targets"][0]["last_error"]
        .as_str()
        .unwrap_or_default()
        .is_empty());
    assert_eq!(snapshot["targets"][0]["tcp_fallback"], false);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn once_text_shows_why_a_target_is_down() {
    let port = {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        listener.local_addr().expect("addr").port()
    };
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({
            "name": "closed port",
            "host": "127.0.0.1",
            "port": port,
            "protocol": "TCP",
            "timeout_ms": 300
        }),
    );
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--once".as_ref(),
        "--format=text".as_ref(),
        "--no-color".as_ref(),
        "--log-level=error".as_ref(),
    ]);
    assert_eq!(
        output.status.code(),
        Some(3),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("DETAIL"));
    assert!(
        text.contains("refused:") || text.contains("timeout:"),
        "{text}"
    );
    assert!(text.contains("closed port"));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn check_validates_without_probing() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--check".as_ref(),
        "--format=text".as_ref(),
    ]);
    assert_eq!(output.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&output.stdout).contains("config OK"));

    // Without --format a piped run follows the same rule as --once: JSON.
    let piped = run(&["--config".as_ref(), config.as_os_str(), "--check".as_ref()]);
    assert_eq!(piped.status.code(), Some(0));
    let report: Value = serde_json::from_slice(&piped.stdout).expect("check json");
    assert_eq!(report["type"], "check");
    assert_eq!(report["ok"], true);

    let broken = dir.join("broken.json");
    fs::write(&broken, "{").expect("write broken");
    let output = run(&["--config".as_ref(), broken.as_os_str(), "--check".as_ref()]);
    assert_eq!(output.status.code(), Some(2));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn help_and_version_do_not_require_a_config() {
    let help = run(&["--help".as_ref()]);
    assert_eq!(help.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&help.stdout).contains("Usage:"));

    let version = run(&["--version".as_ref()]);
    assert_eq!(version.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&version.stdout).contains(env!("CARGO_PKG_VERSION")));

    let missing = run(&[]);
    assert_eq!(missing.status.code(), Some(2));
}

#[test]
fn check_rejects_an_unreadable_token_file() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--check".as_ref(),
        "--format=json".as_ref(),
        "--listen".as_ref(),
        "127.0.0.1:0".as_ref(),
        "--http-token-file".as_ref(),
        dir.join("missing.token").as_os_str(),
    ]);
    assert_eq!(output.status.code(), Some(2));
    let report: Value = serde_json::from_slice(&output.stdout).expect("check json");
    let auth = report["checks"]
        .as_array()
        .expect("checks")
        .iter()
        .find(|check| check["name"] == "auth")
        .expect("auth check");
    assert_eq!(auth["ok"], false);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn daemon_requires_the_bearer_token_when_one_is_configured() {
    use std::net::TcpStream;
    use std::time::{Duration, Instant};

    let http_port = {
        let probe = TcpListener::bind("127.0.0.1:0").expect("bind http");
        probe.local_addr().expect("addr").port()
    };
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({
            "id": 1,
            "name": "closed",
            "host": "127.0.0.1",
            "port": 9,
            "protocol": "TCP",
            "interval_ms": 500,
            "timeout_ms": 500
        }),
    );
    let token_path = dir.join("token");
    fs::write(&token_path, "s3cret\n").expect("write token");
    let listen = format!("127.0.0.1:{http_port}");
    let mut child = Command::new(binary())
        .args([
            "--config".as_ref(),
            config.as_os_str(),
            "--listen".as_ref(),
            std::ffi::OsStr::new(&listen),
            "--http-token-file".as_ref(),
            token_path.as_os_str(),
            "--quiet".as_ref(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn daemon");

    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if TcpStream::connect(("127.0.0.1", http_port)).is_ok() {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }

    let anonymous = http_get(http_port, "/metrics").expect("metrics");
    assert!(anonymous.starts_with("HTTP/1.1 401"), "{anonymous}");

    let authorized =
        http_get_with(http_port, "/metrics", "Authorization: Bearer s3cret\r\n").expect("metrics");
    assert!(authorized.starts_with("HTTP/1.1 200"), "{authorized}");
    assert!(authorized.contains("netstudio_build_info"), "{authorized}");

    // Liveness stays open so a probe that cannot send headers still works.
    assert!(http_get(http_port, "/healthz")
        .expect("healthz")
        .starts_with("HTTP/1.1 200"));

    let _ = child.kill();
    let _ = child.wait();
    let _ = fs::remove_dir_all(&dir);
}

fn http_get(port: u16, path: &str) -> std::io::Result<String> {
    http_get_with(port, path, "")
}

fn http_get_with(port: u16, path: &str, extra_header: &str) -> std::io::Result<String> {
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use std::time::Duration;

    let mut stream = TcpStream::connect(("127.0.0.1", port))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.write_all(
        format!(
            "GET {path} HTTP/1.1\r\nHost: localhost\r\n{extra_header}Connection: close\r\n\r\n"
        )
        .as_bytes(),
    )?;
    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    Ok(response)
}

fn response_body(response: &str) -> &str {
    response
        .split_once("\r\n\r\n")
        .map(|(_, body)| body)
        .unwrap_or("")
}

#[test]
fn probe_interval_overrides_each_targets_own_cadence() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({
            "host": "127.0.0.1",
            "port": 9,
            "protocol": "TCP",
            "interval_ms": 60_000,
            "timeout_ms": 1_000
        }),
    );
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--once".as_ref(),
        "--probe-interval".as_ref(),
        "2".as_ref(),
        "--log-level=error".as_ref(),
    ]);
    let snapshot = parse_snapshot(&output.stdout);
    // 2 x 2000 ms + 1000 ms timeout: the override replaced the 60 s config.
    assert_eq!(snapshot["targets"][0]["stale_after_ms"], 5_000);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn check_reports_every_preflight_channel() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let output_path = dir.join("status.json");
    let pid_path = dir.join("headless.pid");
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--check".as_ref(),
        "--format=json".as_ref(),
        "--output".as_ref(),
        output_path.as_os_str(),
        "--pid-file".as_ref(),
        pid_path.as_os_str(),
    ]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).expect("check json");
    assert_eq!(report["type"], "check");
    assert_eq!(report["ok"], true);
    assert_eq!(report["schema"], 1);
    let names: Vec<&str> = report["checks"]
        .as_array()
        .expect("checks")
        .iter()
        .map(|check| check["name"].as_str().expect("name"))
        .collect();
    assert_eq!(names, ["config", "output", "pid-file"]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn check_fails_when_a_preflight_path_is_unusable() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let missing = dir.join("no-such-dir").join("status.json");
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--check".as_ref(),
        "--format=json".as_ref(),
        "--output".as_ref(),
        missing.as_os_str(),
    ]);
    // Exit 2, and the report says which channel is broken: this used to pass
    // --check and then run a daemon that could never write a snapshot.
    assert_eq!(output.status.code(), Some(2));
    let report: Value = serde_json::from_slice(&output.stdout).expect("check json");
    assert_eq!(report["ok"], false);
    let failed: Vec<&str> = report["checks"]
        .as_array()
        .expect("checks")
        .iter()
        .filter(|check| check["ok"] == false)
        .map(|check| check["name"].as_str().expect("name"))
        .collect();
    assert_eq!(failed, ["output"]);
    let _ = fs::remove_dir_all(&dir);
}

#[cfg(windows)]
#[test]
fn windows_service_mode_refuses_a_console_start() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 9, "protocol": "TCP" }),
    );
    let log_path = dir.join("service.log");
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--windows-service".as_ref(),
        "--log-file".as_ref(),
        log_path.as_os_str(),
    ]);
    // 1063: not started by SCM. Say so instead of hanging or probing nothing.
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("cannot run as a Windows service"),
        "{stderr}"
    );
    assert!(
        stderr.contains("sc.exe start netstudio-headless"),
        "{stderr}"
    );
    let file = fs::read_to_string(&log_path).expect("log file");
    assert!(
        file.contains("cannot run as a Windows service"),
        "the log file must exist before the dispatcher runs: {file}"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn log_file_receives_every_line_in_plain_text() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "id": 1, "host": "127.0.0.1", "port": 9, "protocol": "TCP", "interval_ms": 200, "timeout_ms": 300 }),
    );
    let log_path = dir.join("headless.log");
    let args = [
        "--config".as_ref(),
        config.as_os_str(),
        "--once".as_ref(),
        "--log-file".as_ref(),
        log_path.as_os_str(),
    ];
    let output = run(&args);
    // Port 9 is closed, so --once reports a down target with exit 3; the
    // logs still have to reach the file.
    assert_eq!(output.status.code(), Some(3), "{output:?}");
    let first = fs::read_to_string(&log_path).expect("log file");
    assert!(first.contains("finished in"), "{first}");
    assert!(
        !first.contains('\u{1b}'),
        "log file must not contain ANSI escapes: {first}"
    );

    // A second run appends: rotation must never truncate on open.
    let again = run(&args);
    assert_eq!(again.status.code(), Some(3), "{again:?}");
    let second = fs::read_to_string(&log_path).expect("log file");
    assert_eq!(
        second.matches("finished in").count(),
        2,
        "the file was truncated: {second}"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn check_rejects_an_unwritable_log_directory() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let missing = dir.join("no-such-dir").join("headless.log");
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--check".as_ref(),
        "--format=json".as_ref(),
        "--log-file".as_ref(),
        missing.as_os_str(),
    ]);
    assert_eq!(output.status.code(), Some(2));
    let report: Value = serde_json::from_slice(&output.stdout).expect("check json");
    let failed: Vec<&str> = report["checks"]
        .as_array()
        .expect("checks")
        .iter()
        .filter(|check| check["ok"] == false)
        .map(|check| check["name"].as_str().expect("name"))
        .collect();
    assert_eq!(failed, ["log-file"]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn check_fails_when_the_listen_address_is_taken() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    let address = format!("127.0.0.1:{}", listener.local_addr().expect("addr").port());
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--check".as_ref(),
        "--format=json".as_ref(),
        "--listen".as_ref(),
        std::ffi::OsStr::new(&address),
    ]);
    assert_eq!(output.status.code(), Some(2));
    let report: Value = serde_json::from_slice(&output.stdout).expect("check json");
    let failed: Vec<&str> = report["checks"]
        .as_array()
        .expect("checks")
        .iter()
        .filter(|check| check["ok"] == false)
        .map(|check| check["name"].as_str().expect("name"))
        .collect();
    assert_eq!(failed, ["listen"]);
    drop(listener);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn once_rejects_daemon_only_flags() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    for flag in ["--listen", "--pid-file"] {
        let output = run(&[
            "--config".as_ref(),
            config.as_os_str(),
            "--once".as_ref(),
            flag.as_ref(),
            "127.0.0.1:0".as_ref(),
        ]);
        assert_eq!(output.status.code(), Some(2), "{flag} must be rejected");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(flag), "stderr: {stderr}");
        assert!(output.stdout.is_empty(), "{flag} must not probe");
    }
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn once_fails_before_probing_when_the_output_path_is_unusable() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let missing = dir.join("no-such-dir").join("status.json");
    let output = run(&[
        "--config".as_ref(),
        config.as_os_str(),
        "--once".as_ref(),
        "--output".as_ref(),
        missing.as_os_str(),
        "--log-level=error".as_ref(),
    ]);
    assert_eq!(output.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("does not exist"),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    // Nothing was probed or printed: the failure happens before the loop.
    assert!(output.stdout.is_empty());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn daemon_exits_instead_of_logging_a_permanent_output_failure() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let missing = dir.join("no-such-dir").join("status.json");
    let mut child = Command::new(binary())
        .args([
            "--config".as_ref(),
            config.as_os_str(),
            "--output".as_ref(),
            missing.as_os_str(),
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn daemon");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let status = loop {
        if let Some(status) = child.try_wait().expect("status") {
            break status;
        }
        if std::time::Instant::now() > deadline {
            let _ = child.kill();
            panic!("daemon kept running with an unusable --output");
        }
        thread::sleep(std::time::Duration::from_millis(50));
    };
    let output = child.wait_with_output().expect("output");
    assert_eq!(status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("does not exist"));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn daemon_serves_health_readiness_and_metrics() {
    use std::net::TcpStream;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    // Loopback target that answers every TCP probe.
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind target");
    let target_port = listener.local_addr().expect("addr").port();
    let stop = Arc::new(AtomicBool::new(false));
    let stop_accept = Arc::clone(&stop);
    let accept = thread::spawn(move || {
        listener.set_nonblocking(true).expect("nonblocking");
        while !stop_accept.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok(_) => {}
                Err(_) => thread::sleep(Duration::from_millis(10)),
            }
        }
    });

    // Reserve an HTTP port, then hand it to the daemon (small, accepted race).
    let http_port = {
        let probe = TcpListener::bind("127.0.0.1:0").expect("bind http");
        probe.local_addr().expect("addr").port()
    };

    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({
            "id": 1,
            "name": "local",
            "host": "127.0.0.1",
            "port": target_port,
            "protocol": "TCP",
            "interval_ms": 200,
            "timeout_ms": 1_000
        }),
    );
    let pid_path = dir.join("headless.pid");
    let listen = format!("127.0.0.1:{http_port}");
    let mut child = Command::new(binary())
        .args([
            "--config".as_ref(),
            config.as_os_str(),
            "--listen".as_ref(),
            std::ffi::OsStr::new(&listen),
            "--pid-file".as_ref(),
            pid_path.as_os_str(),
            "--interval".as_ref(),
            "1".as_ref(),
            "--quiet".as_ref(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn daemon");

    let deadline = Instant::now() + Duration::from_secs(15);
    let mut up = false;
    while Instant::now() < deadline {
        if TcpStream::connect(("127.0.0.1", http_port)).is_ok() {
            up = true;
            break;
        }
        if child.try_wait().expect("status").is_some() {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(up, "daemon never listened on {listen}");

    // The pid file is claimed before the loop starts.
    let pid_contents = fs::read_to_string(&pid_path).expect("pid file");
    assert_eq!(pid_contents.trim(), child.id().to_string());

    let health = http_get(http_port, "/healthz").expect("healthz");
    assert!(health.starts_with("HTTP/1.1 200"), "{health}");

    // Strict readiness: 503 until the target has actually been sampled.
    let mut ready = String::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        ready = http_get(http_port, "/readyz").expect("readyz");
        if ready.starts_with("HTTP/1.1 200") {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(ready.starts_with("HTTP/1.1 200"), "readyz: {ready}");

    let metrics = http_get(http_port, "/metrics").expect("metrics");
    assert!(
        metrics.contains("netstudio_target_up{id=\"1\""),
        "metrics: {metrics}"
    );
    assert!(metrics.contains("netstudio_target_muted{id=\"1\""));

    let status = http_get(http_port, "/api/v1/status").expect("status");
    let json: Value = serde_json::from_str(response_body(&status)).expect("status json");
    assert_eq!(json["schema"], 1);
    assert!(json["targets"][0]["sent_count"].as_u64().unwrap_or(0) >= 1);

    let _ = child.kill();
    let _ = child.wait();
    stop.store(true, Ordering::Relaxed);
    let _ = accept.join();
    if let Some(mut stderr) = child.stderr.take() {
        let mut log = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut log);
        assert!(
            !log.contains("ERROR output directory"),
            "unexpected failure log: {log}"
        );
    }
    let _ = fs::remove_dir_all(&dir);
}
#[cfg(unix)]
#[test]
fn daemon_reloads_targets_on_sighup_and_survives_a_broken_file() {
    use std::time::{Duration, Instant};

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind target");
    let target_port = listener.local_addr().expect("addr").port();
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stop_worker = std::sync::Arc::clone(&stop);
    let accept = thread::spawn(move || {
        listener.set_nonblocking(true).expect("nonblocking");
        while !stop_worker.load(std::sync::atomic::Ordering::Relaxed) {
            match listener.accept() {
                Ok(_) => {}
                Err(_) => thread::sleep(Duration::from_millis(10)),
            }
        }
    });

    let dir = temp_dir();
    let config = dir.join("targets.json");
    let write = |targets: Value| {
        let file = serde_json::json!({
            "app": "velocenet-studio",
            "version": 1,
            "targets": targets
        });
        fs::write(&config, serde_json::to_string_pretty(&file).expect("json")).expect("write");
    };
    let target = |id: u32, name: &str| {
        serde_json::json!({
            "id": id,
            "name": name,
            "host": "127.0.0.1",
            "port": target_port,
            "protocol": "TCP",
            "interval_ms": 200,
            "timeout_ms": 1_000
        })
    };
    write(serde_json::json!([target(1, "one")]));

    let snapshot_path = dir.join("status.json");
    let mut child = Command::new(binary())
        .args([
            "--config".as_ref(),
            config.as_os_str(),
            "--output".as_ref(),
            snapshot_path.as_os_str(),
            "--interval".as_ref(),
            "1".as_ref(),
            "--quiet".as_ref(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn daemon");

    let read_snapshot = || {
        fs::read_to_string(&snapshot_path)
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
    };
    let wait_for = |count: usize, deadline: Instant| {
        let mut snapshot = None;
        while Instant::now() < deadline {
            snapshot = read_snapshot();
            if let Some(json) = &snapshot {
                if json["targets"].as_array().map(Vec::len) == Some(count) {
                    return Some(json.clone());
                }
            }
            thread::sleep(Duration::from_millis(50));
        }
        snapshot
    };

    let first = wait_for(1, Instant::now() + Duration::from_secs(15)).expect("first snapshot");
    assert_eq!(first["targets"][0]["name"], "one");

    write(serde_json::json!([target(1, "one"), target(2, "two")]));
    let status = Command::new("kill")
        .args(["-HUP", &child.id().to_string()])
        .status()
        .expect("send SIGHUP");
    assert!(status.success(), "kill -HUP failed");

    let reloaded =
        wait_for(2, Instant::now() + Duration::from_secs(15)).expect("reloaded snapshot");
    assert_eq!(
        reloaded["targets"]
            .as_array()
            .expect("targets")
            .iter()
            .map(|target| target["name"].as_str().unwrap_or(""))
            .collect::<Vec<_>>(),
        vec!["one", "two"]
    );
    // Unchanged target 1 kept its history instead of restarting at zero.
    assert!(
        reloaded["targets"][0]["sent_count"].as_u64().unwrap_or(0) >= 1,
        "{reloaded}"
    );

    // A broken file must not take the daemon down or drop the live config.
    fs::write(&config, "{ not json").expect("write broken config");
    let status = Command::new("kill")
        .args(["-HUP", &child.id().to_string()])
        .status()
        .expect("send second SIGHUP");
    assert!(status.success());
    thread::sleep(Duration::from_millis(1_500));
    assert!(child.try_wait().expect("status").is_none(), "daemon exited");
    let survived = read_snapshot().expect("snapshot after failed reload");
    assert_eq!(survived["targets"].as_array().map(Vec::len), Some(2));

    let _ = child.kill();
    let _ = child.wait();
    let mut log = String::new();
    if let Some(mut stderr) = child.stderr.take() {
        let _ = std::io::Read::read_to_string(&mut stderr, &mut log);
    }
    assert!(log.contains("reloaded 2 target(s)"), "{log}");
    assert!(log.contains("reload failed"), "{log}");

    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let _ = accept.join();
    let _ = fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn daemon_rotates_the_http_token_on_sighup_and_keeps_it_when_the_file_is_bad() {
    use std::net::TcpStream;
    use std::time::{Duration, Instant};

    let http_port = {
        let probe = TcpListener::bind("127.0.0.1:0").expect("bind http");
        probe.local_addr().expect("addr").port()
    };
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({
            "id": 1,
            "name": "closed",
            "host": "127.0.0.1",
            "port": 9,
            "protocol": "TCP",
            "interval_ms": 500,
            "timeout_ms": 500
        }),
    );
    let token_path = dir.join("token");
    fs::write(&token_path, "one\n").expect("write token");
    let listen = format!("127.0.0.1:{http_port}");
    let mut child = Command::new(binary())
        .args([
            "--config".as_ref(),
            config.as_os_str(),
            "--listen".as_ref(),
            std::ffi::OsStr::new(&listen),
            "--http-token-file".as_ref(),
            token_path.as_os_str(),
            "--quiet".as_ref(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn daemon");

    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if TcpStream::connect(("127.0.0.1", http_port)).is_ok() {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    let with = |token: &str| {
        http_get_with(
            http_port,
            "/metrics",
            &format!("Authorization: Bearer {token}\r\n"),
        )
        .expect("metrics")
    };
    assert!(with("one").starts_with("HTTP/1.1 200"));

    // Rotate: the new secret works and the old one is refused, with no restart.
    fs::write(&token_path, "two\n").expect("rotate token");
    let status = Command::new("kill")
        .args(["-HUP", &child.id().to_string()])
        .status()
        .expect("send SIGHUP");
    assert!(status.success(), "kill -HUP failed");
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline && !with("two").starts_with("HTTP/1.1 200") {
        thread::sleep(Duration::from_millis(50));
    }
    assert!(
        with("two").starts_with("HTTP/1.1 200"),
        "new token rejected"
    );
    assert!(
        with("one").starts_with("HTTP/1.1 401"),
        "old token still valid"
    );

    // An empty file must not silently drop authentication.
    fs::write(&token_path, "").expect("blank token");
    let status = Command::new("kill")
        .args(["-HUP", &child.id().to_string()])
        .status()
        .expect("send second SIGHUP");
    assert!(status.success());
    thread::sleep(Duration::from_millis(1_000));
    assert!(with("two").starts_with("HTTP/1.1 200"), "token was dropped");
    assert!(http_get(http_port, "/metrics")
        .expect("anonymous")
        .starts_with("HTTP/1.1 401"));

    let _ = child.kill();
    let _ = child.wait();
    let mut log = String::new();
    if let Some(mut stderr) = child.stderr.take() {
        let _ = std::io::Read::read_to_string(&mut stderr, &mut log);
    }
    assert!(log.contains("HTTP bearer token rotated"), "{log}");
    assert!(log.contains("keeping the previous HTTP token"), "{log}");

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn daemon_reloads_a_changed_config_file_when_watching_is_enabled() {
    use std::time::{Duration, Instant};

    let dir = temp_dir();
    let config = dir.join("targets.json");
    let write = |targets: Value| {
        let file = serde_json::json!({
            "app": "velocenet-studio",
            "version": 1,
            "targets": targets
        });
        fs::write(&config, serde_json::to_string_pretty(&file).expect("json")).expect("write");
    };
    let target = |id: u32, name: &str| {
        serde_json::json!({
            "id": id,
            "name": name,
            "host": "127.0.0.1",
            "port": 9,
            "protocol": "TCP",
            "interval_ms": 200,
            "timeout_ms": 500
        })
    };
    write(serde_json::json!([target(1, "one")]));

    let snapshot_path = dir.join("status.json");
    let mut child = Command::new(binary())
        .args([
            "--config".as_ref(),
            config.as_os_str(),
            "--output".as_ref(),
            snapshot_path.as_os_str(),
            "--watch-config".as_ref(),
            "1".as_ref(),
            "--interval".as_ref(),
            "1".as_ref(),
            "--quiet".as_ref(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn daemon");

    let wait_for = |count: usize| {
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if let Ok(text) = fs::read_to_string(&snapshot_path) {
                if let Ok(json) = serde_json::from_str::<Value>(&text) {
                    if json["targets"].as_array().map(Vec::len) == Some(count) {
                        return json;
                    }
                }
            }
            thread::sleep(Duration::from_millis(50));
        }
        panic!("no snapshot with {count} target(s) before the deadline");
    };
    wait_for(1);

    write(serde_json::json!([target(1, "one"), target(2, "two")]));
    let reloaded = wait_for(2);
    assert_eq!(reloaded["targets"][1]["name"], "two");
    // The unchanged target kept its history across the polled reload.
    assert!(reloaded["targets"][0]["sent_count"].as_u64().unwrap_or(0) >= 1);

    let _ = child.kill();
    let _ = child.wait();
    let mut log = String::new();
    if let Some(mut stderr) = child.stderr.take() {
        let _ = std::io::Read::read_to_string(&mut stderr, &mut log);
    }
    assert!(log.contains("for changes every 1s"), "{log}");
    assert!(log.contains("changed; reloading"), "{log}");
    assert!(log.contains("reloaded 2 target(s)"), "{log}");

    let _ = fs::remove_dir_all(&dir);
}

#[cfg(unix)]
fn _unix_only_marker() {}
