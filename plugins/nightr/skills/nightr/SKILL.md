---
name: nightr
description: Inspect Nightr keep-awake protection on this Mac, explain readiness and hotspot recovery, or explicitly start, stop, retry or skip using the installed Nightr app.
---

Use the Nightr MCP tools for this Mac. Begin with `nightr_status` before advising
or acting; use `nightr_config` for saved settings and `nightr_setup_status` for
read-only readiness details when relevant. Distinguish saved configuration,
observed controller state, desired protection and verified internet. Unknown or
stale observations remain unknown. A Wi-Fi association is not verified internet.

## Scope and authorization

Nightr's app, CLI and every agent session share global state for the current
Mac user. It does not provide a per-session lease or reference count. Explain
this scope before an action if the user's request suggests session isolation.
An explicit request to start, stop, retry or skip authorizes that action; do not
ask for another confirmation when the user has already authorized it. Ordinary
coding work, plugin connection and a request for status do not authorize Start.

Never automatically start or stop on connection, disconnection, task completion
or session cleanup. Do not promise uninterrupted agent work through system sleep
or claim to reconnect coding-agent sessions. Nightr cannot toggle an iPhone's
Personal Hotspot switch.

## Tool selection

All eight tools accept exactly `{}`: no arguments or settings overrides.

| Tool | Purpose |
| --- | --- |
| `nightr_status` | Read current shared protection and recovery state. |
| `nightr_config` | Read saved settings without editing them. |
| `nightr_setup_status` | Read setup readiness without installing or repairing. |
| `nightr_start` | Explicitly request shared protection with saved settings. |
| `nightr_stop` | Explicitly stop shared protection, including when the controller is absent or settings conflict. |
| `nightr_hotspot_retry_now` | Advance a remaining eligible attempt in the current bounded cycle. |
| `nightr_hotspot_try_again` | Explicitly request a new bounded hotspot cycle after exhaustion. |
| `nightr_hotspot_skip` | Explicitly skip hotspot fallback for the current outage. |

Use only the action matching the user's intent. Retry now does not replenish a
budget; Try again is not an automatic response to exhaustion. Safety guards may
block Start or recovery actions. Stop remains available: an absent controller,
incompatible settings or a failed status read must not prevent an authorized
Stop attempt.

## Results and recovery

Report the returned result truthfully, including blockers and next steps.
Starting protection is not proof a power hold is active. Read status after an
action when useful to verify its observed effect. If a mutation times out or its
reply is lost, its outcome is uncertain: do not replay it automatically. Read
status to reconcile; if uncertainty remains, explain it and await new explicit
intent before another mutation. Do not turn a timeout into an unbounded retry
loop or automatically start another hotspot cycle.

Never request, read or expose passwords or Keychain contents. Do not write
configuration, install helpers, bootstrap dependencies, change login services,
join networks through shell commands or bypass Nightr's battery/setup/ownership
guards. When repair is needed, describe the returned blocker and direct the user
to Nightr's app or explicit `nightr setup` flow; do not run setup as a side effect.

The package requires a matching native app at `/Applications/Nightr.app`.
If its MCP executable is absent or incompatible, report that prerequisite.
Do not fall back to PATH, a worktree binary or a downloaded executable. A signed
release containing this MCP support is not yet available; do not imply otherwise.
