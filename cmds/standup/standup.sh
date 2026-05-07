#!/usr/bin/env bash
# Standup draft. Yesterday/Today/Blockers from real data:
#   * Yesterday — git log (author = local repo's user.email) within
#                 [now - --since, now] + jira_my_comments_since.
#   * Today     — open tasks under <profile>/tasks/*.json + jira_in_flight.
#   * Blockers  — notes from <profile>/notes/index.json tagged 'blocker'
#                 with updated_at >= since_iso and archived == false.
#
# Filter mechanics:
#   * `git log --since` filters by *commit* date, but the test fixture
#     (and most replay-style commits) sets author date via `--date=...`.
#     We use `--pretty=%aI|%H|%s` and post-filter author dates in awk so
#     the contract holds regardless of how/when commits land.
#   * --all-repos pulls `[standup] repos = [...]` from the profile config
#     via `dasel -i toml -o json` (config_get can't carry array shape).
#
# --join scans calendar [now, now+15min) for a /standup/i event and opens
# its URL via open|xdg-open (stdout fallback). --meeting URL bypasses the
# calendar lookup. Both fall through to the normal summary render.
#
# Invocation modes:
#   * via clift router → CLIFT_FLAGS pre-populated
#   * direct bash      → standalone_argv parses --since/--repo/--all-repos/
#                        --profile/--join/--meeting

set -euo pipefail

# Resolve framework/CLI dirs with fallback so this runs standalone in tests.
: "${FRAMEWORK_DIR:=${CLIFT_FRAMEWORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}}"
: "${CLI_DIR:=${JARVIS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# shellcheck source=/dev/null
source "${FRAMEWORK_DIR}/lib/log/log.sh"

# Flag resolution: prefer pre-populated CLIFT_FLAGS; otherwise parse argv
# ourselves via the shared standalone helper.
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse \
    '[{"name":"since","type":"string"},
      {"name":"repo","type":"string"},
      {"name":"all-repos","type":"bool"},
      {"name":"profile","type":"string"},
      {"name":"join","type":"bool"},
      {"name":"meeting","type":"string"}]' \
    "$@"
fi

since="${CLIFT_FLAGS[since]:-1d}"
repo="${CLIFT_FLAGS[repo]:-}"
all_repos="${CLIFT_FLAGS[all-repos]:-}"
join="${CLIFT_FLAGS[join]:-}"
meeting_url="${CLIFT_FLAGS[meeting]:-}"

# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/profile.sh"
# state_profile_dir centralizes the precedence chain and exports
# JARVIS_PROFILE so downstream libs (calendar, integrations) read it back.
state_profile_dir >/dev/null
profile="$JARVIS_PROFILE"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/state/config.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/integrations/jira.sh"
# Calendar stack (only needed by --join, but cheap and keeps a single source
# block — providers register at source-time, so order matters: provider.sh
# defines calendar_register; backends register themselves on source).
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/cache/file.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/provider.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/none.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/ics.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/gcalcli.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/applescript.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/calendar/meeting_url.sh"
# shellcheck source=/dev/null
source "${CLI_DIR}/lib/native/clock.sh"

profile_dir="$(state_profile_dir)"

# "now" — overridable for deterministic tests; clock helpers honor JARVIS_FAKE_NOW.
now_iso="$(native_now_iso)"
now_epoch="$(native_now_epoch)"

# Resolve --since (Ns|Nm|Nh|Nd|Nw) to a window start ISO. Day/week units
# anchor to start-of-day-today (UTC) so `--since 1d` reads "everything
# from yesterday morning forward" — the natural standup window. Sub-day
# units (s/m/h) are exact rolling windows. Bad input falls back to 1d.
_anchor_today_midnight() {
  native_resolve_to_epoch "$(native_day_start "$now_iso")"
}
anchor_epoch="$now_epoch"
if [[ "$since" =~ ^([0-9]+)([smhdw])$ ]]; then
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  case "$u" in
    s) sec=$n ;;
    m) sec=$((n*60)) ;;
    h) sec=$((n*3600)) ;;
    d) sec=$((n*86400)); anchor_epoch="$(_anchor_today_midnight)" ;;
    w) sec=$((n*604800)); anchor_epoch="$(_anchor_today_midnight)" ;;
  esac
