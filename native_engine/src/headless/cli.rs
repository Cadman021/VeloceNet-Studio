//! Command-line parsing for the headless binary (no clap dependency).

use std::net::SocketAddr;
use std::path::PathBuf;

use super::log;
use super::log::Level;
use super::term::ColorMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    Auto,
    Json,
    Text,
}

impl OutputFormat {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "auto" => Some(Self::Auto),
            "json" | "ndjson" => Some(Self::Json),
            "text" | "table" | "human" => Some(Self::Text),
            _ => None,
        }
    }
}

pub const HELP: &str = concat!(
    "netstudio-headless ",
    env!("CARGO_PKG_VERSION"),
    "\n",
    "\n",
    "Usage:\n",
    "  netstudio-headless --config <PATH> [OPTIONS]\n",
    "\n",
    "Options:\n",
    "  -c, --config <PATH>     Target configuration file (required)\n",
    "      --check             Validate the configuration (and --output,\n",
    "                          --pid-file, --listen when given), then exit\n",
    "      --once              Probe every target once, print a snapshot, exit\n",
    "      --interval <SECS>   Snapshot interval in seconds (default: 5)\n",
    "      --probe-interval <SECS>\n",
    "                          Probe every target this often (default: per target)\n",
    "      --probe-concurrency <N>\n",
    "                          Maximum probes in flight (default: 32)\n",
    "      --listen <ADDR>     Serve HTTP on ADDR (daemon mode), e.g. 127.0.0.1:9101\n",
    "      --output <PATH>     Atomically write the latest JSON snapshot to PATH\n",
    "      --pid-file <PATH>   Write the process id to PATH (daemon mode)\n",
    "      --http-token-file <PATH>\n",
    "                          Require 'Authorization: Bearer <token>' on every\n",
    "                          endpoint except /healthz; NETSTUDIO_HTTP_TOKEN is\n",
    "                          used when no file is given (daemon mode)\n",
    "  -q, --quiet             Do not stream snapshots to stdout\n",
    "      --format <MODE>     auto (default), json or text\n",
    "      --color <WHEN>      auto (default), always or never\n",
    "          --no-color      Same as --color never\n",
    "      --log-level <LEVEL> error, warn, info (default) or debug\n",
    "      --log-format <FMT>  text (default) or json (one object per line)\n",
    "  -h, --help              Print this help and exit\n",
    "  -V, --version           Print the version and exit\n",
    "\n",
    "Exit codes:\n",
    "  0  success (or every probed target reached in --once)\n",
    "  1  runtime failure (for example a snapshot that cannot be written)\n",
    "  2  invalid configuration, command line, --output/--pid-file path\n",
    "     or an address that cannot be bound\n",
    "  3  --once finished with at least one non-muted target down\n",
);

#[derive(Debug)]
pub struct Cli {
    pub help: bool,
    pub version: bool,
    pub config: Option<PathBuf>,
    pub once: bool,
    pub check: bool,
    pub quiet: bool,
    pub interval_secs: u64,
    /// Global probe cadence override; None keeps each target's interval_ms.
    pub probe_interval_secs: Option<u64>,
    pub probe_concurrency: usize,
    pub listen: Option<SocketAddr>,
    pub output: Option<PathBuf>,
    pub pid_file: Option<PathBuf>,
    /// File holding the bearer token required by the HTTP server; None keeps
    /// the endpoints unauthenticated (the caller is expected to stay on
    /// loopback or behind an authenticating proxy).
    pub http_token_file: Option<PathBuf>,
    pub format: OutputFormat,
    pub color: ColorMode,
    pub log_level: Level,
    pub log_format: log::Format,
}

impl Default for Cli {
    fn default() -> Self {
        Self {
            help: false,
            version: false,
            config: None,
            once: false,
            check: false,
            quiet: false,
            interval_secs: 5,
            probe_interval_secs: None,
            probe_concurrency: 32,
            listen: None,
            output: None,
            pid_file: None,
            http_token_file: None,
            format: OutputFormat::Auto,
            color: ColorMode::Auto,
            log_level: Level::Info,
            log_format: log::Format::Text,
        }
    }
}

