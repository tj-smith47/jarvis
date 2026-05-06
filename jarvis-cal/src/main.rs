// jarvis-cal — ICS + gcalcli TSV → unified NDJSON event stream.
//
// Replaces the awk-based parsers in lib/calendar/{ics,gcalcli}.sh with a
// single Rust binary that:
//   - reads bytes on stdin (so callers stream via curl|gcalcli|cat),
//   - emits one canonical JSON object per line on stdout,
//   - escapes control characters per RFC 8259 by default,
//   - exits with a stable code (0/1/2/5) on errors.
//
// The hidden `emit-fixtures-for-parity` subcommand exists so the cross-encoder
// NDJSON parity test can verify that this binary's serde_json output is
// byte-identical to the Python oracle's json.dumps output.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]

mod ndjson;
mod ics;
mod gcalcli;
mod parity;
mod time;

use clap::{Parser, Subcommand, ValueEnum};
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::ExitCode;

const PROTOCOL_VERSION: u32 = 1;

#[derive(Parser)]
#[command(
    name = "jarvis-cal",
    version,
    about = "ICS + gcalcli TSV → unified NDJSON event stream for jarvis",
    disable_version_flag = true,
)]
struct Cli {
    /// Print the protocol version and exit (consumed by lib/native/protocol.sh).
    #[arg(long)]
    protocol_version: bool,

    #[command(subcommand)]
    command: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Parse a calendar source on stdin into NDJSON {start,end,title,url}.
    Events {
        /// Input format: ics (RFC 5545) or gcalcli (TSV from `gcalcli agenda --tsv`).
        #[arg(long, value_enum)]
        format: Format,
        /// Window start (UTC ISO 8601). Events with start < this are dropped.
        #[arg(long)]
        since: String,
        /// Window end (UTC ISO 8601). Events with start >= this are dropped.
        #[arg(long)]
        until: String,
    },
    /// Hidden — emit canonical NDJSON for each input fixture (parity tests).
    #[command(hide = true, name = "emit-fixtures-for-parity")]
    EmitFixturesForParity {
        #[arg(long)]
        inputs: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },
}

#[derive(Copy, Clone, ValueEnum)]
enum Format {
    Ics,
    Gcalcli,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    if cli.protocol_version {
        println!("{PROTOCOL_VERSION}");
        return ExitCode::SUCCESS;
    }
    match cli.command {
        Some(Cmd::Events { format, since, until }) => run_events(format, &since, &until),
        Some(Cmd::EmitFixturesForParity { inputs, output }) => match parity::emit(&inputs, &output) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("jarvis-cal: emit-fixtures-for-parity: {e}");
                ExitCode::from(2)
            }
        },
        None => {
            eprintln!(
                "usage: jarvis-cal events --format ics|gcalcli --since <ISO> --until <ISO>"
            );
            ExitCode::from(2)
        }
    }
}

fn run_events(format: Format, since_s: &str, until_s: &str) -> ExitCode {
    let since = match time::parse_iso_utc(since_s) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("jarvis-cal: --since {since_s}: {e}");
            return ExitCode::from(2);
        }
    };
    let until = match time::parse_iso_utc(until_s) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("jarvis-cal: --until {until_s}: {e}");
            return ExitCode::from(2);
        }
    };
    if since >= until {
        eprintln!("jarvis-cal: --since must be < --until");
        return ExitCode::from(2);
    }

    let mut buf = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut buf) {
        eprintln!("jarvis-cal: stdin: {e}");
        return ExitCode::from(1);
    }

    let parser_iter: Box<dyn Iterator<Item = ndjson::Event>> = match format {
        Format::Ics => Box::new(ics::parse(&buf)),
        Format::Gcalcli => Box::new(gcalcli::parse(&buf)),
    };

    let stdout = io::stdout();
    let mut out = stdout.lock();
    for ev in parser_iter {
        if !ev.in_window(since, until) {
            continue;
        }
        if let Err(e) = ndjson::write_event(&mut out, &ev) {
            eprintln!("jarvis-cal: write: {e}");
            return ExitCode::from(1);
        }
    }
    ExitCode::SUCCESS
}
