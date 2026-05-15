#!/usr/bin/env bash
# shellcheck disable=SC2154  # priority/url/token/webhook/to/from/transport/subject_prefix set dynamically by _prompt via printf -v
# notify configure <channel> — prompt for channel-specific values and
# write the resulting `[notify.<channel>]` block to the active profile's
# config.toml. Mirrors the gotify / slack / email schemas in lib/notify/*.
#
# Modes:
#   default              prompt-driven; reads from /dev/tty so a piped
#                        non-interactive runner doesn't confuse the user.
#   --non-interactive    read line-per-field from stdin (test harness
#                        path; also useful when populating from a script).
#   --dry-run            print the [notify.*] block to stdout; no write.
#
# The schema-rewrite path uses the same `[<section>] … [<next>]` awk
# scanner as `standup discover` so it handles "section already exists"
# vs "no section yet" without depending on dasel writes (dasel v3 has
# no put subcommand).
#
# Exit codes:
#   0  configured (or dry-run printed)
#   2  bad / missing positional, bad value (URL missing scheme, etc.)
#   3  user aborted prompt (Ctrl-C / empty required field)

set -euo pipefail

# shellcheck disable=SC2154  # _prompt assigns via `printf -v "$var"` indirect

: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"

if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"non-interactive","type":"bool"},
      {"name":"dry-run","type":"bool"}]' \
    "$@"
fi

channel="${CLIFT_POS_1:-}"
non_interactive="${CLIFT_FLAGS[non-interactive]:-}"
dry_run="${CLIFT_FLAGS[dry-run]:-}"

case "$channel" in
  gotify|slack|email) ;;
  "")  clift_exit 2 "usage: jarvis notify configure <gotify|slack|email>" ;;
  *)   clift_exit 2 "unknown channel: $channel (expected: gotify, slack, email)" ;;
esac

profile_dir="$(state_profile_dir)"
cfg="$profile_dir/config.toml"

# _prompt <varname> <prompt-text> <required:0|1> [<default>]
# Interactive: prints the prompt to stderr, reads a line from /dev/tty.
# Non-interactive: reads a line from stdin (the parent's $0 stream).
# Empty + required → exit 3 with a stderr complaint.
# Returns the value via printf -v $varname.
_prompt() {
  local var="$1" text="$2" required="$3" default="${4:-}"
  local val
  if [[ "$non_interactive" == "true" ]]; then
    IFS= read -r val || val=""
  else
    if [[ -n "$default" ]]; then
      printf '%s [%s]: ' "$text" "$default" >&2
    else
      printf '%s: ' "$text" >&2
    fi
    if [[ -t 0 ]]; then
      IFS= read -r val </dev/tty || val=""
    else
      IFS= read -r val || val=""
    fi
  fi
  if [[ -z "$val" && -n "$default" ]]; then
    val="$default"
  fi
  if [[ -z "$val" && "$required" == "1" ]]; then
    printf 'notify configure: %s is required\n' "$var" >&2
    exit 3
  fi
  printf -v "$var" '%s' "$val"
}

# _validate_url <url-var> — minimal scheme check (https?:// or wss?://).
# Catches the common copy-paste mistake of dropping `https://`. We don't
# try to validate that the host resolves; that's the channel's job at
# delivery time.
_validate_url() {
  local val="${!1}"
  if [[ ! "$val" =~ ^https?:// ]]; then
    printf 'notify configure: %s must start with http:// or https:// (got: %s)\n' "$1" "$val" >&2
    exit 2
  fi
}

# _validate_email <var> — RFC 5322 is a yak; "x@y" with a dot in the
# domain catches every realistic typo. Channel will surface real
# delivery errors at send time.
_validate_email() {
  local val="${!1}"
  if [[ ! "$val" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    printf 'notify configure: %s must be a valid email address (got: %s)\n' "$1" "$val" >&2
    exit 2
  fi
}

# Channel-specific prompts. Field order pins the non-interactive stdin
# format (one line per field in the order shown) so test harnesses can
# pipe values without re-discovering the contract on every channel.
case "$channel" in
  gotify)
    _prompt url       "Server URL"           1
    _validate_url url
    _prompt token     "App token"            1
    _prompt priority  "Default priority"     0 5
    if [[ ! "$priority" =~ ^[0-9]+$ ]]; then
      printf 'notify configure: priority must be a non-negative integer (got: %s)\n' "$priority" >&2
      exit 2
    fi
    new_section="$(printf '[notify.gotify]\nurl = "%s"\ntoken = "%s"\npriority = %s\n' \
                          "$url" "$token" "$priority")"
    section_header='[notify.gotify]'
    ;;
  slack)
    _prompt webhook   "Incoming webhook URL" 1
    _validate_url webhook
    new_section="$(printf '[notify.slack]\nwebhook = "%s"\n' "$webhook")"
    section_header='[notify.slack]'
    ;;
  email)
    _prompt to              "Recipient address" 1
    _validate_email to
    _prompt from            "Sender address"    0
    [[ -n "$from" ]] && _validate_email from
    _prompt subject_prefix  "Subject prefix"    0 "[jarvis]"
    _prompt transport       "Transport"         0 auto
    case "$transport" in
      auto|mail|sendmail) ;;
      *) printf 'notify configure: transport must be one of: auto, mail, sendmail (got: %s)\n' "$transport" >&2
         exit 2 ;;
    esac
    new_section="$(
      printf '[notify.email]\nto = "%s"\n' "$to"
      [[ -n "$from"           ]] && printf 'from = "%s"\n' "$from"
      printf 'subject_prefix = "%s"\ntransport = "%s"\n' "$subject_prefix" "$transport"
    )"
    section_header='[notify.email]'
    ;;
esac

if [[ "$dry_run" == "true" ]]; then
  printf '%s\n' "$new_section"
  exit 0
fi

# Section-rewrite same as standup discover: replace if header exists,
# else append. dasel v3 has no put. Uses grep -Fx (fixed-string,
# whole-line) for the header lookup so brackets in the section name
# (`[notify.gotify]`) don't need to be regex-escaped.
mkdir -p "$profile_dir"
if [[ ! -f "$cfg" ]]; then
  printf '%s\n' "$new_section" > "$cfg"
elif ! grep -qFx "$section_header" "$cfg"; then
  # Stat before opening the append-group so we don't read+write the same
  # file inside one pipeline (shellcheck SC2094 false-positive otherwise).
  if [[ -s "$cfg" ]]; then leading_nl=$'\n'; else leading_nl=''; fi
  printf '%s%s\n' "$leading_nl" "$new_section" >> "$cfg"
else
  tmp="$(mktemp)"
  awk -v header="$section_header" -v new_section="$new_section" '
    BEGIN { in_section = 0 }
    $0 == header {
      in_section = 1
      print new_section
      next
    }
    in_section && /^\[[^]]+\][[:space:]]*$/ {
      in_section = 0
    }
    !in_section { print }
  ' "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
fi

log_success "configured ${channel} → ${cfg}"
