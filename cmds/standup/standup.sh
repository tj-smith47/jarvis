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
# Author-date filter via awk (see header comment). Each line is prefixed
# with the repo's owner/name slug (or basename if no remote) so multi-repo
# standups stay readable; if the commit subject ends in a "(#NNN)" PR
# ref, that gets pulled out as `<slug>#<NNN>`, otherwise the short hash
# is appended (`<slug>@<short>`) so every row is actionable.
_standup_repo_slug() {
  local dir="$1" origin
  origin="$(cd "$dir" 2>/dev/null && git config remote.origin.url 2>/dev/null || true)"
  if [[ -z "$origin" ]]; then
    (cd "$dir" 2>/dev/null && basename "$(pwd)")
    return 0
  fi
  # Normalize formats so split-by-/ leaves owner/name as the last two parts:
  #   https://github.com/owner/name(.git)? → owner/name
  #   git@github.com:owner/name(.git)?     → owner/name (after replacing : with /)
  #   ssh://git@github.com/owner/name      → owner/name
  printf '%s' "$origin" | awk '{
    sub(/\.git$/, "")
    sub(/\/$/, "")
    gsub(/:/, "/")
    n = split($0, a, "/")
    if (n >= 2) print a[n-1] "/" a[n]
    else        print a[n]
  }'
}