else
  sec=86400
  anchor_epoch="$(_anchor_today_midnight)"
fi
since_epoch=$(( anchor_epoch - sec ))
since_iso="$(native_epoch_to_iso "$since_epoch")"

# ----------------------------------------------------------- repo list
# --all-repos overrides --repo. Otherwise fall back to --repo, then cwd.
git_repos=()
if [[ "$all_repos" == "true" ]]; then
  cfg="$profile_dir/config.toml"
  if [[ -f "$cfg" ]] && command -v dasel >/dev/null 2>&1; then
    repos_json="$(dasel -i toml -o json standup.repos < "$cfg" 2>/dev/null || true)"
    if [[ -n "$repos_json" && "$repos_json" != "null" ]]; then
      while IFS= read -r r; do
        [[ -n "$r" ]] && git_repos+=("$r")
      done < <(jq -r '.[]?' <<< "$repos_json" 2>/dev/null)
    fi
  fi
fi
if [[ "${#git_repos[@]}" -eq 0 && -n "$repo" ]]; then
  git_repos=("$repo")
fi
if [[ "${#git_repos[@]}" -eq 0 ]]; then
  git_repos=(".")
fi

# ----------------------------------------------------------- yesterday: git
# Author-date filter via awk (see header comment).
git_log_lines=""
for r in "${git_repos[@]}"; do
  [[ -d "$r/.git" ]] || continue
  email="$(cd "$r" 2>/dev/null && git config user.email 2>/dev/null)" || email=""
  [[ -z "$email" ]] && continue
  # Author-date filter via awk so per-commit `--date=...` (which sets
  # author date but not commit date) is honored.
  lines="$(
    cd "$r" 2>/dev/null && \
      git log --author="$email" --pretty=format:'%aI|%s' 2>/dev/null \
        | awk -F'|' -v s="$since_iso" -v u="$now_iso" '
            $1 >= s && $1 <= u { sub(/^[^|]*\|/, ""); print "- " $0 }
          '
  )" || lines=""
  [[ -n "$lines" ]] && git_log_lines+="$lines"$'\n'
done

# `--verbose` lets integration stderr through so auth/network failures
# are visible without dropping into `jarvis doctor --integrations-live`.
verbose="${CLIFT_FLAGS[verbose]:-}"
_silence() {
  if [[ "$verbose" == "true" ]]; then "$@"; else "$@" 2>/dev/null; fi
}

# ----------------------------------------------------------- yesterday: jira
jira_comments="$(_silence jira_my_comments_since "$since_iso" "$profile" || true)"

