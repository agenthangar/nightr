# Nightr agent instructions

Nightr is a standalone macOS keep-awake utility for coding-agent work, extracted
from AgentHangar's `t`. The desktop app, CLI and website share this repository.

- Read DESIGN.md and docs/implementation-plan.md before user-facing work.
- Work in a session worktree on a feature branch; never develop in canonical main.
- Record a matching GitHub issue before implementation. Current launch issue:
  https://github.com/agenthangar/nightr/issues/1.
- The interactive HTML mockup and icon direction require explicit user approval
  before substantial app/controller implementation. Do not push UI changes or
  publish websites until the user approves the preview. Prototype work is allowed.
- Preserve `nosleep` invocations, flags, saved config and Keychain service names.
  The new `nightr` executable must run without an installed `t`.
- Use the supported command-line installer for Nightr installs and upgrades.
  Never use Computer Use or GUI automation for installation. Leave macOS
  administrator authentication to the user. Verify the installed signed payload
  and confirm Nightr reopened via process and controller status.
- Never run actual sleep/power, Wi-Fi join, Keychain modification, helper install,
  login-service install or DNS mutation as a test. Use mocked system commands,
  sandbox HOME/XDG paths and isolated temporary state. Strip COV_CORE_* from
  child copies of measured binaries. Native UI tests require explicit opt-in.
- Use only synthetic data in demos. No auth state, user configuration, transcripts
  or personal session recordings in this public repository.
- Treat power ownership and one active monitor as invariants. Bounded helpers,
  cancellation, battery cutoff and cleanup take priority over recovery.
- Preserve source attribution and MIT notices for extracted code. Keep a precise
  upstream commit record in docs/provenance.md.
- Releases are patch-first, independently versioned, starting at v0.1.0. Do not
  publish a release before acceptance checks pass. Never advertise planned
  capabilities as already implemented.
- Run relevant unit/contract checks and `python3 -m pytest --cov
  --cov-fail-under=97` for extracted Python sources, shell syntax checks for
  changed shell, and appropriate preview/browser checks. No default macOS UI CI.
- Watch snapshot runs with `t runners runs watch ID --timeout 60 --json` and
  PR checks with `t runners runs watch OWNER/REPO#PR@HEAD_SHA --timeout 60 --json`.
  Pass `--next-step` to record the pending action and resume a timed-out watch.
  For standalone signing on main, start a local watcher receipt with
  `t runners runs start --tool codex --repo nightr --timeout 6100 --next-step "Verify signed package" -- python3 scripts/watch_signed_candidate.py RUN_ID MERGE_SHA`.
  Watch that receipt by ID and inspect its result before installing.
- Review actual diffs and evidence before PRs. After required preview approval,
  open ready PRs, enable squash auto-merge, and monitor required CI through merge;
  never bypass protections. Do not auto-publish an unapproved design.

Workflow context: resolve `t workflow context --tool codex` in the selected
worktree and follow only that scope's resolved workflow.