pub fn parse(args: &[String]) -> Result<Cli, String> {
    let mut cli = Cli::default();
    let mut index = 0;
    while index < args.len() {
        let raw = args[index].clone();
        let (flag, inline) = match raw.split_once("=") {
            Some((flag, value)) => (flag.to_string(), Some(value.to_string())),
            None => (raw, None),
        };
        match flag.as_str() {
            "-h" | "--help" => {
                cli.help = true;
                return Ok(cli);
            }
            "-V" | "--version" => {
                cli.version = true;
                return Ok(cli);
            }
            "-c" | "--config" => {
                cli.config = Some(PathBuf::from(take_value(&flag, inline, args, &mut index)?));
            }
            "--once" => {
                reject_value(&flag, inline.as_deref())?;
                cli.once = true;
            }
            "--check" => {
                reject_value(&flag, inline.as_deref())?;
                cli.check = true;
            }
            "-q" | "--quiet" => {
                reject_value(&flag, inline.as_deref())?;
                cli.quiet = true;
            }
            "--interval" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                let seconds: u64 = value
                    .parse()
                    .map_err(|_| format!("invalid --interval value: {value}"))?;
                if !(1..=3600).contains(&seconds) {
                    return Err("--interval must be between 1 and 3600 seconds".to_string());
                }
                cli.interval_secs = seconds;
            }
            "--probe-interval" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                let seconds: u64 = value
                    .parse()
                    .map_err(|_| format!("invalid --probe-interval value: {value}"))?;
                if !(1..=3600).contains(&seconds) {
                    return Err("--probe-interval must be between 1 and 3600 seconds".to_string());
                }
                cli.probe_interval_secs = Some(seconds);
            }
            "--probe-concurrency" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                let limit: usize = value
                    .parse()
                    .map_err(|_| format!("invalid --probe-concurrency value: {value}"))?;
                if !(1..=256).contains(&limit) {
                    return Err("--probe-concurrency must be between 1 and 256".to_string());
                }
                cli.probe_concurrency = limit;
            }
            "--listen" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                let address: SocketAddr = value
                    .parse()
                    .map_err(|_| format!("invalid --listen address {value}: expected IP:PORT"))?;
                cli.listen = Some(address);
            }
            "--output" => {
                cli.output = Some(PathBuf::from(take_value(&flag, inline, args, &mut index)?));
            }
            "--pid-file" => {
                cli.pid_file = Some(PathBuf::from(take_value(&flag, inline, args, &mut index)?));
            }
            "--http-token-file" => {
                cli.http_token_file =
                    Some(PathBuf::from(take_value(&flag, inline, args, &mut index)?));
            }
            "--format" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                cli.format = OutputFormat::parse(&value).ok_or_else(|| {
                    format!("invalid --format value: {value} (use auto, json or text)")
                })?;
            }
            "--color" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                cli.color = ColorMode::parse(&value).ok_or_else(|| {
                    format!("invalid --color value: {value} (use auto, always or never)")
                })?;
            }
            "--no-color" => {
                reject_value(&flag, inline.as_deref())?;
                cli.color = ColorMode::Never;
            }
            "--log-level" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                cli.log_level = Level::parse(&value).ok_or_else(|| {
                    format!("invalid --log-level value: {value} (use error, warn, info or debug)")
                })?;
            }
            "--log-format" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                cli.log_format = log::Format::parse(&value).ok_or_else(|| {
                    format!("invalid --log-format value: {value} (use text or json)")
                })?;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
        index += 1;
    }
    if cli.once && cli.check {
        return Err("--once and --check cannot be combined".to_string());
    }
    // --once exits after one snapshot: a listening socket or a pid file would
    // be dropped before anyone could use them. Reject loudly instead of
    // silently ignoring what the operator asked for.
    if cli.once && cli.listen.is_some() {
        return Err("--listen is a daemon option and cannot be combined with --once".to_string());
    }
    if cli.once && cli.pid_file.is_some() {
        return Err("--pid-file is a daemon option and cannot be combined with --once".to_string());
    }
    if cli.once && cli.http_token_file.is_some() {
        return Err(
            "--http-token-file is a daemon option and cannot be combined with --once".to_string(),
        );
    }
    Ok(cli)
}

fn take_value(
    flag: &str,
    inline: Option<String>,
    args: &[String],
    index: &mut usize,
) -> Result<String, String> {
    if let Some(value) = inline {
        if value.is_empty() {
            return Err(format!("{flag} requires a value"));
        }
        return Ok(value);
    }
    *index += 1;
    args.get(*index)
        .cloned()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("{flag} requires a value"))
}

