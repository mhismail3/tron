//! Isolated JavaScript program worker process.
//!
//! The parent Tron process owns engine authority. This process receives one
//! bounded program request over stdin/stdout JSON lines, runs QuickJS, and asks
//! the parent for every `tools.search`/`tools.inspect`/`tools.execute` host
//! call.

fn main() -> std::process::ExitCode {
    tron::domains::program::worker_process_main()
}
