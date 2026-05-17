#!/usr/bin/env bash
# Section / row icon dispatch for the brief / standup / status hot paths.
#
# Two consistent icon sets, selectable via env:
#
#   JARVIS_ICONS=unicode   (default) — basic Unicode glyphs that render in
#                                      any monospace font (VHS default,
#                                      tty without color emoji, SSH from
#                                      a server box without Apple Color
#                                      Emoji, etc.).
#   JARVIS_ICONS=emoji              — pictographs. Requires a font with
#                                     emoji coverage (Apple Color Emoji,
#                                     NotoColorEmoji, Twemoji).
#
# Sourced library: MUST NOT call `set -euo pipefail` (would leak into
# every caller). Source-guard idiom per jarvis CLAUDE.md.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_UI_ICONS_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_UI_ICONS_LOADED=1

# jarvis_icon <kind>
#
# Kinds (current callers):
#   greeting    — "Good morning" prefix          (brief)
#   calendar    — calendar section header        (brief)
#   prs         — PRs awaiting review header     (brief)
#   focus       — focus yesterday header         (brief)
#   reminders   — reminders today header         (brief)
#   jira        — jira in flight header          (brief)
#   tasks       — tasks section header           (brief)
#   notes       — notes section header           (brief)
#   deploys     — deploys section header         (brief)
#   oncall      — oncall section header          (brief)
#   pr_merged   — per-row marker for shipped PR  (standup)
#   pr_opened   — per-row marker for new PR      (standup)
#   warn        — warning marker                 (standup "no PR")
#
# Unknown kinds emit empty string (silent fallback — never error out of
# a render hot path).
jarvis_icon() {
  local kind="$1"
  local style="${JARVIS_ICONS:-unicode}"
  if [[ "$style" == "emoji" ]]; then
    case "$kind" in
      greeting)   printf '☀' ;;
      calendar)   printf '📅' ;;
      prs)        printf '🔀' ;;
      focus)      printf '⏱' ;;
      reminders)  printf '🔔' ;;
      jira)       printf '🪲' ;;
      tasks)      printf '✅' ;;
      notes)      printf '📓' ;;
      deploys)    printf '🚀' ;;
      oncall)     printf '📟' ;;
      pr_merged)  printf '🚀' ;;
      pr_opened)  printf '📝' ;;
      warn)       printf '⚠' ;;
      *)          printf '' ;;
    esac
  else
    case "$kind" in
      greeting)   printf '☀' ;;
      calendar)   printf '◷' ;;
      prs)        printf '⇄' ;;
      focus)      printf '◔' ;;
      reminders)  printf '◉' ;;
      jira)       printf '◆' ;;
      tasks)      printf '✓' ;;
      notes)      printf '≡' ;;
      deploys)    printf '▲' ;;
      oncall)     printf '●' ;;
      pr_merged)  printf '▲' ;;
      pr_opened)  printf '+' ;;
      warn)       printf '⚠' ;;
      *)          printf '' ;;
    esac
  fi
}
