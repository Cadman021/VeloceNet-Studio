//! Minimal SIGINT/SIGTERM/SIGHUP handling without a signal-handling crate.

use std::sync::atomic::{AtomicBool, Ordering};

static SHUTDOWN: AtomicBool = AtomicBool::new(false);
static RELOAD: AtomicBool = AtomicBool::new(false);

pub fn shutdown_requested() -> bool {
    SHUTDOWN.load(Ordering::Relaxed)
}

/// Used by the Windows service control handler, which is the service-side
/// equivalent of Ctrl+C.
pub fn request_shutdown() {
    SHUTDOWN.store(true, Ordering::Relaxed);
}

/// True once since the last call: SIGHUP is level-triggered by the kernel but
/// the daemon wants to act on it exactly once.
pub fn take_reload_request() -> bool {
    RELOAD.swap(false, Ordering::Relaxed)
}

/// SIGHUP (reload) exists on Unix only. Windows has no equivalent signal, so
/// the daemon there needs a restart.
pub const RELOAD_SUPPORTED: bool = cfg!(unix);

#[cfg(unix)]
mod platform {
    use super::{RELOAD, SHUTDOWN};
    use std::sync::atomic::Ordering;

    extern "C" fn handle(_signal: libc::c_int) {
        SHUTDOWN.store(true, Ordering::Relaxed);
    }

    extern "C" fn handle_reload(_signal: libc::c_int) {
        // Only sets a flag: the daemon loop re-reads the file, so the handler
        // itself stays async-signal-safe.
        RELOAD.store(true, Ordering::Relaxed);
    }

    pub fn install() -> Result<(), String> {
        let mut failed = false;
        for signal in [libc::SIGINT, libc::SIGTERM] {
            let previous = unsafe { libc::signal(signal, handle as libc::sighandler_t) };
            if previous == libc::SIG_ERR {
                failed = true;
            }
        }
        let reload = unsafe { libc::signal(libc::SIGHUP, handle_reload as libc::sighandler_t) };
        if reload == libc::SIG_ERR {
            failed = true;
        }
        if failed {
            Err("could not install SIGINT/SIGTERM/SIGHUP handlers".to_string())
        } else {
            Ok(())
        }
    }
}

#[cfg(windows)]
mod platform {
    use super::SHUTDOWN;
    use std::sync::atomic::Ordering;
    use windows_sys::core::BOOL;
    use windows_sys::Win32::Foundation::TRUE;
    use windows_sys::Win32::System::Console::SetConsoleCtrlHandler;

    unsafe extern "system" fn handle(_control: u32) -> BOOL {
        SHUTDOWN.store(true, Ordering::Relaxed);
        TRUE
    }

    pub fn install() -> Result<(), String> {
        let installed = unsafe { SetConsoleCtrlHandler(Some(handle), 1) };
        if installed == 0 {
            Err("could not install the Windows console control handler".to_string())
        } else {
            Ok(())
        }
    }
}

#[cfg(not(any(unix, windows)))]
mod platform {
    pub fn install() -> Result<(), String> {
        Ok(())
    }
}

pub use platform::install;
