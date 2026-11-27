//! Windows Service Control Manager (SCM) integration.
//!
//! A service must hand control to `StartServiceCtrlDispatcherW` before it
//! does any work; SCM then calls our service main on its own thread, and the
//! dispatcher returns once the service stops. Reporting `SERVICE_RUNNING`
//! only after the daemon has validated its config, bound its listener and
//! claimed its pid file is what makes `sc.exe start` a meaningful health
//! signal instead of "a process was created".
//!
//! The control handler does no work: it sets the same shutdown flag Ctrl+C
//! sets, so stopping a service follows the graceful path (probes cancelled,
//! listener closed, pid file removed) with no service-specific code.

use std::ffi::c_void;
use std::sync::atomic::{AtomicI32, AtomicIsize, AtomicU32, Ordering};
use std::sync::{Mutex, OnceLock};

use windows_sys::Win32::Foundation::ERROR_SERVICE_SPECIFIC_ERROR;
use windows_sys::Win32::System::Services::{
    RegisterServiceCtrlHandlerExW, SetServiceStatus, StartServiceCtrlDispatcherW,
    SERVICE_ACCEPT_SHUTDOWN, SERVICE_ACCEPT_STOP, SERVICE_CONTROL_INTERROGATE,
    SERVICE_CONTROL_SHUTDOWN, SERVICE_CONTROL_STOP, SERVICE_RUNNING, SERVICE_START_PENDING,
    SERVICE_STATUS, SERVICE_STATUS_CURRENT_STATE, SERVICE_STATUS_HANDLE, SERVICE_STOPPED,
    SERVICE_STOP_PENDING, SERVICE_TABLE_ENTRYW, SERVICE_WIN32_OWN_PROCESS,
};

use super::{cli, log, signal, EXIT_CONFIG};

/// Must match the service name `sc.exe`/`New-Service` registers, because SCM
/// looks up our entry by name in the dispatcher table.
pub const SERVICE_NAME: &str = "netstudio-headless";

static STATUS_HANDLE: AtomicIsize = AtomicIsize::new(0);
static CURRENT_STATE: AtomicU32 = AtomicU32::new(SERVICE_START_PENDING);
static EXIT_CODE: AtomicI32 = AtomicI32::new(0);

fn pending() -> &'static Mutex<Option<cli::Cli>> {
    static PENDING: OnceLock<Mutex<Option<cli::Cli>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(None))
}

fn lock<T>(mutex: &'static Mutex<T>) -> std::sync::MutexGuard<'static, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

/// Hands the process to SCM and returns the daemon's exit code.
pub fn run(cli: cli::Cli) -> i32 {
    *lock(pending()) = Some(cli);
    let name = wide(SERVICE_NAME);
    let table = [
        SERVICE_TABLE_ENTRYW {
            lpServiceName: name.as_ptr() as *mut u16,
            lpServiceProc: Some(service_main),
        },
        SERVICE_TABLE_ENTRYW {
            lpServiceName: std::ptr::null_mut(),
            lpServiceProc: None,
        },
    ];
    let dispatched = unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) };
    if dispatched == 0 {
        let error = std::io::Error::last_os_error();
        log::error(format!(
            "cannot run as a Windows service: {error}; start it with `sc.exe start {SERVICE_NAME}` (or via tool/install-headless-service.ps1) instead of from a shell"
        ));
        return EXIT_CONFIG;
    }
    EXIT_CODE.load(Ordering::Relaxed)
}

/// Called once the daemon is actually serving, so SCM does not report a
/// service as running while its config is still being validated.
pub fn mark_running() {
    if STATUS_HANDLE.load(Ordering::Relaxed) != 0 {
        report(SERVICE_RUNNING, 0);
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe extern "system" fn service_main(_argc: u32, _argv: *mut *mut u16) {
    let name = wide(SERVICE_NAME);
    let handle = RegisterServiceCtrlHandlerExW(name.as_ptr(), Some(control), std::ptr::null_mut());
    if handle.is_null() {
        return;
    }
    STATUS_HANDLE.store(handle as isize, Ordering::Relaxed);
    report(SERVICE_START_PENDING, 0);
    let Some(cli) = lock(pending()).take() else {
        EXIT_CODE.store(EXIT_CONFIG, Ordering::Relaxed);
        report(SERVICE_STOPPED, EXIT_CONFIG as u32);
        return;
    };
    let code = super::run(cli);
    EXIT_CODE.store(code, Ordering::Relaxed);
    report(SERVICE_STOPPED, code as u32);
}

/// SCM thread: keep it to an atomic store, exactly like a signal handler.
unsafe extern "system" fn control(
    control: u32,
    _event_type: u32,
    _event_data: *mut c_void,
    _context: *mut c_void,
) -> u32 {
    if control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN {
        report(SERVICE_STOP_PENDING, 0);
        signal::request_shutdown();
    } else if control == SERVICE_CONTROL_INTERROGATE {
        report(CURRENT_STATE.load(Ordering::Relaxed), 0);
    }
    0
}

fn report(state: SERVICE_STATUS_CURRENT_STATE, exit_code: u32) {
    CURRENT_STATE.store(state, Ordering::Relaxed);
    let handle = STATUS_HANDLE.load(Ordering::Relaxed) as SERVICE_STATUS_HANDLE;
    if handle.is_null() {
        return;
    }
    let accepting = if state == SERVICE_RUNNING {
        SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
    } else {
        0
    };
    let pending = state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING;
    // A non-zero code goes in the service-specific slot (1066 + code), the
    // only way SCM reports our exit status instead of treating the number as
    // a Win32 error such as "path not found".
    let (win32_code, specific) = if exit_code == 0 {
        (0, 0)
    } else {
        (ERROR_SERVICE_SPECIFIC_ERROR, exit_code)
    };
    let status = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: state,
        dwControlsAccepted: accepting,
        dwWin32ExitCode: win32_code,
        dwServiceSpecificExitCode: specific,
        dwCheckPoint: 0,
        dwWaitHint: if pending { 10_000 } else { 0 },
    };
    unsafe { SetServiceStatus(handle, &status) };
}
