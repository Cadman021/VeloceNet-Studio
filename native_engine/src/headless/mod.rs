//! Headless mode: run the monitoring engine without the Flutter UI.
//!
//! The binary in `src/bin/netstudio-headless.rs` only calls [`main_entry`];
//! everything else is regular library code so the parsers and renderers can
//! be tested without spawning a daemon.

mod cli;
mod config;
mod http;
mod log;
mod metrics;
mod signal;
mod term;
mod text;

use std::io::{IsTerminal, Write};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::sleep;
use std::time::{Duration, Instant};

use parking_lot::RwLock;

use crate::engine::Engine;
use crate::stats::{self, TargetStats, TargetStatus};

pub use log::Level;

pub const NAME: &str = "netstudio-headless";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

const EXIT_OK: i32 = 0;
const EXIT_FAILURE: i32 = 1;
const EXIT_CONFIG: i32 = 2;
const EXIT_TARGETS_DOWN: i32 = 3;

#[derive(Debug, serde::Serialize)]
pub struct Summary {
    pub targets: usize,
    pub pending: usize,
    pub online: usize,
    pub degraded: usize,
    pub offline: usize,
    /// Targets whose most recent probe failed (pending targets excluded).
    pub down: usize,
}

#[derive(Debug, serde::Serialize)]
pub struct Snapshot {
    pub schema: u32,
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub time: String,
    pub epoch_ms: u64,
    pub version: &'static str,
    pub summary: Summary,
    pub targets: Vec<TargetStats>,
}

impl Snapshot {
    pub fn new(targets: Vec<TargetStats>) -> Self {
        let epoch_ms = log::now_epoch_ms();
        let mut summary = Summary {
            targets: targets.len(),
            pending: 0,
            online: 0,
            degraded: 0,
            offline: 0,
            down: 0,
        };
        for target in &targets {
            match target.status {
                TargetStatus::Pending => summary.pending += 1,
                TargetStatus::Online => summary.online += 1,
                TargetStatus::Degraded => summary.degraded += 1,
                TargetStatus::Offline => summary.offline += 1,
            }
            if target.sent_count > 0 && target.last_rtt_ms < 0.0 {
                summary.down += 1;
            }
        }
        Self {
            schema: 1,
            kind: "snapshot",
            time: log::rfc3339(epoch_ms),
            epoch_ms,
            version: VERSION,
            summary,
            targets,
        }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string())
    }

    pub fn to_pretty_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }
}

/// State shared by the daemon loop and the HTTP threads.
pub struct State {
    target_count: AtomicUsize,
    stats: RwLock<Vec<TargetStats>>,
}

impl State {
    pub fn new(target_count: usize) -> Arc<Self> {
        Arc::new(Self {
            target_count: AtomicUsize::new(target_count),
            stats: RwLock::new(Vec::new()),
        })
    }

    pub fn update(&self, stats: Vec<TargetStats>) {
        *self.stats.write() = stats;
    }

    pub fn stats(&self) -> Vec<TargetStats> {
        self.stats.read().clone()
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot::new(self.stats())
    }

    pub fn ready(&self) -> bool {
        self.target_count.load(Ordering::Relaxed) > 0
            && self.stats.read().iter().any(|target| target.sent_count > 0)
    }
}

pub fn main_entry() -> i32 {
    // Resolve automatic colouring before parsing so even usage errors are
    // readable; a successful parse applies the explicit flag below.
    term::init(term::ColorMode::Auto);
    let args: Vec<String> = std::env::args().skip(1).collect();
    match cli::parse(&args) {
        Ok(cli) => run(cli),
        Err(error) => {
            let style = term::stderr_style();
            eprintln!("{} {error}", style.red("error:"));
            eprintln!("{}", style.dim(&format!("Run {NAME} --help for usage.")));
            EXIT_CONFIG
        }
    }
}

