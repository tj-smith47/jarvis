// ICS (RFC 5545) → Event iterator.
//
// What we handle:
//   - CRLF line unfolding (§3.1: a line beginning with SP/HTAB continues
//     the previous logical line).
//   - VEVENT blocks (BEGIN:VEVENT ... END:VEVENT).
//   - DTSTART / DTEND / SUMMARY / URL properties with arbitrary
//     parameters (`NAME[;PARAM=VAL[;PARAM=VAL]]:VALUE`).
//   - Three datetime forms:
//       * `YYYYMMDDTHHMMSSZ`           — UTC; passes through.
//       * `YYYYMMDDTHHMMSS` + `TZID=…` — local-in-named-tz; converted to UTC
//         via chrono-tz. Drains known-bug T4-W2 (the bash awk parser
//         dropped these with a stderr warning).
//       * `YYYYMMDD` (date only)       — all-day; midnight UTC of that date.
//   - Naked datetimes with no TZID and no Z get a stderr warning and the
//     event is dropped (same as the bash parser — we won't second-guess).
//
// What we don't handle yet (deferred per plan; bash didn't either):
//   - RRULE expansion within the [since,until) window. Single-occurrence
//     events are emitted as-is. Recurring-event support is a follow-up.
//   - EXDATE exclusion. Same as RRULE.
//
// Properties are matched with anchored prefixes (`NAME:` or `NAME;`) so
// `URLISH:` doesn't collide with `URL:` (matches the bash anchored regex).

use crate::ndjson::Event;
use crate::time::{format_utc, parse_ics_basic};
use chrono::{TimeZone, Utc};
use chrono_tz::Tz;

pub fn parse(input: &str) -> Box<dyn Iterator<Item = Event>> {
    let unfolded = unfold(input);
    let events = parse_vevents(&unfolded);
    Box::new(events.into_iter())
}

/// RFC 5545 §3.1 line unfolding.
fn unfold(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for line in input.lines() {
        // Strip a trailing CR if the input was CRLF-flavoured.
        let line = line.strip_suffix('\r').unwrap_or(line);
        if let Some(rest) = line.strip_prefix(' ').or_else(|| line.strip_prefix('\t')) {
            out.push_str(rest);
        } else {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(line);
        }
    }
    out
}

#[derive(Default)]
struct PendingEvent {
    dtstart: String,
    dtstart_tzid: Option<String>,
    dtend: String,
    dtend_tzid: Option<String>,
    summary: String,
    url: String,
}

fn parse_vevents(input: &str) -> Vec<Event> {
    let mut events = Vec::new();
    let mut pending: Option<PendingEvent> = None;

    for line in input.lines() {
        if line.starts_with("BEGIN:VEVENT") {
            pending = Some(PendingEvent::default());
            continue;
        }
        if line.starts_with("END:VEVENT") {
            if let Some(ev) = pending.take().and_then(finalise) {
                events.push(ev);
            }
            continue;
        }
        let Some(p) = pending.as_mut() else { continue; };

        if let Some((value, tzid)) = match_prop(line, "DTSTART") {
            p.dtstart = value;
            p.dtstart_tzid = tzid;
        } else if let Some((value, tzid)) = match_prop(line, "DTEND") {
            p.dtend = value;
            p.dtend_tzid = tzid;
        } else if let Some((value, _)) = match_prop(line, "SUMMARY") {
            p.summary = decode_text(&value);
        } else if let Some((value, _)) = match_prop(line, "URL") {
            // URL values are not RFC 5545 TEXT (no \n / \, escapes); pass through.
            p.url = value;
        }
    }
    events
}

/// If `line` matches `NAME:` or `NAME;...:`, return (value, Some(TZID) or None).
fn match_prop(line: &str, name: &str) -> Option<(String, Option<String>)> {
    let after_name = line.strip_prefix(name)?;
    // Discriminate: `NAME:` (no params) vs `NAME;...:` (params) vs `NAMEX...` (false match).
    let next = after_name.chars().next()?;
    if next != ':' && next != ';' {
        return None;
    }
    // Locate the unescaped `:` that ends the params block.
    let colon = after_name.find(':')?;
    let params = &after_name[..colon];
    let value = &after_name[colon + 1..];
    let tzid = extract_tzid(params);
    Some((value.to_string(), tzid))
}

fn extract_tzid(params: &str) -> Option<String> {
    // params looks like ";VALUE=DATE;TZID=America/Los_Angeles" or "".
    for part in params.split(';') {
        if let Some(rest) = part.strip_prefix("TZID=") {
            return Some(rest.to_string());
        }
    }
    None
}