# ----------------------------------------------------------- today: tasks
open_tasks=""
if [[ -d "$profile_dir/tasks" ]]; then
  shopt -s nullglob
  task_files=( "$profile_dir/tasks"/*.json )
  shopt -u nullglob
  if (( ${#task_files[@]} > 0 )); then
    open_tasks="$(jq -rs '
      .[] | select((.status // "open") == "open") | "- " + (.title // .slug // "(untitled)")
    ' "${task_files[@]}")"
    [[ -n "$open_tasks" ]] && open_tasks+=$'\n'
  fi
fi

# ----------------------------------------------------------- today: jira
jira_today="$(_silence jira_in_flight "$profile" || true)"

# ----------------------------------------------------------- blockers
blockers=""
if [[ -f "$profile_dir/notes/index.json" ]]; then
  blockers="$(jq -r --arg s "$since_iso" '
    .notes[]?
    | select((.archived // false) == false
             and ((.tags // []) | index("blocker"))
             and ((.updated_at // "") >= $s))
    | "- " + (.title // (.path // "(untitled)"))
  ' "$profile_dir/notes/index.json" 2>/dev/null || true)"
fi

# ----------------------------------------------------------- --join / --meeting
# Runs before the render block so the meeting opens first, then the standup
# summary follows. URL precedence:
#   1. --meeting URL (explicit) — skip calendar lookup entirely.
#   2. calendar event titled /standup/i within [now, now+15min):
#      a. event's `.url` field
#      b. fallback: meeting_url_extract on the event title.
# Open via `open`, fall back to `xdg-open`, fall back to printing the URL.
_standup_open_url() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url"
    return
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
    return
  fi
  printf '%s\n' "$url"
}

if [[ "${join:-}" == "true" || -n "${meeting_url:-}" ]]; then
  url="${meeting_url:-}"
  if [[ -z "$url" ]]; then
    horizon_epoch=$(( now_epoch + 15*60 ))
    horizon_iso="$(date -u -d "@$horizon_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                   || date -u -j -f %s "$horizon_epoch" +%Y-%m-%dT%H:%M:%SZ)"
    events="$(calendar_events "$now_iso" "$horizon_iso" "$profile" 2>/dev/null || true)"
    if [[ -n "$events" ]]; then
      target="$(printf '%s\n' "$events" | jq -rc 'select(.title | test("standup"; "i"))' | head -1)"
      if [[ -n "$target" ]]; then
        url="$(printf '%s' "$target" | jq -r '.url // ""')"
        if [[ -z "$url" ]]; then
          # Prefer cron-meet-cal's extractor when installed (handles structured
          # event payloads, broader URL patterns); fall back to the internal
          # Zoom/Meet/Teams regex otherwise. Subcommand contract:
          #   cron-meet-cal extract-url < event-text  -> URL on stdout (exit 0)
          #                                           or empty + nonzero (no match).
          if command -v cron-meet-cal >/dev/null 2>&1; then
            url="$(printf '%s' "$target" | jq -r '.title' \
                    | cron-meet-cal extract-url 2>/dev/null || true)"
          fi
          if [[ -z "$url" ]]; then
            url="$(printf '%s' "$target" | jq -r '.title' | meeting_url_extract || true)"
          fi
        fi
      fi
    fi
  fi
  if [[ -n "$url" ]]; then
    _standup_open_url "$url"
  else
    printf 'standup: no standup event in the next 15 min (set --meeting URL to bypass)\n'
  fi
  printf '\n'
  # Fall through to the normal summary render below.
fi

# ----------------------------------------------------------- render
printf '\n'
if declare -F log_info >/dev/null 2>&1; then
  log_info "standup draft — since ${since}"
else
  printf 'info: standup draft — since %s\n' "$since"
fi
printf '\n'

printf '  \033[1mYesterday\033[0m\n'
had_yesterday=0
if [[ -n "$git_log_lines" ]]; then
  printf '%s' "$git_log_lines" | sed 's/^/    /'
  had_yesterday=1
fi
if [[ -n "$jira_comments" ]]; then
  printf '%s\n' "$jira_comments" | jq -r '"    - [" + .key + "] " + .body'
  had_yesterday=1
fi
(( had_yesterday == 0 )) && printf '    (none)\n'
printf '\n'

printf '  \033[1mToday\033[0m\n'
had_today=0
if [[ -n "$open_tasks" ]]; then
  printf '%s' "$open_tasks" | sed 's/^/    /'
  had_today=1
fi
if [[ -n "$jira_today" ]]; then
  printf '%s\n' "$jira_today" | jq -r '"    - [" + .key + "] " + .summary'
  had_today=1
fi
(( had_today == 0 )) && printf '    (none)\n'
printf '\n'

printf '  \033[1mBlockers\033[0m\n'
if [[ -n "$blockers" ]]; then
  printf '%s\n' "$blockers" | sed 's/^/    /'
else
  printf '    (none)\n'
fi
printf '\n'