fn run(cli: cli::Cli) -> i32 {
    term::init(cli.color);
    log::set_level(cli.log_level);
    if cli.help {
        print!("{}", cli::HELP);
        return EXIT_OK;
    }
    if cli.version {
        println!("{NAME} {VERSION}");
        return EXIT_OK;
    }
    let Some(config_path) = cli.config.clone() else {
        log::error("--config <PATH> is required");
        return EXIT_CONFIG;
    };
    let loaded = match config::load(&config_path) {
        Ok(loaded) => loaded,
        Err(error) => {
            log::error(error);
            return EXIT_CONFIG;
        }
    };
    for warning in &loaded.warnings {
        log::warn(warning);
    }
    if loaded.targets.is_empty() {
        log::error(format!(
            "no usable targets in {} (all entries were invalid or disabled)",
            config_path.display()
        ));
        return EXIT_CONFIG;
    }
    if cli.check {
        let style = term::stdout_style();
        println!(
            "{} {} target(s) in {}",
            style.green("config OK:"),
            loaded.targets.len(),
            config_path.display()
        );
        return EXIT_OK;
    }

    stats::set_alert_thresholds(loaded.offline_after, loaded.recover_after);
    let engine = match Engine::new() {
        Ok(engine) => engine,
        Err(error) => {
            log::error(error);
            return EXIT_FAILURE;
        }
    };
    for target in &loaded.targets {
        engine.add_target(target.clone());
    }
    if cli.once {
        run_once(&engine, &cli)
    } else {
        run_daemon(engine, &cli, loaded, &config_path)
    }
}

fn run_once(engine: &Engine, cli: &cli::Cli) -> i32 {
    let started = Instant::now();
    let count = engine.get_metrics_snapshot().len();
    log::info(format!("probing {count} target(s) once"));
    let snapshot = Snapshot::new(engine.probe_once());
    let pretty = snapshot.to_pretty_json();
    let rendered = if uses_text(cli.format) {
        text::render(&snapshot, term::stdout_style())
    } else {
        format!("{pretty}\n")
    };
    if let Err(error) = write_stdout(&rendered) {
        log::warn(format!("could not write the snapshot to stdout: {error}"));
    }
    if let Some(path) = &cli.output {
        if let Err(error) = write_snapshot(path, &pretty) {
            log::error(error);
            return EXIT_FAILURE;
        }
    }
    log::info(format!(
        "finished in {:.2}s: {} target(s), {} down",
        started.elapsed().as_secs_f64(),
        snapshot.summary.targets,
        snapshot.summary.down
    ));
    if snapshot.summary.targets == 0 {
        return EXIT_FAILURE;
    }
    if snapshot.summary.down > 0 {
        EXIT_TARGETS_DOWN
    } else {
        EXIT_OK
    }
}

fn run_daemon(
    engine: Engine,
    cli: &cli::Cli,
    loaded: config::LoadedConfig,
    config_path: &Path,
) -> i32 {
    let state = State::new(loaded.targets.len());
    state.update(engine.get_metrics_snapshot());

    let mut server = match cli.listen {
        Some(address) => match http::Server::spawn(address, state.clone()) {
            Ok(server) => Some(server),
            Err(error) => {
                log::error(format!("cannot listen on {address}: {error}"));
                return EXIT_FAILURE;
            }
        },
        None => None,
    };

    if let Some(path) = &cli.pid_file {
        if let Err(error) = write_pid_file(path) {
            log::error(error);
            if let Some(mut server) = server.take() {
                server.stop();
            }
            return EXIT_FAILURE;
        }
    }
    if let Err(error) = signal::install() {
        log::warn(format!("signal handling unavailable: {error}"));
    }

    log::info(format!(
        "{NAME} {VERSION} starting: {} target(s), config {}",
        loaded.targets.len(),
        config_path.display()
    ));
    if let Some(server) = &server {
        log::info(format!("HTTP listening on http://{}", server.addr()));
    }
    if let Some(path) = &cli.output {
        log::info(format!("snapshot file: {}", path.display()));
    }

    engine.start();
    let mut next_emit = Instant::now();
    let mut stream_open = !cli.quiet;
    while !signal::shutdown_requested() {
        let stats = engine.get_metrics_snapshot();
        state.update(stats.clone());
        if Instant::now() >= next_emit {
            let snapshot = Snapshot::new(stats);
            let rendered = if uses_text(cli.format) {
                text::render(&snapshot, term::stdout_style())
            } else {
                format!("{}\n", snapshot.to_json())
            };
            if stream_open && write_stdout(&rendered).is_err() {
                log::warn("stdout is closed; continuing without streaming snapshots");
                stream_open = false;
            }
            if let Some(path) = &cli.output {
                if let Err(error) = write_snapshot(path, &snapshot.to_pretty_json()) {
                    log::error(error);
                }
            }
            next_emit = Instant::now() + Duration::from_secs(cli.interval_secs);
        }
        sleep(Duration::from_millis(250));
    }

    log::info("shutting down");
    engine.stop();
    if let Some(mut server) = server.take() {
        server.stop();
    }
    if let Some(path) = &cli.pid_file {
        remove_pid_file(path);
    }
    log::info("stopped");
    EXIT_OK
}

