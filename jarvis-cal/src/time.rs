// Strict UTC ISO 8601 parsing for window bounds + event timestamps.
//
// We accept the same shapes the bash codebase emits:
//   YYYY-MM-DDTHH:MM:SSZ
//   YYYY-MM-DDTHH:MM:SS+HH:MM
//   YYYY-MM-DDTHH:MM:SS-HH:MM
//
// And the ICS-flavoured basic format:
//   YYYYMMDDTHHMMSSZ
//
// The bash parsers never emitted offset variants (they always wrote `Z`),
// but accepting offsets here lets the binary normalise gcalcli's local
// times into UTC and forward the result through the same window check.

use anyhow::{anyhow, Result};
use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};

/// Parse a UTC ISO 8601 timestamp. Trailing `Z` is required for ISO long
/// form; ICS basic form is accepted iff it ends in `Z`.
pub fn parse_iso_utc(s: &str) -> Result<DateTime<Utc>> {
    let s = s.trim();

    // ICS basic form: YYYYMMDDTHHMMSSZ
    if let Some(ndt) = parse_ics_basic_utc(s) {
        return Ok(Utc.from_utc_datetime(&ndt));
    }

    // ISO long form via chrono's RFC 3339 parser.
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Ok(dt.with_timezone(&Utc));
    }

    Err(anyhow!("not a recognised UTC ISO 8601 timestamp: {s:?}"))
}

/// Parse `YYYYMMDD` or `YYYYMMDDTHHMMSS` (no Z, no separators).
/// Returns the naive datetime so callers can attach a tz.
pub fn parse_ics_basic(s: &str) -> Option<NaiveDateTime> {
    if s.len() == 8 {
        return parse_ymd(s).map(|d| d.and_hms_opt(0, 0, 0)).flatten();
    }
    if s.len() == 15 && s.as_bytes().get(8) == Some(&b'T') {
        let date = parse_ymd(&s[..8])?;
        let time = parse_hms(&s[9..])?;
        return Some(date.and_time(time));
    }
    None
}

fn parse_ics_basic_utc(s: &str) -> Option<NaiveDateTime> {
    s.strip_suffix('Z').and_then(parse_ics_basic)
}

fn parse_ymd(s: &str) -> Option<NaiveDate> {
    if s.len() != 8 || !s.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let y: i32 = s[0..4].parse().ok()?;
    let m: u32 = s[4..6].parse().ok()?;
    let d: u32 = s[6..8].parse().ok()?;
    NaiveDate::from_ymd_opt(y, m, d)
}

fn parse_hms(s: &str) -> Option<NaiveTime> {
    if s.len() != 6 || !s.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let h: u32 = s[0..2].parse().ok()?;
    let mi: u32 = s[2..4].parse().ok()?;
    let se: u32 = s[4..6].parse().ok()?;
    NaiveTime::from_hms_opt(h, mi, se)
}

/// Format a UTC datetime as the canonical jarvis ISO string.
pub fn format_utc(dt: DateTime<Utc>) -> String {
    dt.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_z_form() {
        let t = parse_iso_utc("2026-04-28T12:00:00Z").unwrap();
        assert_eq!(format_utc(t), "2026-04-28T12:00:00Z");
    }

    #[test]
    fn parses_offset_form() {
        let t = parse_iso_utc("2026-04-28T15:30:00+05:00").unwrap();
        assert_eq!(format_utc(t), "2026-04-28T10:30:00Z");
    }

    #[test]
    fn parses_ics_basic_z() {
        let t = parse_iso_utc("20260428T120000Z").unwrap();
        assert_eq!(format_utc(t), "2026-04-28T12:00:00Z");
    }

    #[test]
    fn rejects_naked_local() {
        assert!(parse_iso_utc("2026-04-28T12:00:00").is_err());
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_iso_utc("frobnicate").is_err());
        assert!(parse_iso_utc("").is_err());
    }
}
