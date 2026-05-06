#!/usr/bin/env bash
# Email notification channel via the system `mail` or `sendmail` MTA.
# Reads [notify.email] from per-profile config.toml:
#   to              required, recipient address
#   from            optional, sender (mail -r / sendmail From: header)
#   subject_prefix  optional, default "[jarvis]" — leading subject token
#   transport       optional, "auto" | "mail" | "sendmail" (default "auto")
#
# Subject is "<prefix> <first 80 chars of first message line>" so the inbox
# glance carries enough context; body is the full message.
#
# Channel signature matches gotify/slack: `notify_email <message> <profile>`.
# Profile is threaded explicitly — no env mutation. Honors JARVIS_NOTIFY_DRYRUN
# (skip MTA call, log success).

# shellcheck disable=SC2317
if [[ -n "${_JARVIS_NOTIFY_EMAIL_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_JARVIS_NOTIFY_EMAIL_LOADED=1

notify_email() {
  local message="${1:-}" profile="${2:-}"

  if [[ -z "$message" ]]; then
    _notify_log email false "" "empty message" "$profile"
    return 1
  fi

  local to from subject_prefix transport
  to="$(config_get notify.email.to "" "$profile")"
  from="$(config_get notify.email.from "" "$profile")"
  subject_prefix="$(config_get notify.email.subject_prefix "[jarvis]" "$profile")"
  transport="$(config_get notify.email.transport "auto" "$profile")"

  if [[ -z "$to" ]]; then
    _notify_log email false "$message" "missing [notify.email].to" "$profile"
    return 2
  fi

  # "auto" picks the first MTA on PATH so a synced $JARVIS_HOME works on
  # whichever box runs the tick — mail is more common, sendmail is the
  # universal fallback.
  if [[ "$transport" == "auto" ]]; then
    if command -v mail >/dev/null 2>&1; then
      transport="mail"
    elif command -v sendmail >/dev/null 2>&1; then
      transport="sendmail"
    else
      _notify_log email false "$message" \
        "no email transport on PATH (install mail or sendmail)" "$profile"
      return 2
    fi
  fi

  if [[ "${JARVIS_NOTIFY_DRYRUN:-}" == "1" ]]; then
    _notify_log email true "$message" "" "$profile"
    return 0
  fi

  local first_line subject
  first_line="${message%%$'\n'*}"
  if (( ${#first_line} > 80 )); then
    first_line="${first_line:0:77}..."
  fi
  if [[ -n "$first_line" ]]; then
    subject="$subject_prefix $first_line"
  else
    subject="$subject_prefix"
  fi

  local err rc=0
  case "$transport" in
    mail)
      if [[ -n "$from" ]]; then
        err="$(printf '%s\n' "$message" \
                | mail -s "$subject" -r "$from" -- "$to" 2>&1 >/dev/null)" \
          || rc=$?
      else
        err="$(printf '%s\n' "$message" \
                | mail -s "$subject" -- "$to" 2>&1 >/dev/null)" \
          || rc=$?
      fi
      ;;
    sendmail)
      # -t parses To/From/Subject from headers. Build a minimal RFC 2822
      # envelope; sendmail's stderr is rarely machine-actionable so we
      # surface rc only when it fails.
      err="$(
        {
          [[ -n "$from" ]] && printf 'From: %s\n' "$from"
          printf 'To: %s\n' "$to"
          printf 'Subject: %s\n' "$subject"
          printf '\n%s\n' "$message"
        } | sendmail -t 2>&1
      )" || rc=$?
      ;;
    *)
      _notify_log email false "$message" \
        "unknown transport '$transport' (expected: mail, sendmail, auto)" "$profile"
      return 2
      ;;
  esac

  if (( rc == 0 )); then
    _notify_log email true "$message" "" "$profile"
    return 0
  fi
  err="${err%%$'\n'*}"
  [[ -z "$err" ]] && err="$transport: exit $rc"
  _notify_log email false "$message" "$err" "$profile"
  return 1
}

notify_register email notify_email
