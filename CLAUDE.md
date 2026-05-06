# jarvis — application conventions

This directory is a clift CLI built as a working dogfood example. The
**framework** conventions live in `/CLAUDE.md` at repo root (must follow);
this file captures **jarvis-specific** deltas that the application layer
needs but the framework doesn't impose on consumers.

## Layout

```
examples/jarvis/
  cmds/<group>/<sub>/...     # one Taskfile.yaml per command dir (LSP)
  lib/                       # jarvis-internal libraries (sourced from cmds)
    state/{profile,lock,json,ndjson,config}.sh   # state primitives
    focus/log.sh             # focus.log NDJSON + pair/orphan derivations
    notify/registry.sh       # pluggable notification channels
    calendar/{provider,none,gcalcli,ics,meeting_url}.sh
    integrations/{gh,jira,deploys,oncall}.sh
    cache/file.sh            # 5-min file cache for calendar+others
    remind/install.sh        # cron / systemd backend installers
    runtime/standalone_argv.sh   # bats helper for direct-invocation parity
  tests/                     # ../tests at repo root — bats suites
```

## Hard Rule — sourced libraries omit `set -euo pipefail`

**The framework CLAUDE.md says every script must `set -euo pipefail` at
the top.** That applies to executable scripts (cmds, hot-path entry
points). It does NOT apply to **sourced libraries** under `lib/`.

Why: `set -e` and `set -o pipefail` leak into the *caller's* shell when
the library is sourced. A lib that does `[[ "$x" == "y" ]]` for control
flow would abort the caller's script if the comparison is false. Same
for `grep -c .` that returns 1 on no matches.

How to apply:

- **Executable scripts** (`cmds/*/*.sh`, `lib/notify/*.sh` shipped scripts,
  scaffolding + check binaries): MUST start with `set -euo pipefail`.
- **Sourced libraries** (everything in `lib/` that's `source`d, not
  executed): MUST NOT call `set` at all. Inherit the caller's options.
  Add a header comment explaining the choice (see `lib/note/index.sh`,
  `lib/note/store.sh`, `lib/note/current.sh` for exemplars).
- The source-guard idiom is still required:
  ```bash
  # shellcheck disable=SC2317
  if [[ -n "${_JARVIS_<MODULE>_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
  fi
  _JARVIS_<MODULE>_LOADED=1
  ```

This convention is enforced by code review, not by lint. New libraries
that opt in to `set -e` will leak it; reviewers must catch.

## NDJSON contract for integrations

Every `lib/integrations/*.sh` and `lib/calendar/*.sh` provider follows
the same stdout shape:

- One JSON object per line on stdout.
- Empty stdout = "no data" (configured but nothing returned).
- Exit 1 = tool/config missing → caller hides the section.
- Exit 2 = error → caller may surface, dispatcher silences for hot paths.
- Stderr is **not** suppressed at the integration layer; the dispatcher
  decides whether to silence (`brief`/`standup` hot path) or surface
  (`doctor --integrations-live`).

## Profile flag is persistent

`profile` is declared as `vars.PERSISTENT_FLAGS` on the root Taskfile.
Per-command Taskfiles MUST NOT redeclare it under `vars.FLAGS` (compile.sh
hard-errors on collision).

**Resolution lives in `lib/state/profile.sh`** — a single
`state_profile_dir()` call picks up the value in priority order:

| Priority | Source | Where it comes from |
|---|---|---|
| 1 | `CLIFT_FLAGS[profile]` | router pipeline (assoc array, in-shell) |
| 2 | `CLIFT_FLAG_PROFILE` env | parser export (visible across subshells) |
| 3 | `JARVIS_PROFILE` env | direct override (tests, manual export) |
| 4 | `'default'` | last-resort fallback |

`state_profile_dir()` also exports `JARVIS_PROFILE` as a side effect so
downstream libs that read the env directly (`lib/calendar/provider.sh`,
`lib/integrations/*.sh`, `lib/state/config.sh` fallback) see the same
resolved value. Cmds need NO per-cmd translation boilerplate; just call
`state_profile_dir()` (or any helper that wraps it, e.g. `task_store_dir`).

## `.env` vs `config.toml` boundary

Two configuration surfaces, two distinct purposes:

- **`.env`** — *framework wiring + machine-wide preferences*. Set once at
  install (`jarvis setup:cli` writes it), read at every wrapper invocation
  before `task` is exec'd. Single file, single value per machine.
- **`config.toml`** — *per-profile user preferences*. Lives at
  `$JARVIS_HOME/<profile>/config.toml`, read on demand by `config_get`.
  Different values per profile (`work` / `home` / `default`).

| Key | Surface | Why |
|---|---|---|
| `CLI_NAME`, `CLI_VERSION` | `.env` | identity, set at scaffold time |
| `CLI_DIR`, `FRAMEWORK_DIR` | `.env` | filesystem wiring, install-resolved |
| `CLIFT_MODE` | `.env` | dispatch mode (standard / task), install-time |
| `LOG_THEME` | `.env` | machine-wide UX preference, single value |
| `[calendar] provider`, `[calendar.ics] source` | `config.toml` | per-profile integration config |
| `[notify.*]` (gotify / slack / email) | `config.toml` | per-profile channel credentials |
| `[standup] repos` | `config.toml` | per-profile workspace context |
| `[scheduler] backend` | `config.toml` | per-profile reminder dispatch |

**Rule of thumb:** if the value should differ between `work` and `home`
profiles, it belongs in `config.toml`. If it's a one-time install detail
or a UX preference that applies to every profile on this machine, it
belongs in `.env`.

## Determinism for tests

- Time: cmds honor `JARVIS_FAKE_NOW` (UTC ISO-8601). Helpers like
  `_focus_today_local`, `now_iso` resolution, etc. all check this env.
- Profile: `JARVIS_PROFILE=test` set by `tests/jarvis_helper.bash`;
  `--profile test` is inert when invoked through the helper but kept
  for direct-invocation parity.
- PATH shims: `tests/jarvis_shim_helper.bash` provides `shim_install`
  for replacing `gh`/`jira`/`gcalcli`/`curl`/`open` without touching
  the real tools.

## Standalone argv parity

Cmds that may be invoked directly (`bash cmds/<name>/<name>.sh ...`)
must use the standalone_argv fallback:

```bash
if ! declare -p CLIFT_FLAGS >/dev/null 2>&1; then
  source "${CLI_DIR}/lib/runtime/standalone_argv.sh"
  jarvis_standalone_argv_parse '<JSON-spec>' "$@"
fi
```

This keeps direct-invocation tests semantically identical to the router
pipeline. `brief`, `standup`, `status`, `doctor` all follow this pattern.
