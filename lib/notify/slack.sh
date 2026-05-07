#!/usr/bin/env bash
# Slack incoming-webhook notification channel.
# Reads [notify.slack] webhook from per-profile config.toml.

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTIFY_SLACK_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTIFY_SLACK_LOADED=1

notify_slack() {
  local message="${1:-}" profile="${2:-}"

  if [[ -z "$message" ]]; then
    _notify_log slack false "" "empty message" "$profile"
    return 1
  fi

  local webhook
  webhook="$(config_get notify.slack.webhook "" "$profile")"

  if [[ -z "$webhook" ]]; then
    _notify_log slack false "$message" "missing [notify.slack].webhook" "$profile"
    return 2
  fi

  if [[ "${JARVIS_NOTIFY_DRYRUN:-}" == "1" ]]; then
    _notify_log slack true "$message" "" "$profile"
    return 0
  fi

  local body err
  body="$(jq -nc --arg t "$message" '{text:$t}')"
  # The webhook URL is token-bearing — passing it on the command line means
  # the secret is visible in `ps` / /proc/<pid>/cmdline. Feed it via curl's
  # --config (stdin) so it never appears in argv.
  if err="$(printf 'url = "%s"\n' "$webhook" \
              | curl -fsS --config - -X POST \
                  -H 'Content-Type: application/json' \
                  -d "$body" 2>&1 >/dev/null)"; then
    _notify_log slack true "$message" "" "$profile"
    return 0
  fi
  err="${err%%$'\n'*}"
  _notify_log slack false "$message" "$err" "$profile"
  return 1
}

notify_register slack notify_slack