git_log_lines=""
for r in "${git_repos[@]}"; do
  [[ -d "$r/.git" ]] || continue
  email="$(cd "$r" 2>/dev/null && git config user.email 2>/dev/null)" || email=""
  [[ -z "$email" ]] && continue
  repo_slug="$(_standup_repo_slug "$r")"
  # `%H|%h|%s` carries author-date, short hash, subject. Awk extracts the
  # PR ref from a trailing `(#NNN)` if present; otherwise falls back to
  # the short hash so the reader can `git show` the commit either way.
  lines="$(
    cd "$r" 2>/dev/null && \
      git log --author="$email" --pretty=format:'%aI|%h|%s' 2>/dev/null \
        | awk -F'|' -v s="$since_iso" -v u="$now_iso" -v repo="$repo_slug" '
            $1 >= s && $1 <= u {
              hash = $2
              # Subject may contain |; rejoin slots 3..NF.
              subj = $3
              for (i = 4; i <= NF; i++) subj = subj "|" $i
              pr = ""
              if (match(subj, / \(#[0-9]+\)$/)) {
                pr = substr(subj, RSTART + 3, RLENGTH - 4)
                subj = substr(subj, 1, RSTART - 1)
              }
              ref = (pr != "" ? "#" pr : "@" hash)
              printf "- %s%s  %s\n", repo, ref, subj
            }
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

# ----------------------------------------------------------- yesterday: tasks closed
# Tasks marked done in [since_iso, now_iso] never appeared in the yesterday
# narrative — only git commits + jira comments did. Adding closed tasks
# rounds out "what I shipped" beyond just code.
yesterday_tasks_done=""
if [[ -d "$profile_dir/tasks" ]]; then
  shopt -s nullglob
  _yt_files=( "$profile_dir/tasks"/*.json )
  shopt -u nullglob
  if (( ${#_yt_files[@]} > 0 )); then
    yesterday_tasks_done="$(jq -rs --arg s "$since_iso" --arg n "$now_iso" '
      [ .[] | select((.status // "") == "done"
                     and (.done_at // "") >= $s
                     and (.done_at // "") <= $n) ]
      | sort_by(.done_at)
      | .[]
      | "- ✓ " + (.title // .slug // "(untitled)")
    ' "${_yt_files[@]}" 2>/dev/null || true)"
  fi
fi

# ----------------------------------------------------------- yesterday: focus sessions
# focus.log captures end-rows with elapsed_seconds + topic. Aggregating to
# total minutes + top 1-2 topics gives the standup reader a one-line "I
# spent 4h on X yesterday" without forcing them to dig into `focus stats`.
yesterday_focus=""
focus_log="$profile_dir/focus.log"
if [[ -f "$focus_log" ]]; then
  yesterday_focus="$(jq -rs --arg s "$since_iso" --arg n "$now_iso" '
    [ .[] | select(.event == "end"
                   and (.elapsed_seconds // 0) > 0
                   and (.ts // "") >= $s
                   and (.ts // "") <= $n) ] as $ends
    | ($ends | map(.elapsed_seconds) | add // 0) as $secs
    | ($secs / 60 | floor) as $m
    | ($ends | map(.topic // "(untitled)")
            | group_by(.)
            | map({topic:.[0], count:length})
            | sort_by(-.count)
            | .[:2]
            | map(.topic)
            | join(", ")) as $top
    | if $m == 0 then ""
      elif $m < 60 then
        "- focus: \($m) min" + (if $top != "" then " on \($top)" else "" end)
      else
        ($m / 60 | floor) as $h
        | (if ($m % 60) == 0 then "\($h)h" else "\($h)h \($m % 60)m" end) as $hm
        | "- focus: \($hm)" + (if $top != "" then " on \($top)" else "" end)
      end
  ' < "$focus_log" 2>/dev/null || true)"
fi

# ----------------------------------------------------------- yesterday: reminders fired
# notify.log carries every channel-attempt row. Successfully-delivered
# reminders in the standup window are part of "what happened" — without
# this surface the user has to `cat notify.log` to know what fired.
yesterday_reminders_fired=""
notify_log="$profile_dir/notify.log"
if [[ -f "$notify_log" ]]; then
  _yr_count="$(jq -rs --arg s "$since_iso" --arg n "$now_iso" '
    [ .[] | select((.ok // false) == true
                   and (.ts // "") >= $s
                   and (.ts // "") <= $n
                   and (.channel // "") != "tick.heartbeat") ]
    | length
  ' < "$notify_log" 2>/dev/null || printf '0')"
  if [[ "${_yr_count:-0}" -gt 0 ]]; then
    yesterday_reminders_fired="- $_yr_count reminder$([[ "$_yr_count" -ne 1 ]] && printf s) fired"
  fi
fi

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

# ----------------------------------------------------------- today: meetings
# Standup pre-fix listed open tasks + jira-in-flight under "Today" but
# DROPPED today's calendar entirely — a standup draft that doesn't
# mention "I have a 1:1 at 14:00" is missing half the picture. Window is
# [now, end-of-today) — we don't want to dwell on a 9am that already
# happened by the time the user's reading.
day_start_iso="$(native_day_start "$now_iso")"
day_end_iso="$(native_day_boundary "$day_start_iso" +1d)"
meetings_today="$(_silence calendar_events "$now_iso" "$day_end_iso" "$profile" || true)"

# ----------------------------------------------------------- today: reminders
# Same gap as brief — `<profile>/reminders/*.json` was never read by
# standup despite being the canonical source of "things firing today".
reminders_today=""
if [[ -d "$profile_dir/reminders" ]]; then
  shopt -s nullglob
  _rem_files=( "$profile_dir/reminders"/*.json )
  shopt -u nullglob
  if (( ${#_rem_files[@]} > 0 )); then
    reminders_today="$(jq -cs --arg now "$now_iso" --arg end "$day_end_iso" '
      [ .[]
        | select((.status // "pending") == "pending" or (.status // "") == "active")
        | select(.trigger_at >= $now and .trigger_at < $end) ]
      | sort_by(.trigger_at)
      | .[]
    ' "${_rem_files[@]}" 2>/dev/null || true)"
  fi
fi

# ----------------------------------------------------------- blockers
# Pre-fix the blocker scan was filtered by `updated_at >= since_iso`, which
# meant a blocker that had been real for 5 days but received no recent edit
# silently dropped out of the standup view — the exact opposite of what the
# section is for. Now we list every active (non-archived) blocker note
# regardless of recency, and render an age suffix so the reader can tell
# which ones are stale.
#
# Each row also carries a body excerpt so the title isn't the only context
# (titles like "auth broken" force you to re-open the note to remember
# what's actually broken).
#
# Task store does not carry a `tags` field today, so task-side blockers
# are NOT scanned here — that needs a schema decision before it can land.
_blocker_excerpt() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    BEGIN { fm = 0 }
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm && /^---[[:space:]]*$/      { fm = 0; next }
    fm                              { next }
    /^[[:space:]]*$/                { next }
    /^[[:space:]]*#/                { next }
    {
      sub(/^[[:space:]]*[-*][[:space:]]+/, "")
      sub(/^[[:space:]]+/, "")
      if (length($0) > 80) print substr($0, 1, 79) "…"
      else print $0
      exit
    }
  ' "$f"
}

blockers=""
if [[ -f "$profile_dir/notes/index.json" ]]; then
  # Emit TSV: <relative-path>\t<title>\t<age-string>
  # `age_str` derives from updated_at vs now_iso; honors JARVIS_FAKE_NOW.
  blocker_tsv="$(jq -r --arg now "$now_iso" '
    def age_str:
      if (.updated_at // "") != "" then
        (($now | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
         (.updated_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) as $secs
        | if    $secs < 60     then ""
          elif  $secs < 3600   then "(\($secs / 60   | floor)m)"
          elif  $secs < 86400  then "(\($secs / 3600 | floor)h)"
          else                      "(\($secs / 86400 | floor)d)" end
      else "" end;
    .notes[]?
    | select((.archived // false) == false
             and ((.tags // []) | index("blocker")))
    | (.path // "")
      + "\t" + (.title // .path // "(untitled)")
      + "\t" + age_str
  ' "$profile_dir/notes/index.json" 2>/dev/null || true)"

  if [[ -n "$blocker_tsv" ]]; then
    while IFS=$'\t' read -r path title age; do
      [[ -z "$title" ]] && continue
      line="- ${title}"
      [[ -n "$age" ]] && line="${line} ${age}"
      blockers+="${line}"$'\n'
      if [[ -n "$path" && -f "$profile_dir/$path" ]]; then
        excerpt="$(_blocker_excerpt "$profile_dir/$path" || true)"
        [[ -n "$excerpt" ]] && blockers+="    ${excerpt}"$'\n'
      fi
    done <<< "$blocker_tsv"
    # Trim trailing newline so the consumer sed can prefix uniformly.
    blockers="${blockers%$'\n'}"
  fi
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
if [[ -n "$yesterday_tasks_done" ]]; then
  printf '%s\n' "$yesterday_tasks_done" | sed 's/^/    /'
  had_yesterday=1
fi
if [[ -n "$yesterday_focus" ]]; then
  printf '    %s\n' "$yesterday_focus"
  had_yesterday=1
fi
if [[ -n "$yesterday_reminders_fired" ]]; then
  printf '    %s\n' "$yesterday_reminders_fired"
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

if [[ -n "$meetings_today" ]]; then
  printf '  \033[1mMeetings\033[0m\n'
  printf '%s\n' "$meetings_today" | jq -r '
    "    " +
    (.start | sub("^.*T"; "") | sub(":[0-9]+Z?$"; "")) +
    "  " + .title +
    (if (.url // "") != "" then "  " + .url else "" end)'
  printf '\n'
fi

if [[ -n "$reminders_today" ]]; then
  printf '  \033[1mReminders\033[0m\n'
  printf '%s\n' "$reminders_today" | jq -r '
    "    " +
    (.trigger_at | sub("^.*T"; "") | sub(":[0-9]+Z?$"; "")) +
    "  " + (.message // .slug // "(no message)") +
    (if (.repeat // "") != "" and .repeat != "once" then "  (every \(.repeat))" else "" end)'
  printf '\n'
fi

printf '  \033[1mBlockers\033[0m\n'
if [[ -n "$blockers" ]]; then
  printf '%s\n' "$blockers" | sed 's/^/    /'
else
  printf '    (none)\n'
fi
printf '\n'
