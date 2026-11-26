//! Command-line parsing for the headless binary (no clap dependency).

use std::net::SocketAddr;
use std::path::PathBuf;

use super::log::Level;

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
    "      --check             Validate the configuration and exit\n",
    "      --once              Probe every target once, print JSON, and exit\n",
    "      --interval <SECS>   Snapshot interval in seconds (default: 5)\n",
    "      --listen <ADDR>     Serve HTTP on ADDR, e.g. 127.0.0.1:9101\n",
    "      --output <PATH>     Atomically write the latest snapshot to PATH\n",
    "      --pid-file <PATH>   Write the process id to PATH while running\n",
    "  -q, --quiet             Do not stream NDJSON snapshots to stdout\n",
    "      --log-level <LEVEL> error, warn, info (default) or debug\n",
    "  -h, --help              Print this help and exit\n",
    "  -V, --version           Print the version and exit\n",
    "\n",
    "Exit codes:\n",
    "  0  success (or every probed target reached in --once)\n",
    "  1  runtime failure\n",
    "  2  invalid configuration or command line\n",
    "  3  --once finished with at least one target down\n",
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
    pub listen: Option<SocketAddr>,
    pub output: Option<PathBuf>,
    pub pid_file: Option<PathBuf>,
    pub log_level: Level,
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
            listen: None,
            output: None,
            pid_file: None,
            log_level: Level::Info,
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
            "--log-level" => {
                let value = take_value(&flag, inline, args, &mut index)?;
                cli.log_level = Level::parse(&value).ok_or_else(|| {
                    format!("invalid --log-level value: {value} (use error, warn, info or debug)")
                })?;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
        index += 1;
    }
    if cli.once && cli.check {
        return Err("--once and --check cannot be combined".to_string());
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
        assert!(cli.listen.is_none());
        assert!(!cli.once);
        assert!(!cli.check);
        assert_eq!(cli.log_level, Level::Info);
    }

    #[test]
    fn equals_form_and_optional_flags() {
        let cli = parse(&args(&[
            "--config=targets.json",
            "--interval=15",
            "--listen=127.0.0.1:9101",
            "--output=status.json",
            "--pid-file=run.pid",
            "--quiet",
            "--log-level=debug",
        ]))
        .expect("parse");
        assert_eq!(cli.interval_secs, 15);
        assert_eq!(cli.listen.expect("listen").port(), 9101);
        assert!(cli.quiet);
        assert_eq!(cli.log_level, Level::Debug);
    }

    #[test]
    fn rejects_invalid_values() {
        assert!(parse(&args(&["--interval", "0"])).is_err());
        assert!(parse(&args(&["--interval", "3601"])).is_err());
        assert!(parse(&args(&["--interval", "soon"])).is_err());
        assert!(parse(&args(&["--listen", "localhost"])).is_err());
        assert!(parse(&args(&["--log-level", "trace"])).is_err());
        assert!(parse(&args(&["--config"])).is_err());
        assert!(parse(&args(&["--once=yes"])).is_err());
        assert!(parse(&args(&["--bogus"])).is_err());
        assert!(parse(&args(&["--once", "--check"])).is_err());
    }

    #[test]
    fn help_and_version_short_circuit() {
        assert!(parse(&args(&["--help", "--bogus"])).expect("help").help);
        assert!(parse(&args(&["-V"])).expect("version").version);
    }
}
