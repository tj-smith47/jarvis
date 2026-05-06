// gcalcli TSV → Event iterator.
//
// Input format (gcalcli >=4.x `agenda --tsv`):
//   start_date \t start_time \t end_date \t end_time \t link \t title
//
// Wholly trivial parsing — split on \t, reject rows with <6 fields, glue
// `<date>T<time>:00` for both ends. Empty rows are skipped silently
// (matches the awk parser's NF >= 6 guard).
//
// Tabs embedded in titles/URLs are unhandled (gcalcli is assumed to
// sanitise) — same constraint the bash awk parser carried.

use crate::ndjson::Event;

pub fn parse(input: &str) -> Box<dyn Iterator<Item = Event>> {
    // Collect to Vec so we don't borrow `input` past return.
    let events: Vec<Event> = input
        .lines()
        .filter_map(parse_row)
        .collect();
    Box::new(events.into_iter())
}

fn parse_row(line: &str) -> Option<Event> {
    let fields: Vec<&str> = line.split('\t').collect();
    if fields.len() < 6 {
        return None;
    }
    let start_date = fields[0];
    let start_time = fields[1];
    let end_date = fields[2];
    let end_time = fields[3];
    let url = fields[4];
    let title = fields[5];

    Some(Event {
        start: format!("{start_date}T{start_time}:00"),
        end: format!("{end_date}T{end_time}:00"),
        title: title.to_string(),
        url: url.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_basic_row() {
        let tsv = "2026-04-28\t14:00\t2026-04-28\t15:00\thttps://meet.example/abc\tStandup\n";
        let events: Vec<Event> = parse(tsv).collect();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].start, "2026-04-28T14:00:00");
        assert_eq!(events[0].end, "2026-04-28T15:00:00");
        assert_eq!(events[0].title, "Standup");
        assert_eq!(events[0].url, "https://meet.example/abc");
    }

    #[test]
    fn skips_short_rows() {
        let tsv = "incomplete\trow\twith\nthree\tfields\n";
        let events: Vec<Event> = parse(tsv).collect();
        assert!(events.is_empty());
    }

    #[test]
    fn empty_input_yields_no_events() {
        let events: Vec<Event> = parse("").collect();
        assert!(events.is_empty());
    }
}
