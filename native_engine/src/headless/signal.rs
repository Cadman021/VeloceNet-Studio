//! Minimal SIGINT/SIGTERM handling without a signal-handling crate.

use std::sync::atomic::{AtomicBool, Ordering};

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

pub fn shutdown_requested() -> bool {
    SHUTDOWN.load(Ordering::Relaxed)
}

#[cfg(unix)]
mod platform {
    use super::SHUTDOWN;
    use std::sync::atomic::Ordering;

    extern "C" fn handle(_signal: libc::c_int) {
        SHUTDOWN.store(true, Ordering::Relaxed);
    }

    pub fn install() -> Result<(), String> {
        let mut failed = false;
        for signal in [libc::SIGINT, libc::SIGTERM] {
            let previous = unsafe { libc::signal(signal, handle as libc::sighandler_t) };
            if previous == libc::SIG_ERR {
                failed = true;
            }
        }
        if failed {
            Err("could not install SIGINT/SIGTERM handlers".to_string())
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
