#!/usr/bin/env python3
"""jarvis-when — natural-language datetime helper for the jarvis CLI.

Replaces the bilateral GNU/BSD `date -d`/`date -j` fallbacks scattered across
the bash codebase with one cross-platform parser. Pure stdlib (no pip
install, no PEP 668 friction, no C extensions). Single-file script.

Subcommands:
  parse <expr>             Print ISO 8601 UTC of <expr>.
  humanize <iso>           Print "tomorrow at 9am" / "in 2h 15m" / "23m ago".
  delta <iso-a> <iso-b>    Print "1d 4h" / "23m" (signed).
  next-occurrence <day>    Print next <weekday> 00:00:00 UTC.
  --protocol-version       Print "1\\n" and exit 0 (jarvis-state pin checker).
  --help                   Print this text.

Recognised time expressions (parse + humanize):

  Keyword:   now, today, tomorrow, yesterday
  Duration:  Ns | Nm | Nh | Nd | Nw  (s=seconds, m=minutes, h=hours,
             d=days, w=weeks)
  Relative:  "in <duration>", "<duration> ago"
  Clock:     HH:MM (24h) — today, rolls to tomorrow if past
             "tomorrow HH:MM"
  Calendar:  YYYY-MM-DD            (00:00:00 local)
             YYYY-MM-DD HH:MM      (local; trailing :SS optional)
             ISO 8601 with T       (Z = UTC; offset honoured)
  Weekday:   monday, tuesday, ...  (next occurrence at 00:00:00 local)
             "next <weekday>"      (same as bare weekday)
             "last <weekday>"      (previous occurrence)

Time source precedence (load-bearing — matches lib/native/clock.sh contract):
  1. JARVIS_TODAY  (YYYY-MM-DD; sets the "today" date, time defaults to 00:00)
  2. JARVIS_FAKE_NOW (UTC ISO 8601)
  3. system clock

Output format:
  parse, next-occurrence : YYYY-MM-DDTHH:MM:SSZ (always UTC)
  humanize               : free-form English
  delta                  : compact ("1d 4h", "23m", "5s"); negative prefix "-"

Exit codes:
  0  success
  2  validation error (unparseable input, bad subcommand)
  5  internal error
"""

from __future__ import annotations

import os
import re
import sys
from datetime import datetime, timedelta, timezone

PROTOCOL_VERSION = 1

UTC = timezone.utc

WEEKDAYS = {
    "monday": 0, "mon": 0,
    "tuesday": 1, "tue": 1, "tues": 1,
    "wednesday": 2, "wed": 2,
    "thursday": 3, "thu": 3, "thur": 3, "thurs": 3,
    "friday": 4, "fri": 4,
    "saturday": 5, "sat": 5,
    "sunday": 6, "sun": 6,
}

DURATION_UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}

DURATION_RE = re.compile(r"^\s*(\d+)\s*([smhdw])\s*$")
COMPOUND_DURATION_RE = re.compile(r"(\d+)\s*([smhdw])")
COMPOUND_GATE_RE = re.compile(r"^(?:\s*\d+\s*[smhdw])+\s*$")
HHMM_RE = re.compile(r"^([0-2][0-9]):([0-5][0-9])(?::([0-5][0-9]))?$")
DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
DATETIME_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})\s+([0-2][0-9]):([0-5][0-9])(?::([0-5][0-9]))?$")
ISO_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T([0-2][0-9]):([0-5][0-9])(?::([0-5][0-9]))?(Z|[+-]\d{2}:?\d{2})?$"
)


# ---------------------------------------------------------------------------
# Errors + clock
# ---------------------------------------------------------------------------

class ParseError(ValueError):
    """Raised when an expression cannot be parsed; mapped to exit 2."""


def _now_utc() -> datetime:
    """Effective 'now' in UTC, honouring JARVIS_TODAY then JARVIS_FAKE_NOW."""
    today = os.environ.get("JARVIS_TODAY", "").strip()
    if today:
        m = DATE_RE.match(today)
        if not m:
            raise ParseError(f"JARVIS_TODAY={today!r} is not YYYY-MM-DD")
        y, mo, d = (int(g) for g in m.groups())
        return datetime(y, mo, d, 0, 0, 0, tzinfo=UTC)

    fake = os.environ.get("JARVIS_FAKE_NOW", "").strip()
    if fake:
        try:
            return _parse_iso(fake)
        except ParseError as exc:
            raise ParseError(f"JARVIS_FAKE_NOW={fake!r}: {exc}") from None

    return datetime.now(tz=UTC).replace(microsecond=0)


def _today_local_date(now: datetime) -> tuple[int, int, int]:
    """Date components of 'today' as the user perceives it."""
    return now.year, now.month, now.day


# ---------------------------------------------------------------------------
# Format helpers
# ---------------------------------------------------------------------------