fn reject_value(flag: &str, inline: Option<&str>) -> Result<(), String> {
    if inline.is_some() {
        Err(format!("{flag} does not take a value"))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| item.to_string()).collect()
    }

    #[test]
    fn defaults_are_daemon_friendly() {
        let cli = parse(&args(&["--config", "targets.json"])).expect("parse");
        assert_eq!(cli.interval_secs, 5);
        assert_eq!(cli.probe_concurrency, 32);
        assert!(cli.listen.is_none());
        assert!(!cli.once);
        assert!(!cli.check);
        assert_eq!(cli.format, OutputFormat::Auto);
        assert_eq!(cli.color, ColorMode::Auto);
        assert_eq!(cli.log_level, Level::Info);
        assert_eq!(cli.log_format, log::Format::Text);
    }

    #[test]
    fn equals_form_and_optional_flags() {
        let cli = parse(&args(&[
            "--config=targets.json",
            "--interval=15",
            "--probe-concurrency=16",
            "--listen=127.0.0.1:9101",
            "--output=status.json",
            "--pid-file=run.pid",
            "--quiet",
            "--format=text",
            "--color=always",
            "--log-level=debug",
        ]))
        .expect("parse");
        assert_eq!(cli.interval_secs, 15);
        assert_eq!(cli.probe_concurrency, 16);
        assert_eq!(cli.listen.expect("listen").port(), 9101);
        assert!(cli.quiet);
        assert_eq!(cli.format, OutputFormat::Text);
        assert_eq!(cli.color, ColorMode::Always);
        assert_eq!(cli.log_level, Level::Debug);
    }

    #[test]
    fn probe_interval_is_validated() {
        let cli = parse(&args(&["--config", "t.json", "--probe-interval", "10"])).expect("parse");
        assert_eq!(cli.probe_interval_secs, Some(10));
        for bad in ["0", "3601", "soon"] {
            let error = parse(&args(&["--probe-interval", bad])).expect_err(bad);
            assert!(error.contains("--probe-interval"), "{error}");
        }
    }

    #[test]
    fn rejects_invalid_values() {
        assert!(parse(&args(&["--interval", "0"])).is_err());
        assert!(parse(&args(&["--interval", "3601"])).is_err());
        assert!(parse(&args(&["--interval", "soon"])).is_err());
        assert!(parse(&args(&["--probe-concurrency", "0"])).is_err());
        assert!(parse(&args(&["--probe-concurrency", "257"])).is_err());
        assert!(parse(&args(&["--probe-concurrency", "many"])).is_err());
        assert!(parse(&args(&["--listen", "localhost"])).is_err());
        assert!(parse(&args(&["--log-level", "trace"])).is_err());
        assert!(parse(&args(&["--format", "yaml"])).is_err());
        assert!(parse(&args(&["--color", "rainbow"])).is_err());
        assert!(parse(&args(&["--config"])).is_err());
        assert!(parse(&args(&["--once=yes"])).is_err());
        assert!(parse(&args(&["--bogus"])).is_err());
        assert!(parse(&args(&["--once", "--check"])).is_err());
    }

    #[test]
    fn daemon_only_flags_are_rejected_with_once() {
        assert!(parse(&args(&[
            "--config",
            "targets.json",
            "--once",
            "--listen",
            "127.0.0.1:9101"
        ]))
        .is_err());
        assert!(parse(&args(&[
            "--config",
            "targets.json",
            "--once",
            "--pid-file",
            "x.pid"
        ]))
        .is_err());
        assert!(parse(&args(&[
            "--config",
            "targets.json",
            "--once",
            "--http-token-file",
            "token"
        ]))
        .is_err());
        // --output is meaningful for --once (it writes the snapshot there).
        assert!(parse(&args(&[
            "--config",
            "targets.json",
            "--once",
            "--output",
            "status.json"
        ]))
        .is_ok());
        // Both remain valid for --check: they are validated, not ignored.
        assert!(parse(&args(&[
            "--config",
            "targets.json",
            "--check",
            "--listen",
            "127.0.0.1:9101",
            "--pid-file",
            "x.pid",
            "--output",
            "status.json"
        ]))
        .is_ok());
    }

    #[test]
    fn no_color_alias_wins() {
        let cli = parse(&args(&["--color=always", "--no-color"])).expect("parse");
        assert_eq!(cli.color, ColorMode::Never);
    }

    #[test]
    fn help_and_version_short_circuit() {
        assert!(parse(&args(&["--help", "--bogus"])).expect("help").help);
        assert!(parse(&args(&["-V"])).expect("version").version);
    }
}
