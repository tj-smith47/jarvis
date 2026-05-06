// NDJSON event emit + window check.
//
// `Event` carries the canonical 4-field shape. `write_event` serializes via
// serde_json with `preserve_order` (the dependency feature flag pulled in
// from Cargo.toml), then appends a single `\n`. serde_json's default escape
// rules match Python's json.dumps(ensure_ascii=False, separators=(",",":"))
// for the value space we accept.

use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};
use serde::Serialize;
use std::io::{self, Write};

/// Canonical 4-field calendar event.
///
/// All fields are owned `String` so the same struct can be populated from
/// `&str` (zero-copy) inputs via `.to_string()` or built lazily.
#[derive(Debug, Serialize)]
pub struct Event {
    pub start: String,
    pub end: String,
    pub title: String,
    pub url: String,
}

impl Event {
    /// Drop events whose `start` falls outside `[since, until)`.
    ///
    /// `start` may be any ISO 8601 string this binary produced — empty
    /// strings (degenerate; our parsers should never emit them) are
    /// treated as out-of-window.
    pub fn in_window(&self, since: DateTime<Utc>, until: DateTime<Utc>) -> bool {
        // Strict UTC form (`...Z` or `...+HH:MM`) — preferred path.
        if let Ok(t) = crate::time::parse_iso_utc(&self.start) {
            return t >= since && t < until;
        }
        // Naive ISO form (`YYYY-MM-DDTHH:MM:SS` from gcalcli TSV which is
        // already-windowed upstream by gcalcli itself). Treat as UTC for
        // comparison purposes; gcalcli's tz semantics are an upstream
        // contract this binary doesn't second-guess.
        if let Ok(ndt) = NaiveDateTime::parse_from_str(&self.start, "%Y-%m-%dT%H:%M:%S") {
            let t = Utc.from_utc_datetime(&ndt);
            return t >= since && t < until;
        }
        false
    }
}

/// Write one event as a single canonical NDJSON line + `\n` terminator.
pub fn write_event<W: Write>(out: &mut W, ev: &Event) -> io::Result<()> {
    serde_json::to_writer(&mut *out, ev)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    out.write_all(b"\n")?;
    Ok(())
}
