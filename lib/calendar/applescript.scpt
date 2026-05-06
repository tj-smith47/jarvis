-- Calendar.app event fetcher invoked by lib/calendar/applescript.sh.
--
-- ARGV: SINCE_ISO UNTIL_ISO CALFILTER
--   SINCE_ISO, UNTIL_ISO  ISO-8601 wall-clock ("YYYY-MM-DDTHH:MM:SSZ" or
--                          "YYYY-MM-DDTHH:MM:SS"). The trailing `Z` is
--                          ignored: components are interpreted in the local
--                          time zone (Calendar.app stores events in local
--                          wall-clock terms; this matches the existing
--                          gcalcli provider's local-naive output convention
--                          and the ICS provider's HH:MM-only render in brief.sh).
--   CALFILTER             "" for all visible calendars, or a comma-list of
--                          calendar names ("Work,Personal").
--
-- STDOUT: tab-separated lines, one per event:
--   START_ISO \t END_ISO \t TITLE \t URL \t LOCATION \n
--   Tabs/newlines inside any field are collapsed to spaces before emit so
--   the bash awk consumer can rely on the column count.
--
-- Sources:
--   * Apple Calendar Scripting Guide — Locating an Event
--     https://developer.apple.com/library/archive/documentation/AppleApplications/Conceptual/CalendarScriptingGuide/Calendar-LocateanEvent.html
--   * MacScripter — events over a date range
--     https://www.macscripter.net/t/applescript-to-create-list-of-events-over-a-specified-date-range/66307
--   * Lean Crew — AppleSloth (`whose` performance caveat; OK for day windows)
--     https://leancrew.com/all-this/2020/03/applesloth/
--
-- Known limitation: recurring events. AppleScript's `every event whose start
-- date >= X` evaluates against the *original* event date, not expanded
-- recurrence instances. Daily/weekly events created in the past whose first
-- instance falls outside [since, until) will not appear. Workaround: rely on
-- a calendar source that materializes recurrences (gcalcli/ics from a feed
-- where the upstream has expanded), or extend this provider via EventKit
-- (Cocoa) in a follow-up. Documented in .claude/smoke/mac-calendar.md.

on run argv
    if (count of argv) < 3 then
        return ""
    end if
    set sinceISO to item 1 of argv
    set untilISO to item 2 of argv
    set calFilter to item 3 of argv

    set sinceDate to my isoToDate(sinceISO)
    set untilDate to my isoToDate(untilISO)

    set out to ""
    tell application "Calendar"
        if calFilter is "" then
            set cals to every calendar
        else
            set wanted to my splitComma(calFilter)
            set cals to (every calendar whose name is in wanted)
        end if
        repeat with c in cals
            tell c
                set evs to (every event whose start date is greater than or equal to sinceDate and start date is less than untilDate)
                repeat with e in evs
                    set s to my dateToISO(start date of e)
                    set en to my dateToISO(end date of e)
                    set t to my collapseWS(summary of e as string)
                    set u to ""
                    try
                        set u to my collapseWS(url of e as string)
                    end try
                    set loc to ""
                    try
                        set loc to my collapseWS(location of e as string)
                    end try
                    set out to out & s & tab & en & tab & t & tab & u & tab & loc & linefeed
                end repeat
            end tell
        end repeat
    end tell
    return out
end run

-- isoToDate "YYYY-MM-DDTHH:MM:SS[Z]" -> AppleScript date in local TZ.
-- The Z is intentionally ignored; see file header rationale.
on isoToDate(s)
    set y to (text 1 thru 4 of s) as integer
    set m to (text 6 thru 7 of s) as integer
    set d to (text 9 thru 10 of s) as integer
    set hh to (text 12 thru 13 of s) as integer
    set mm to (text 15 thru 16 of s) as integer
    set ss to (text 18 thru 19 of s) as integer
    set dt to current date
    -- Set day to 1 first so subsequent month/year writes never overflow
    -- into the next month (e.g. setting month to Feb when day is 31).
    set day of dt to 1
    set year of dt to y
    set month of dt to m
    set day of dt to d
    set time of dt to (hh * 3600) + (mm * 60) + ss
    return dt
end isoToDate

on dateToISO(dt)
    set y to year of dt
    set m to (month of dt) as integer
    set d to day of dt
    set hh to hours of dt
    set mm to minutes of dt
    set ss to seconds of dt
    return my pad(y, 4) & "-" & my pad(m, 2) & "-" & my pad(d, 2) & "T" & my pad(hh, 2) & ":" & my pad(mm, 2) & ":" & my pad(ss, 2)
end dateToISO

on pad(n, w)
    set s to n as string
    repeat while (length of s) < w
        set s to "0" & s
    end repeat
    return s
end pad

-- splitComma "Work,Personal" -> {"Work", "Personal"}; trims surrounding spaces.
on splitComma(s)
    set AppleScript's text item delimiters to ","
    set parts to text items of s
    set AppleScript's text item delimiters to ""
    set out to {}
    repeat with p in parts
        set t to my trim(p as string)
        if t is not "" then set end of out to t
    end repeat
    return out
end splitComma

on trim(s)
    set s to s as string
    repeat while s starts with " "
        set s to text 2 thru -1 of s
    end repeat
    repeat while s ends with " "
        if (length of s) ≤ 1 then return ""
        set s to text 1 thru -2 of s
    end repeat
    return s
end trim

-- collapseWS replaces tab/CR/LF with single spaces so the TSV invariant holds.
on collapseWS(s)
    set s to s as string
    set AppleScript's text item delimiters to {tab, return, linefeed, character id 13}
    set parts to text items of s
    set AppleScript's text item delimiters to " "
    set joined to parts as string
    set AppleScript's text item delimiters to ""
    return joined
end collapseWS