fn uses_text(format: cli::OutputFormat) -> bool {
    match format {
        cli::OutputFormat::Auto => std::io::stdout().is_terminal(),
        cli::OutputFormat::Json => false,
        cli::OutputFormat::Text => true,
    }
}

fn write_stdout(text: &str) -> std::io::Result<()> {
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(text.as_bytes())?;
    stdout.flush()
}

fn write_pid_file(path: &Path) -> Result<(), String> {
    if path.exists() {
        log::warn(format!(
            "pid file {} already exists; overwriting",
            path.display()
        ));
    }
    std::fs::write(path, format!("{}\n", std::process::id()))
        .map_err(|error| format!("cannot write pid file {}: {error}", path.display()))
}

fn remove_pid_file(path: &Path) {
    if let Ok(contents) = std::fs::read_to_string(path) {
        if contents.trim() == std::process::id().to_string() {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn write_snapshot(path: &Path, contents: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    if !parent.is_dir() {
        return Err(format!(
            "output directory {} does not exist",
            parent.display()
        ));
    }
    let file_name = path
        .file_name()
        .ok_or_else(|| format!("invalid output path {}", path.display()))?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        file_name.to_string_lossy(),
        std::process::id()
    ));
    std::fs::write(&temporary, contents)
        .map_err(|error| format!("cannot write {}: {error}", temporary.display()))?;
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("cannot replace {}: {error}", path.display()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::TargetMetricTracker;

    fn tracker(id: u32, success: bool) -> TargetMetricTracker {
        let mut tracker = TargetMetricTracker::new(
            id,
            format!("target-{id}"),
            "127.0.0.1".to_string(),
            80,
            "TCP".to_string(),
        );
        tracker.record_sample(success, if success { 2.0 } else { -1.0 }, None, None);
        tracker
    }

    #[test]
    fn snapshot_counts_statuses_and_failures() {
        let mut online = tracker(1, true);
        let mut offline = tracker(2, false);
        let snapshot = Snapshot::new(vec![online.snapshot(), offline.snapshot()]);
        assert_eq!(snapshot.schema, 1);
        assert_eq!(snapshot.kind, "snapshot");
        assert_eq!(snapshot.summary.targets, 2);
        assert_eq!(snapshot.summary.online, 1);
        assert_eq!(snapshot.summary.offline, 1);
        assert_eq!(snapshot.summary.down, 1);
        assert!(snapshot.to_json().contains("\"type\":\"snapshot\""));
    }

    #[test]
    fn snapshot_file_is_replaced_atomically() {
        let directory = std::env::temp_dir().join(format!(
            "netstudio-headless-snapshot-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).expect("temp dir");
        let path = directory.join("status.json");
        write_snapshot(&path, "{\"ok\":true}").expect("write");
        assert_eq!(
            std::fs::read_to_string(&path).expect("read"),
            "{\"ok\":true}"
        );
        let temporary = directory.join(format!(".status.json.{}.tmp", std::process::id()));
        assert!(!temporary.exists());
        let _ = std::fs::remove_dir_all(&directory);
    }
}