/// Decode RFC 5545 TEXT escapes used in SUMMARY: `\n`, `\,`, `\;`, `\\`.
fn decode_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') | Some('N') => out.push('\n'),
                Some(',') => out.push(','),
                Some(';') => out.push(';'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    // Unknown escape — preserve verbatim.
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn finalise(p: PendingEvent) -> Option<Event> {
    let start_iso = resolve(&p.dtstart, p.dtstart_tzid.as_deref())?;
    // DTEND is optional in RFC 5545; if absent, mirror DTSTART.
    let end_iso = if p.dtend.is_empty() {
        start_iso.clone()
    } else {
        resolve(&p.dtend, p.dtend_tzid.as_deref()).unwrap_or_else(|| start_iso.clone())
    };
    Some(Event {
        start: start_iso,
        end: end_iso,
        title: p.summary,
        url: p.url,
    })
}

/// Convert a raw ICS datetime + optional TZID into UTC ISO 8601.
/// Returns None for naked-local timestamps with no TZID (with stderr warning).
fn resolve(raw: &str, tzid: Option<&str>) -> Option<String> {
    // UTC form: trailing Z.
    if let Some(stripped) = raw.strip_suffix('Z') {
        let ndt = parse_ics_basic(stripped)?;
        return Some(format_utc(Utc.from_utc_datetime(&ndt)));
    }
    // All-day form: 8 chars, no T.
    if raw.len() == 8 {
        let ndt = parse_ics_basic(raw)?;
        return Some(format_utc(Utc.from_utc_datetime(&ndt)));
    }
    // Local-in-tz form.
    if let Some(tz_name) = tzid {
        let tz: Tz = match tz_name.parse() {
            Ok(t) => t,
            Err(_) => {
                eprintln!("jarvis-cal: ICS unknown TZID {tz_name:?} (event dropped)");
                return None;
            }
        };
        let ndt = parse_ics_basic(raw)?;
        let local = match tz.from_local_datetime(&ndt) {
            chrono::LocalResult::Single(dt) => dt,
            chrono::LocalResult::Ambiguous(dt, _) => dt, // earlier of the two
            chrono::LocalResult::None => {
                eprintln!("jarvis-cal: ICS DTSTART {raw} invalid in TZID {tz_name} (event dropped)");
                return None;
            }
        };
        return Some(format_utc(local.with_timezone(&Utc)));
    }
    // Naked local with no TZID — same behaviour as the bash awk parser.
    eprintln!("jarvis-cal: ICS skipping event with non-UTC, non-TZID DTSTART ({raw})");
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(s: &str) -> Vec<Event> {
        parse(s).collect()
    }

    #[test]
    fn parses_a_minimal_utc_event() {
        let ics = "\
BEGIN:VCALENDAR\r\n\
BEGIN:VEVENT\r\n\
DTSTART:20260428T140000Z\r\n\
DTEND:20260428T150000Z\r\n\
SUMMARY:Standup\r\n\
URL:https://meet.example/abc\r\n\
END:VEVENT\r\n\
END:VCALENDAR\r\n";
        let events = collect(ics);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].start, "2026-04-28T14:00:00Z");
        assert_eq!(events[0].end, "2026-04-28T15:00:00Z");
        assert_eq!(events[0].title, "Standup");
        assert_eq!(events[0].url, "https://meet.example/abc");
    }

    #[test]
    fn handles_tzid_via_chrono_tz() {
        let ics = "\
BEGIN:VEVENT\n\
DTSTART;TZID=America/Los_Angeles:20260428T140000\n\
DTEND;TZID=America/Los_Angeles:20260428T150000\n\
SUMMARY:LA meeting\n\
END:VEVENT\n";
        let events = collect(ics);
        assert_eq!(events.len(), 1);
        // April 28 2026 14:00 PDT = 21:00 UTC.
        assert_eq!(events[0].start, "2026-04-28T21:00:00Z");
        assert_eq!(events[0].end, "2026-04-28T22:00:00Z");
    }

    #[test]
    fn drops_naked_local_with_warning() {
        let ics = "\
BEGIN:VEVENT\n\
DTSTART:20260428T140000\n\
SUMMARY:floating\n\
END:VEVENT\n";
        assert!(collect(ics).is_empty());
    }

    #[test]
    fn handles_all_day() {
        let ics = "\
BEGIN:VEVENT\n\
DTSTART;VALUE=DATE:20260428\n\
SUMMARY:Holiday\n\
END:VEVENT\n";
        let events = collect(ics);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].start, "2026-04-28T00:00:00Z");
    }

    #[test]
    fn unfolds_continuation_lines() {
        let ics = "\
BEGIN:VEVENT\n\
DTSTART:20260428T140000Z\n\
SUMMARY:Long title that\n  continues here\n\
END:VEVENT\n";
        let events = collect(ics);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].title, "Long title that continues here");
    }

    #[test]
    fn decodes_text_escapes() {
        let ics = "\
BEGIN:VEVENT\n\
DTSTART:20260428T140000Z\n\
SUMMARY:Line1\\nLine2 with \\, comma and \\; semicolon\n\
END:VEVENT\n";
        let events = collect(ics);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].title, "Line1\nLine2 with , comma and ; semicolon");
    }

    #[test]
    fn property_name_anchored_avoids_url_ish() {
        let ics = "\
BEGIN:VEVENT\n\
DTSTART:20260428T140000Z\n\
SUMMARY:T\n\
URLISH:not-a-url\n\
URL:https://real.example\n\
END:VEVENT\n";
        let events = collect(ics);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].url, "https://real.example");
    }

    #[test]
    fn missing_dtend_mirrors_dtstart() {
        let ics = "\
BEGIN:VEVENT\n\
DTSTART:20260428T140000Z\n\
SUMMARY:NoEnd\n\
END:VEVENT\n";
        let events = collect(ics);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].start, events[0].end);
    }
}
