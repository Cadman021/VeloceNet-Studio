//! Tiny ANSI styling layer for the human-readable CLI output.
//!
//! The machine formats (NDJSON, JSON snapshots) never contain escape codes.
//! Colours are resolved once at startup: `auto` follows the terminal and
//! honours `NO_COLOR`, while `always` is useful for CI logs and demos.

use std::io::IsTerminal;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorMode {
    Auto,
    Always,
    Never,
}

impl ColorMode {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "auto" => Some(Self::Auto),
            "always" | "yes" | "on" => Some(Self::Always),
            "never" | "no" | "off" => Some(Self::Never),
            _ => None,
        }
    }
}

static STDOUT_COLOR: AtomicBool = AtomicBool::new(false);
static STDERR_COLOR: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Copy)]
pub struct Style {
    enabled: bool,
}

impl Style {
    #[cfg(test)]
    pub fn plain() -> Self {
        Self { enabled: false }
    }

    #[cfg(test)]
    pub fn colored() -> Self {
        Self { enabled: true }
    }

    pub fn paint(self, code: &str, text: &str) -> String {
        if self.enabled {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }

    pub fn bold(self, text: &str) -> String {
        self.paint("1", text)
    }

    pub fn dim(self, text: &str) -> String {
        self.paint("2", text)
    }

    pub fn green(self, text: &str) -> String {
        self.paint("32", text)
    }

    pub fn yellow(self, text: &str) -> String {
        self.paint("33", text)
    }

    pub fn red(self, text: &str) -> String {
        self.paint("31", text)
    }

    pub fn cyan(self, text: &str) -> String {
        self.paint("36", text)
    }
}

#[derive(Debug, Clone, Copy)]
enum Stream {
    Stdout,
    Stderr,
}

pub fn init(mode: ColorMode) {
    let no_color = std::env::var_os("NO_COLOR").is_some();
    let dumb_term = std::env::var("TERM")
        .map(|term| term.eq_ignore_ascii_case("dumb"))
        .unwrap_or(false);
    let auto_allowed = !no_color && !dumb_term;

    let mut stdout_color = choose(mode, std::io::stdout().is_terminal(), auto_allowed);
    let mut stderr_color = choose(mode, std::io::stderr().is_terminal(), auto_allowed);

    // A redirected stream is not a console: do not try to toggle its mode.
    if stdout_color && std::io::stdout().is_terminal() && !prepare_console(Stream::Stdout) {
        stdout_color = false;
    }
    if stderr_color && std::io::stderr().is_terminal() && !prepare_console(Stream::Stderr) {
        stderr_color = false;
    }

    STDOUT_COLOR.store(stdout_color, Ordering::Relaxed);
    STDERR_COLOR.store(stderr_color, Ordering::Relaxed);
}

fn choose(mode: ColorMode, is_terminal: bool, auto_allowed: bool) -> bool {
    match mode {
        ColorMode::Always => true,
        ColorMode::Never => false,
        ColorMode::Auto => is_terminal && auto_allowed,
    }
}

pub fn stdout_style() -> Style {
    Style {
        enabled: STDOUT_COLOR.load(Ordering::Relaxed),
    }
}

pub fn stderr_style() -> Style {
    Style {
        enabled: STDERR_COLOR.load(Ordering::Relaxed),
    }
}

#[cfg(windows)]
fn prepare_console(stream: Stream) -> bool {
    use windows_sys::Win32::System::Console::{
        GetConsoleMode, GetStdHandle, SetConsoleMode, ENABLE_VIRTUAL_TERMINAL_PROCESSING,
        STD_ERROR_HANDLE, STD_OUTPUT_HANDLE,
    };

    let handle = match stream {
        Stream::Stdout => unsafe { GetStdHandle(STD_OUTPUT_HANDLE) },
        Stream::Stderr => unsafe { GetStdHandle(STD_ERROR_HANDLE) },
    };
    let mut mode = 0u32;
    let got_mode = unsafe { GetConsoleMode(handle, &mut mode) };
    if got_mode == 0 {
        return false;
    }
    unsafe { SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0 }
}

#[cfg(not(windows))]
fn prepare_console(_stream: Stream) -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_color_modes() {
        assert_eq!(ColorMode::parse("AUTO"), Some(ColorMode::Auto));
        assert_eq!(ColorMode::parse(" always "), Some(ColorMode::Always));
        assert_eq!(ColorMode::parse("off"), Some(ColorMode::Never));
        assert_eq!(ColorMode::parse("rainbow"), None);
    }

    #[test]
    fn styles_wrap_text_only_when_enabled() {
        let plain = Style::plain();
        assert_eq!(plain.green("ONLINE"), "ONLINE");
        assert_eq!(plain.bold("title"), "title");

        let color = Style { enabled: true };
        assert_eq!(color.green("ONLINE"), "\x1b[32mONLINE\x1b[0m");
        assert_eq!(color.bold("title"), "\x1b[1mtitle\x1b[0m");
    }
}
