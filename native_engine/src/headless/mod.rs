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

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::sleep;
use std::time::{Duration, Instant};

use parking_lot::{Mutex, RwLock};

use crate::engine::{Engine, TargetConfig};
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
    /// Targets whose latest sample exceeded 2 × interval + timeout.
    pub stale: usize,
    /// Targets muted in the app (probed and reported, never alert-worthy).
    pub muted: usize,
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
    /// Shared, not cloned: the daemon hands the same statistics to the stdout
    /// snapshot, the output file and every HTTP scrape.
    pub targets: Arc<Vec<TargetStats>>,
}

impl Snapshot {
    pub fn new(targets: impl Into<Arc<Vec<TargetStats>>>) -> Self {
        let targets: Arc<Vec<TargetStats>> = targets.into();
        let epoch_ms = log::now_epoch_ms();
        let mut summary = Summary {
            targets: targets.len(),
            pending: 0,
            online: 0,
            degraded: 0,
            offline: 0,
            down: 0,
            stale: 0,
            muted: 0,
        };
        for target in targets.iter() {
            match target.status {
                TargetStatus::Pending => summary.pending += 1,
                TargetStatus::Online => summary.online += 1,
                TargetStatus::Degraded => summary.degraded += 1,
                TargetStatus::Offline => summary.offline += 1,
            }
            if target.sent_count > 0 && target.last_rtt_ms < 0.0 {
                summary.down += 1;
            }
            if target.stale {
                summary.stale += 1;
            }
            if target.muted {
                summary.muted += 1;
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

/// Cap on distinct (path, status) pairs exported as counters. The routing
/// table has six paths, so this only matters if the HTTP parser starts
/// reporting arbitrary paths.
const MAX_HTTP_SERIES: usize = 32;

/// Facts about the daemon itself, as opposed to the targets it probes:
/// Prometheus needs these to tell a healthy monitor from a stuck one.
pub struct Health {
    started: Instant,
    snapshot_micros: AtomicU64,
    snapshot_taken: AtomicBool,
    reloads_ok: AtomicU64,
    reloads_failed: AtomicU64,
    http: Mutex<BTreeMap<(&'static str, u16), u64>>,
}

impl Health {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            snapshot_micros: AtomicU64::new(0),
            snapshot_taken: AtomicBool::new(false),
            reloads_ok: AtomicU64::new(0),
            reloads_failed: AtomicU64::new(0),
            http: Mutex::new(BTreeMap::new()),
        }
    }

    pub fn uptime_seconds(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    /// How long the engine took to produce the last snapshot; None until one
    /// tick has completed, so a fresh process does not look instantaneously
    /// fast.
    pub fn note_snapshot(&self, elapsed: Duration) {
        let micros = u64::try_from(elapsed.as_micros()).unwrap_or(u64::MAX);
        self.snapshot_micros.store(micros, Ordering::Relaxed);
        self.snapshot_taken.store(true, Ordering::Relaxed);
    }

    pub fn snapshot_seconds(&self) -> Option<f64> {
        self.snapshot_taken
            .load(Ordering::Relaxed)
            .then(|| self.snapshot_micros.load(Ordering::Relaxed) as f64 / 1_000_000.0)
    }

    pub fn note_reload(&self, ok: bool) {
        if ok {
            self.reloads_ok.fetch_add(1, Ordering::Relaxed);
        } else {
            self.reloads_failed.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn reload_counts(&self) -> (u64, u64) {
        (
            self.reloads_ok.load(Ordering::Relaxed),
            self.reloads_failed.load(Ordering::Relaxed),
        )
    }

    pub fn note_http(&self, path: &'static str, status: u16) {
        let mut map = self.http.lock();
        let key = if map.contains_key(&(path, status)) || map.len() < MAX_HTTP_SERIES {
            (path, status)
        } else {
            ("other", 0)
        };
        *map.entry(key).or_insert(0) += 1;
    }

    pub fn http_requests(&self) -> Vec<((&'static str, u16), u64)> {
        self.http
            .lock()
            .iter()
            .map(|(key, count)| (*key, *count))
            .collect()
    }
}

/// State shared by the daemon loop and the HTTP threads.
pub struct State {
    target_count: AtomicUsize,
    stats: RwLock<Arc<Vec<TargetStats>>>,
    health: Health,
}

impl State {
    pub fn new(target_count: usize) -> Arc<Self> {
        Arc::new(Self {
            target_count: AtomicUsize::new(target_count),
            stats: RwLock::new(Arc::new(Vec::new())),
            health: Health::new(),
        })
    }

    /// Takes an Arc so a tick can hand the same statistics to the shared state
    /// and to the rendered snapshot without a second deep copy.
    pub fn update(&self, stats: impl Into<Arc<Vec<TargetStats>>>) {
        *self.stats.write() = stats.into();
    }

    /// After a SIGHUP reload the expected target count changes; readiness must
    /// compare against the new set, not the startup set.
    pub fn set_target_count(&self, target_count: usize) {
        self.target_count.store(target_count, Ordering::Relaxed);
    }

    pub fn stats(&self) -> Arc<Vec<TargetStats>> {
        self.stats.read().clone()
    }

    pub fn health(&self) -> &Health {
        &self.health
    }

    /// Counts one served request for `netstudio_http_requests_total`.
    pub fn note_http(&self, path: &'static str, status: u16) {
        self.health.note_http(path, status);
    }

    pub fn configured(&self) -> usize {
        self.target_count.load(Ordering::Relaxed)
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot::new(self.stats())
    }

    /// Ready only once *every* configured target has produced a sample:
    /// before that the snapshot is incomplete and a scrape would read zeros
    /// as real values. Targets that are merely slow still hold readiness
    /// back, which is what an orchestrator should wait for.
    pub fn ready(&self) -> bool {
        let expected = self.target_count.load(Ordering::Relaxed);
        let stats = self.stats.read();
        expected > 0 && stats.len() == expected && stats.iter().all(|target| target.sent_count > 0)
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
    log::set_format(cli.log_format);
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
    let mut loaded = match config::load(&config_path) {
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
    // --interval is the snapshot cadence; --probe-interval overrides every
    // target's own interval_ms so one flag can slow a mixed config down (or
    // speed it up) without editing the file. Staleness follows the override,
    // because the engine derives it from the effective interval.
    if let Some(seconds) = cli.probe_interval_secs {
        let interval_ms = seconds * 1_000;
        for target in &mut loaded.targets {
            target.interval_ms = interval_ms;
        }
    }
    if cli.check {
        return run_check(&cli, &loaded, &config_path);
    }

    // Pre-flight the daemon's own side channels: failing before the probe
    // loop starts beats a loop that runs forever without writing a snapshot
    // or a pid file.
    if let Some(path) = &cli.output {
        if let Err(error) = validate_output_path(path) {
            log::error(error);
            return EXIT_CONFIG;
        }
    }
    if let Some(path) = &cli.pid_file {
        if let Err(error) = validate_pid_path(path) {
            log::error(error);
            return EXIT_CONFIG;
        }
    }

    stats::set_alert_thresholds(loaded.offline_after, loaded.recover_after);
    let engine = match Engine::with_probe_concurrency(cli.probe_concurrency) {
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

#[derive(Debug, serde::Serialize)]
struct CheckReport {
    schema: u32,
    #[serde(rename = "type")]
    kind: &'static str,
    ok: bool,
    config: String,
    targets: usize,
    muted: usize,
    warnings: Vec<String>,
    checks: Vec<CheckItem>,
}

#[derive(Debug, serde::Serialize)]
struct CheckItem {
    name: &'static str,
    ok: bool,
    detail: String,
}

/// `--check` answers one question: "would this invocation start right now?"
/// Besides the config it validates every side channel the daemon opens at
/// startup, so an unwritable output directory or a taken port is a failed
/// check instead of a daemon that runs for hours without writing anything.
fn run_check(cli: &cli::Cli, loaded: &config::LoadedConfig, config_path: &Path) -> i32 {
    let muted = loaded.targets.iter().filter(|target| target.muted).count();
    let mut checks = vec![CheckItem {
        name: "config",
        ok: true,
        detail: format!("{} usable target(s), {muted} muted", loaded.targets.len()),
    }];

    if let Some(path) = &cli.output {
        checks.push(check_item(
            "output",
            validate_output_path(path),
            format!("{} is writable", path.display()),
        ));
    }
    if let Some(path) = &cli.pid_file {
        checks.push(check_item(
            "pid-file",
            validate_pid_path(path),
            format!("{} is available", path.display()),
        ));
    }
    if let Some(address) = cli.listen {
        checks.push(check_item(
            "listen",
            validate_listen(address),
            format!("{address} is bindable"),
        ));
        // A missing or empty token file must fail the preflight, not the first
        // authenticated scrape.
        let token = http_token(cli);
        let detail = match (&token, &cli.http_token_file) {
            (Ok(Some(_)), Some(path)) => format!("bearer token from {} is loaded", path.display()),
            (Ok(Some(_)), None) => "bearer token from NETSTUDIO_HTTP_TOKEN is loaded".to_string(),
            _ => "no token (endpoints are unauthenticated)".to_string(),
        };
        let ok = token.map(|_| ());
        checks.push(check_item("auth", ok, detail));
    }

    let report = CheckReport {
        schema: 1,
        kind: "check",
        ok: checks.iter().all(|check| check.ok),
        config: config_path.display().to_string(),
        targets: loaded.targets.len(),
        muted,
        warnings: loaded.warnings.clone(),
        checks,
    };

    // Same rule as --once and the daemon: text on a terminal, JSON when piped;
    // --format overrides either. A check needs no probe, so the text form is
    // the whole report.
    let json = !uses_text(cli.format);
    if !json {
        let style = term::stdout_style();
        if report.ok {
            println!(
                "{} {} target(s) in {}",
                style.green("config OK:"),
                report.targets,
                config_path.display()
            );
            for check in &report.checks {
                println!(
                    "  {} {}",
                    style.dim(&format!("{:<8}", check.name)),
                    check.detail
                );
            }
        } else {
            for check in report.checks.iter().filter(|check| !check.ok) {
                log::error(format!("{}: {}", check.name, check.detail));
            }
            println!(
                "{} {} target(s) in {}",
                style.red("config FAILED:"),
                report.targets,
                config_path.display()
            );
        }
    } else {
        println!(
            "{}",
            serde_json::to_string(&report).unwrap_or_else(|_| "{}".to_string())
        );
    }

    if report.ok {
        EXIT_OK
    } else {
        EXIT_CONFIG
    }
}

fn check_item(name: &'static str, result: Result<(), String>, ok_detail: String) -> CheckItem {
    match result {
        Ok(()) => CheckItem {
            name,
            ok: true,
            detail: ok_detail,
        },
        Err(error) => CheckItem {
            name,
            ok: false,
            detail: error,
        },
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
    // A muted target is still probed and reported, but muting means "do not
    // page me": it must not turn a cron run red. The snapshot keeps the
    // factual count, the exit code uses the alerting one.
    let alerting_down = snapshot
        .targets
        .iter()
        .filter(|target| !target.muted && target.sent_count > 0 && target.last_rtt_ms < 0.0)
        .count();
    log::info(format!(
        "finished in {:.2}s: {} target(s), {} down, {} muted",
        started.elapsed().as_secs_f64(),
        snapshot.summary.targets,
        snapshot.summary.down,
        snapshot.summary.muted
    ));
    if snapshot.summary.targets == 0 {
        return EXIT_FAILURE;
    }
    if alerting_down > 0 {
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
    // What the engine is currently running; a SIGHUP compares the file against
    // this snapshot instead of get_metrics_snapshot() (which is empty until the
    // first sample and would make every reload look like "add everything").
    let mut applied: HashMap<u32, TargetConfig> = loaded
        .targets
        .iter()
        .map(|target| (target.id, target.clone()))
        .collect();

    let token = match http_token(cli) {
        Ok(token) => token,
        Err(error) => {
            log::error(error);
            return EXIT_CONFIG;
        }
    };
    let mut server = match cli.listen {
        Some(address) => {
            if !address.ip().is_loopback() {
                let transport = if token.is_some() {
                    "with a bearer token but without TLS"
                } else {
                    "without TLS or authentication"
                };
                log::warn(format!(
                    "HTTP is bound to non-loopback {address} {transport}; \
                     bind to 127.0.0.1 and put a TLS reverse proxy in front, or restrict access at the firewall"
                ));
            }
            match http::Server::spawn(address, state.clone(), token) {
                Ok(server) => Some(server),
                Err(error) => {
                    log::error(format!("cannot listen on {address}: {error}"));
                    return EXIT_FAILURE;
                }
            }
        }
        None => None,
    };

    let pid_file = match &cli.pid_file {
        Some(path) => match PidFile::acquire(path) {
            Ok(guard) => Some(guard),
            Err(error) => {
                log::error(error);
                if let Some(mut server) = server.take() {
                    server.stop();
                }
                return EXIT_CONFIG;
            }
        },
        None => None,
    };
    if let Some(guard) = &pid_file {
        log::info(format!("pid file: {}", guard.path().display()));
    }
    if let Err(error) = signal::install() {
        log::warn(format!("signal handling unavailable: {error}"));
    }

    log::info(format!(
        "{NAME} {VERSION} starting: {} target(s), config {}",
        loaded.targets.len(),
        config_path.display()
    ));
    if signal::RELOAD_SUPPORTED {
        log::info("SIGHUP reloads the config file without a restart");
    }
    if let Some(server) = &server {
        log::info(format!("HTTP listening on http://{}", server.addr()));
    }
    if let Some(path) = &cli.output {
        log::info(format!("snapshot file: {}", path.display()));
    }
    let mut watch = cli.watch_config_secs.map(|seconds| {
        log::info(format!(
            "watching {} for changes every {seconds}s",
            config_path.display()
        ));
        Watch {
            period: Duration::from_secs(seconds),
            next: Instant::now() + Duration::from_secs(seconds),
            stamp: config_stamp(config_path),
        }
    });

    engine.start();
    let mut next_emit = Instant::now();
    let mut stream_open = !cli.quiet;
    let mut stale_targets = HashSet::new();
    // Log an output failure once, not once per interval, and announce the
    // recovery: the same message every second buries everything else.
    let mut output_error: Option<String> = None;
    while !signal::shutdown_requested() {
        let mut reload_reason = signal::take_reload_request().then_some("SIGHUP");
        if let Some(watch) = &mut watch {
            if Instant::now() >= watch.next {
                watch.next = Instant::now() + watch.period;
                let current = config_stamp(config_path);
                if current != watch.stamp {
                    watch.stamp = current;
                    // A SIGHUP that landed on the same tick already reloads.
                    if reload_reason.is_none() {
                        reload_reason = Some("watch");
                        log::info(format!("{} changed; reloading", config_path.display()));
                    }
                }
            }
        }
        if reload_reason.is_some() {
            let outcome = reload(&engine, &state, cli, config_path, &mut applied);
            state.health().note_reload(outcome.is_ok());
            match outcome {
                Ok(count) => log::info(format!(
                    "reloaded {count} target(s) from {}",
                    config_path.display()
                )),
                Err(error) => log::error(format!(
                    "reload failed, keeping the running configuration: {error}"
                )),
            }
            if let Some(server) = &server {
                refresh_http_token(cli, server);
            }
            // Remember what was loaded, so a watcher does not retry the same
            // broken file every period; the next edit triggers a new attempt.
            if let Some(watch) = &mut watch {
                watch.stamp = config_stamp(config_path);
            }
        }
        let tick_started = Instant::now();
        let stats = Arc::new(engine.get_metrics_snapshot());
        state.health().note_snapshot(tick_started.elapsed());
        log_staleness(&mut stale_targets, &stats);
        state.update(Arc::clone(&stats));
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
                match write_snapshot(path, &snapshot.to_pretty_json()) {
                    Ok(()) => {
                        if output_error.take().is_some() {
                            log::info(format!(
                                "snapshot file {} is writable again",
                                path.display()
                            ));
                        }
                    }
                    Err(error) => {
                        if output_error.as_deref() != Some(error.as_str()) {
                            log::error(error.clone());
                            output_error = Some(error);
                        }
                    }
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
    // Drop ends the exclusive pid-file claim (and removes the file).
    drop(pid_file);
    log::info("stopped");
    EXIT_OK
}

/// Polled config file state, used when SIGHUP is unavailable.
struct Watch {
    period: Duration,
    next: Instant,
    stamp: Option<ConfigStamp>,
}

/// Modified time plus size: one alone misses edits on filesystems with a
/// coarse timestamp, and both are cheap to read.
#[derive(Clone, Copy, PartialEq, Eq)]
struct ConfigStamp {
    modified: Option<std::time::SystemTime>,
    size: u64,
}

fn config_stamp(path: &Path) -> Option<ConfigStamp> {
    let metadata = fs::metadata(path).ok()?;
    Some(ConfigStamp {
        modified: metadata.modified().ok(),
        size: metadata.len(),
    })
}

/// SIGHUP also rotates the bearer token. A missing, empty or unreadable
/// source must never weaken a running endpoint, so the previous token stays
/// in place and the failure is logged.
fn refresh_http_token(cli: &cli::Cli, server: &http::Server) {
    match http_token(cli) {
        Ok(Some(token)) => {
            let rotated = server.token().as_deref() != Some(token.as_ref());
            server.set_token(Some(token));
            if rotated {
                log::info("HTTP bearer token rotated");
            }
        }
        Ok(None) => {
            if server.token().is_some() {
                log::warn("the HTTP token source is gone; keeping the previous token");
            }
        }
        Err(error) => log::warn(format!("keeping the previous HTTP token: {error}")),
    }
}

/// Longest accepted HTTP token; long secrets are pointless and would only
/// bloat the header comparison.
const MAX_HTTP_TOKEN_CHARS: usize = 256;

/// The HTTP bearer token comes from a file (preferred: it keeps the secret out
/// of the process list and shell history) or from NETSTUDIO_HTTP_TOKEN.
fn http_token(cli: &cli::Cli) -> Result<Option<Arc<str>>, String> {
    let raw = match &cli.http_token_file {
        Some(path) => Some(fs::read_to_string(path).map_err(|error| {
            format!("cannot read --http-token-file {}: {error}", path.display())
        })?),
        // An empty variable means "not configured": a blank secret must never
        // be silently accepted as a token nobody can guess.
        None => match std::env::var("NETSTUDIO_HTTP_TOKEN") {
            Ok(value) if !value.trim().is_empty() => Some(value),
            _ => None,
        },
    };
    let Some(raw) = raw else {
        return Ok(None);
    };
    let token = raw.trim();
    if token.is_empty() {
        return Err("HTTP token is empty".to_string());
    }
    if token.chars().count() > MAX_HTTP_TOKEN_CHARS {
        return Err(format!(
            "HTTP token is longer than {MAX_HTTP_TOKEN_CHARS} characters"
        ));
    }
    if token.chars().any(char::is_control) {
        return Err("HTTP token contains a control character".to_string());
    }
    Ok(Some(Arc::from(token)))
}

/// SIGHUP: re-read the config file and apply add/remove/update without a
/// restart. A malformed file must never take the daemon down, so every failure
/// is returned as an error and the caller keeps the old configuration.
fn reload(
    engine: &Engine,
    state: &State,
    cli: &cli::Cli,
    config_path: &Path,
    applied: &mut HashMap<u32, TargetConfig>,
) -> Result<usize, String> {
    let mut loaded = config::load(config_path)?;
    if loaded.targets.is_empty() {
        return Err(format!("no usable targets in {}", config_path.display()));
    }
    if let Some(seconds) = cli.probe_interval_secs {
        let interval_ms = seconds * 1_000;
        for target in &mut loaded.targets {
            target.interval_ms = interval_ms;
        }
    }

    let desired: HashMap<u32, TargetConfig> = loaded
        .targets
        .iter()
        .map(|target| (target.id, target.clone()))
        .collect();
    for id in applied.keys().filter(|id| !desired.contains_key(id)) {
        engine.remove_target(*id);
        log::info(format!("reload: target {id} removed"));
    }
    for (id, target) in &desired {
        match applied.get(id) {
            // Unchanged targets keep their history, jitter and counters.
            Some(previous) if previous == target => continue,
            Some(_) => log::info(format!(
                "reload: target {id} ({}) updated; its counters restart",
                target.name
            )),
            None => log::info(format!("reload: target {id} ({}) added", target.name)),
        }
        engine.add_target(target.clone());
    }
    stats::set_alert_thresholds(loaded.offline_after, loaded.recover_after);
    *applied = desired;
    state.set_target_count(applied.len());
    Ok(applied.len())
}

/// Warn once when a target goes stale, and log recovery once. This keeps a
/// stalled probe visible in logs without repeating every scrape.
fn log_staleness(known: &mut HashSet<u32>, stats: &[TargetStats]) {
    let mut current = HashSet::new();
    for target in stats {
        if target.stale {
            current.insert(target.id);
            if !known.contains(&target.id) {
                log::warn(format!(
                    "target {} is stale: last sample {}s ago (threshold {}s)",
                    target.name,
                    target.last_sample_age_ms.unwrap_or(0) / 1_000,
                    target.stale_after_ms / 1_000
                ));
            }
        } else if known.contains(&target.id) {
            log::info(format!(
                "target {} is reporting fresh samples again",
                target.name
            ));
        }
    }
    *known = current;
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

/// Exclusive pid file.
///
/// Created with O_EXCL, so two daemons can never both claim it; a leftover
/// file is only taken over once its pid is proven dead. Drop removes the file,
/// and only while it still holds our own pid (never a successor's).
#[derive(Debug)]
struct PidFile {
    path: PathBuf,
}

impl PidFile {
    fn acquire(path: &Path) -> Result<Self, String> {
        let dir = parent_dir(path);
        if !dir.is_dir() {
            return Err(format!(
                "pid file directory {} does not exist",
                dir.display()
            ));
        }
        let pid = std::process::id();
        for attempt in 0..2 {
            match OpenOptions::new().write(true).create_new(true).open(path) {
                Ok(mut file) => {
                    file.write_all(format!("{pid}\n").as_bytes())
                        .and_then(|()| file.sync_all())
                        .map_err(|error| {
                            let _ = std::fs::remove_file(path);
                            format!("cannot write pid file {}: {error}", path.display())
                        })?;
                    return Ok(Self {
                        path: path.to_path_buf(),
                    });
                }
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                    if attempt > 0 {
                        break;
                    }
                    match read_pid(path) {
                        Some(holder) if pid_alive(holder) => {
                            return Err(format!(
                                "{} is already held by running process {holder}",
                                path.display()
                            ));
                        }
                        _ => {
                            log::warn(format!(
                                "removing stale pid file {} (no live process owns it)",
                                path.display()
                            ));
                            let _ = std::fs::remove_file(path);
                        }
                    }
                }
                Err(error) => {
                    return Err(format!(
                        "cannot create pid file {}: {error}",
                        path.display()
                    ));
                }
            }
        }
        Err(format!(
            "cannot create pid file {}: still present after removing the stale copy",
            path.display()
        ))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for PidFile {
    fn drop(&mut self) {
        if read_pid(&self.path) == Some(std::process::id()) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

fn read_pid(path: &Path) -> Option<u32> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// Whether the pid names a live process. A recycled pid can make a stale file
/// look live; that only costs the operator a manual delete.
#[cfg(unix)]
fn pid_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    // SAFETY: signal 0 performs only the existence/permission check.
    let result = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if result == 0 {
        return true;
    }
    // EPERM means the process exists but belongs to another user.
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(windows)]
fn pid_alive(pid: u32) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ACCESS_DENIED};
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    // GetExitCodeProcess reports 259 (STILL_ACTIVE) while the process runs.
    const STILL_ACTIVE_CODE: u32 = 259;

    if pid == 0 {
        return false;
    }
    // SAFETY: handles returned by OpenProcess are closed below; the pid comes
    // from our own pid file.
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            // Access denied still means a live process owns the pid.
            return GetLastError() == ERROR_ACCESS_DENIED;
        }
        let mut code: u32 = 0;
        let ok = GetExitCodeProcess(handle, &mut code) != 0;
        let _ = CloseHandle(handle);
        ok && code == STILL_ACTIVE_CODE
    }
}

#[cfg(all(not(unix), not(windows)))]
fn pid_alive(_pid: u32) -> bool {
    false
}

fn parent_dir(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

/// The output file's parent directory must exist: the file itself is replaced
/// on every write, so a read-only directory is the failure mode that matters.
fn validate_output_path(path: &Path) -> Result<(), String> {
    let dir = parent_dir(path);
    if !dir.is_dir() {
        return Err(format!("output directory {} does not exist", dir.display()));
    }
    if path.is_dir() {
        return Err(format!("output path {} is a directory", path.display()));
    }
    probe_dir_writable(dir)
}

fn validate_pid_path(path: &Path) -> Result<(), String> {
    let dir = parent_dir(path);
    if !dir.is_dir() {
        return Err(format!(
            "pid file directory {} does not exist",
            dir.display()
        ));
    }
    probe_dir_writable(dir)?;
    if let Some(holder) = read_pid(path) {
        if pid_alive(holder) {
            return Err(format!(
                "{} is already held by running process {holder}",
                path.display()
            ));
        }
    }
    Ok(())
}

/// Bind and immediately release the address: proves the port is free and that
/// the local interface exists, without leaving anything listening.
fn validate_listen(address: std::net::SocketAddr) -> Result<(), String> {
    match std::net::TcpListener::bind(address) {
        Ok(listener) => {
            drop(listener);
            Ok(())
        }
        Err(error) => Err(format!("cannot bind {address}: {error}")),
    }
}

fn probe_dir_writable(dir: &Path) -> Result<(), String> {
    let probe = dir.join(format!(
        ".{NAME}-write-test.{}.{}",
        std::process::id(),
        log::now_epoch_ms()
    ));
    match OpenOptions::new().write(true).create_new(true).open(&probe) {
        Ok(file) => {
            drop(file);
            let _ = std::fs::remove_file(&probe);
            Ok(())
        }
        Err(error) => Err(format!(
            "directory {} is not writable: {error}",
            dir.display()
        )),
    }
}

fn write_snapshot(path: &Path, contents: &str) -> Result<(), String> {
    let parent = parent_dir(path);
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

    fn temp_dir(tag: &str) -> PathBuf {
        let directory =
            std::env::temp_dir().join(format!("netstudio-headless-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("temp dir");
        directory
    }

    #[test]
    fn rotating_the_http_token_keeps_the_old_secret_when_the_file_is_unusable() {
        let dir = temp_dir("token-rotate");
        let token_path = dir.join("token");
        fs::write(&token_path, "one\n").expect("token");
        let cli = cli::parse(&[
            "-c".to_string(),
            "targets.json".to_string(),
            "--listen".to_string(),
            "127.0.0.1:0".to_string(),
            "--http-token-file".to_string(),
            token_path.display().to_string(),
        ])
        .expect("cli");
        let server = http::Server::spawn(
            "127.0.0.1:0".parse().expect("addr"),
            State::new(1),
            http_token(&cli).expect("token"),
        )
        .expect("spawn");
        assert_eq!(server.token().as_deref(), Some("one"));

        fs::write(&token_path, "two\n").expect("rotate");
        refresh_http_token(&cli, &server);
        assert_eq!(server.token().as_deref(), Some("two"));

        // An empty file and a deleted file both fail to load: the running
        // secret must survive instead of silently opening the endpoint.
        fs::write(&token_path, "").expect("blank");
        refresh_http_token(&cli, &server);
        assert_eq!(server.token().as_deref(), Some("two"));

        fs::remove_file(&token_path).expect("remove");
        refresh_http_token(&cli, &server);
        assert_eq!(server.token().as_deref(), Some("two"));

        drop(server);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn readiness_waits_for_every_target() {
        let state = State::new(2);
        state.update(vec![tracker(1, true).snapshot()]);
        // One of two targets has sampled: still not ready.
        assert!(!state.ready());
        state.update(vec![
            tracker(1, true).snapshot(),
            tracker(2, true).snapshot(),
        ]);
        assert!(state.ready());
        // A target that sampled but failed is still a sample: ready.
        state.update(vec![
            tracker(1, true).snapshot(),
            tracker(2, false).snapshot(),
        ]);
        assert!(state.ready());
    }

    #[test]
    fn summary_counts_muted_targets() {
        let mut muted = tracker(1, false);
        muted = muted.with_organization("edge".to_string(), true);
        let snapshot = Snapshot::new(vec![muted.snapshot(), tracker(2, false).snapshot()]);
        assert_eq!(snapshot.summary.muted, 1);
        // Muted does not hide the failure from the snapshot itself.
        assert_eq!(snapshot.summary.down, 2);
        assert!(snapshot.to_json().contains("\"muted\":1"));
    }

    #[test]
    fn output_path_is_validated_before_use() {
        let directory = temp_dir("output");
        let path = directory.join("status.json");
        assert!(validate_output_path(&path).is_ok());
        let missing = directory.join("nope").join("status.json");
        let error = validate_output_path(&missing).expect_err("missing dir");
        assert!(error.contains("does not exist"), "{error}");
        let error = validate_output_path(&directory).expect_err("directory");
        assert!(error.contains("is a directory"), "{error}");
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn pid_file_is_exclusive_and_releases_on_drop() {
        let directory = temp_dir("pid");
        let path = directory.join("headless.pid");
        let guard = PidFile::acquire(&path).expect("acquire");
        assert_eq!(
            std::fs::read_to_string(&path).expect("read").trim(),
            std::process::id().to_string()
        );
        // A second daemon in the same process is refused, not allowed to steal it.
        let error = PidFile::acquire(&path).expect_err("second acquire");
        assert!(error.contains("already held"), "{error}");
        drop(guard);
        assert!(!path.exists(), "drop must remove the pid file");
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn stale_pid_file_is_taken_over() {
        let directory = temp_dir("stale-pid");
        let path = directory.join("headless.pid");
        // No live process can own this pid on either platform.
        std::fs::write(&path, "4000000000\n").expect("write stale");
        let guard = PidFile::acquire(&path).expect("take over");
        assert_eq!(
            std::fs::read_to_string(&path).expect("read").trim(),
            std::process::id().to_string()
        );
        drop(guard);
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn pid_validation_rejects_a_live_holder() {
        let directory = temp_dir("pid-live");
        let path = directory.join("headless.pid");
        // Our own pid is definitely alive; the daemon must refuse to start.
        std::fs::write(&path, format!("{}\n", std::process::id())).expect("write");
        let error = validate_pid_path(&path).expect_err("live holder");
        assert!(error.contains("already held"), "{error}");
        let _ = std::fs::remove_dir_all(&directory);
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
