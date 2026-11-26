//! Standalone daemon entry point; all logic lives in the library so it can
//! be unit tested without launching the binary.

fn main() {
    std::process::exit(netstudio_engine::headless::main_entry());
}