def _format_iso(dt: datetime) -> str:
    """UTC ISO 8601 with trailing Z; seconds always emitted."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    dt = dt.astimezone(UTC).replace(microsecond=0)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> datetime:
    """Parse strict ISO 8601 (with T separator); offset/Z honoured."""
    m = ISO_RE.match(s.strip())
    if not m:
        # Fall through to the looser YYYY-MM-DD HH:MM form below.
        m2 = DATETIME_RE.match(s.strip())
        if m2:
            y, mo, d, hh, mm, ss = m2.groups()
            return datetime(int(y), int(mo), int(d), int(hh), int(mm),
                            int(ss or 0), tzinfo=UTC)
        m3 = DATE_RE.match(s.strip())
        if m3:
            y, mo, d = m3.groups()
            return datetime(int(y), int(mo), int(d), tzinfo=UTC)
        raise ParseError(f"not a recognised ISO/date form: {s!r}")
    y, mo, d, hh, mm, ss, tz = m.groups()
    base = datetime(int(y), int(mo), int(d), int(hh), int(mm), int(ss or 0))
    if tz in (None, "Z"):
        return base.replace(tzinfo=UTC)
    sign = 1 if tz[0] == "+" else -1
    body = tz[1:].replace(":", "")
    off = timedelta(hours=int(body[:2]), minutes=int(body[2:4]))
    return (base - sign * off).replace(tzinfo=UTC)


# ---------------------------------------------------------------------------
# Duration parsing
# ---------------------------------------------------------------------------

def _parse_duration(s: str) -> timedelta:
    """Parse Ns|Nm|Nh|Nd|Nw, single unit OR compound ('1h30m')."""
    s = s.strip().replace(" ", "")
    if not s:
        raise ParseError("empty duration")
    m = DURATION_RE.match(s)
    if m:
        n, u = m.groups()
        return timedelta(seconds=int(n) * DURATION_UNITS[u])
    # Try compound (e.g. "1h30m", "2d4h"). Must consume the whole string.
    total = 0
    consumed = 0
    for cm in COMPOUND_DURATION_RE.finditer(s):
        if cm.start() != consumed:
            raise ParseError(f"unparsable duration: {s!r}")
        n, u = cm.groups()
        total += int(n) * DURATION_UNITS[u]
        consumed = cm.end()
    if consumed != len(s) or consumed == 0:
        raise ParseError(f"unparsable duration: {s!r}")
    return timedelta(seconds=total)


# ---------------------------------------------------------------------------
# Expression parser
# ---------------------------------------------------------------------------

def parse(expr: str, now: datetime | None = None) -> datetime:
    """Resolve an arbitrary user expression to UTC datetime.

    Always returns a tz-aware UTC datetime.
    Raises ParseError on unrecognised input.
    """
    if now is None:
        now = _now_utc()
    s = expr.strip()
    if not s:
        raise ParseError("empty expression")
    low = s.lower()

    # Keywords ---------------------------------------------------------------
    if low == "now":
        return now
    if low == "today":
        y, mo, d = _today_local_date(now)
        return datetime(y, mo, d, tzinfo=UTC)
    if low == "tomorrow":
        base = datetime(*_today_local_date(now), tzinfo=UTC) + timedelta(days=1)
        return base
    if low == "yesterday":
        base = datetime(*_today_local_date(now), tzinfo=UTC) - timedelta(days=1)
        return base

    # "tomorrow HH:MM" / "today HH:MM" / "yesterday HH:MM"
    for kw, offset in (("tomorrow ", 1), ("today ", 0), ("yesterday ", -1)):
        if low.startswith(kw):
            tail = s[len(kw):]
            mm = HHMM_RE.match(tail)
            if not mm:
                raise ParseError(f"expected HH:MM after {kw.strip()!r}, got {tail!r}")
            y, mo, d = _today_local_date(now)
            base = datetime(y, mo, d, int(mm.group(1)), int(mm.group(2)),
                            int(mm.group(3) or 0), tzinfo=UTC)
            return base + timedelta(days=offset)

    # "in <duration>" / "<duration> ago" -------------------------------------
    if low.startswith("in "):
        return now + _parse_duration(s[3:])
    if low.endswith(" ago"):
        return now - _parse_duration(s[:-4])

    # Bare duration → "in <dur>" -------------------------------------------
    if DURATION_RE.match(low) or COMPOUND_GATE_RE.match(low):
        try:
            return now + _parse_duration(low)
        except ParseError:
            pass  # fall through to other matchers

    # HH:MM (today; rolls forward if past) ----------------------------------
    mm = HHMM_RE.match(s)
    if mm:
        y, mo, d = _today_local_date(now)
        target = datetime(y, mo, d, int(mm.group(1)), int(mm.group(2)),
                          int(mm.group(3) or 0), tzinfo=UTC)
        if target <= now:
            target += timedelta(days=1)
        return target

    # ISO / calendar forms ---------------------------------------------------
    for matcher in (ISO_RE, DATETIME_RE, DATE_RE):
        if matcher.match(s):
            return _parse_iso(s)

    # Weekday: "monday", "next tuesday", "last friday" ---------------------
    parts = low.split()
    if len(parts) == 1 and parts[0] in WEEKDAYS:
        return _next_weekday(now, WEEKDAYS[parts[0]])
    if len(parts) == 2 and parts[0] in ("next", "this") and parts[1] in WEEKDAYS:
        return _next_weekday(now, WEEKDAYS[parts[1]])
    if len(parts) == 2 and parts[0] == "last" and parts[1] in WEEKDAYS:
        return _prev_weekday(now, WEEKDAYS[parts[1]])

    raise ParseError(f"unrecognised expression: {expr!r}")


def _next_weekday(now: datetime, target_dow: int) -> datetime:
    today_dow = now.weekday()
    days = (target_dow - today_dow) % 7
    if days == 0:
        days = 7
    base = datetime(*_today_local_date(now), tzinfo=UTC) + timedelta(days=days)
    return base


def _prev_weekday(now: datetime, target_dow: int) -> datetime:
    today_dow = now.weekday()
    days = (today_dow - target_dow) % 7
    if days == 0:
        days = 7
    base = datetime(*_today_local_date(now), tzinfo=UTC) - timedelta(days=days)
    return base


# ---------------------------------------------------------------------------
# Humanize / delta
# ---------------------------------------------------------------------------

def _format_duration(seconds: int) -> str:
    """Compact 'Xd Yh Zm Ws' format, dropping zero leading components."""
    if seconds == 0:
        return "0s"
    sign = "-" if seconds < 0 else ""
    seconds = abs(seconds)
    parts = []
    for unit, span in (("w", 604800), ("d", 86400), ("h", 3600), ("m", 60), ("s", 1)):
        if seconds >= span:
            n, seconds = divmod(seconds, span)
            parts.append(f"{n}{unit}")
    return sign + " ".join(parts) if parts else f"{sign}0s"


def humanize(iso: str, now: datetime | None = None) -> str:
    """Render an ISO timestamp relative to now, English-friendly."""
    if now is None:
        now = _now_utc()
    target = _parse_iso(iso)
    delta = int((target - now).total_seconds())
    if delta == 0:
        return "now"
    abs_d = abs(delta)
    if abs_d < 60:
        word = "in" if delta > 0 else ""
        suffix = "" if delta > 0 else " ago"
        return f"{word + ' ' if word else ''}{abs_d}s{suffix}".strip()
    # Same calendar day -> render time of day.
    if target.date() == now.date():
        return f"today at {target.strftime('%-H:%M').lstrip()}"
    if target.date() == (now + timedelta(days=1)).date():
        return f"tomorrow at {target.strftime('%-H:%M').lstrip()}"
    if target.date() == (now - timedelta(days=1)).date():
        return f"yesterday at {target.strftime('%-H:%M').lstrip()}"
    word = "in" if delta > 0 else ""
    suffix = "" if delta > 0 else " ago"
    return f"{word + ' ' if word else ''}{_format_duration(abs_d)}{suffix}".strip()


def delta(a: str, b: str) -> str:
    """Compact signed delta between two ISO timestamps."""
    da = _parse_iso(a)
    db = _parse_iso(b)
    return _format_duration(int((db - da).total_seconds()))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _resolve_now_or_die() -> datetime:
    try:
        return _now_utc()
    except ParseError as exc:
        print(f"jarvis-when: {exc}", file=sys.stderr)
        sys.exit(2)


def _cmd_parse(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: jarvis-when parse <expr>", file=sys.stderr)
        return 2
    now = _resolve_now_or_die()
    try:
        print(_format_iso(parse(argv[0], now=now)))
    except ParseError as exc:
        print(f"jarvis-when: {exc}", file=sys.stderr)
        return 2
    return 0


def _cmd_humanize(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: jarvis-when humanize <iso>", file=sys.stderr)
        return 2
    now = _resolve_now_or_die()
    try:
        print(humanize(argv[0], now=now))
    except ParseError as exc:
        print(f"jarvis-when: {exc}", file=sys.stderr)
        return 2
    return 0


def _cmd_delta(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: jarvis-when delta <iso-a> <iso-b>", file=sys.stderr)
        return 2
    try:
        print(delta(argv[0], argv[1]))
    except ParseError as exc:
        print(f"jarvis-when: {exc}", file=sys.stderr)
        return 2
    return 0


def _cmd_next_occurrence(argv: list[str]) -> int:
    if len(argv) != 1 or argv[0].lower() not in WEEKDAYS:
        print("usage: jarvis-when next-occurrence <weekday>", file=sys.stderr)
        return 2
    now = _resolve_now_or_die()
    print(_format_iso(_next_weekday(now, WEEKDAYS[argv[0].lower()])))
    return 0


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--protocol-version":
        print(PROTOCOL_VERSION)
        return 0

    sub = argv[0]
    rest = argv[1:]
    handler = {
        "parse": _cmd_parse,
        "humanize": _cmd_humanize,
        "delta": _cmd_delta,
        "next-occurrence": _cmd_next_occurrence,
    }.get(sub)
    if handler is None:
        print(f"jarvis-when: unknown subcommand {sub!r}", file=sys.stderr)
        return 2
    try:
        return handler(rest)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - protocol code 5 catch-all
        print(f"jarvis-when: internal error: {exc!r}", file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
