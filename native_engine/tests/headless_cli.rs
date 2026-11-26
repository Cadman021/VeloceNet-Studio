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

    let on_disk: Value =
        serde_json::from_str(&fs::read_to_string(&output_path).expect("read output"))
            .expect("json");
    assert_eq!(on_disk["schema"], 1);
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
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn check_validates_without_probing() {
    let dir = temp_dir();
    let config = write_config(
        &dir,
        serde_json::json!({ "host": "127.0.0.1", "port": 80, "protocol": "TCP" }),
    );
    let output = run(&["--config".as_ref(), config.as_os_str(), "--check".as_ref()]);
    assert_eq!(output.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&output.stdout).contains("config OK"));

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
