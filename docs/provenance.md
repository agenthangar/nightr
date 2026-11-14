# Extraction provenance

Nightr's initial CLI is derived from
[AgentHangar t](https://github.com/agenthangar/t) at immutable upstream commit
[`b6a0f24b383980595a92694276b6cd6a8ae8365e`](https://github.com/agenthangar/t/tree/b6a0f24b383980595a92694276b6cd6a8ae8365e).
Upstream copyright: Copyright (c) 2026 Chris O'Brien. The MIT license is retained
in the repository's [LICENSE](../LICENSE).

Copied runtime sources: `zsh/nosleep.zsh`, `zsh/nosleep-fallback.zsh`,
`libexec/nosleep_config.py`, `libexec/nosleep_hotspot.py`,
`libexec/nosleep_wifi.py`, and `libexec/nosleep_wifi.swift`.
`bin/nosleep` derives from the upstream launcher; `bin/nightr` uses the same
standalone launch contract. The upstream `t_dev.py` source selector and runtime
`_t_reload_if_moved` delegation were removed. Both launchers resolve their own
repository only.

`libexec/nightr_terminal.py` contains the needed `Style`, `_RailUI` and terminal
row/window helpers from upstream `bin/t`, Unicode display helpers from
`libexec/t_session_details.py`, and `key_labels` from `libexec/t_picker_theme.py`.
It omits t's unrelated model-table renderer and loads no t modules. Config loads
this local module lazily instead of executing `bin/t`.

Tests derive from upstream `tests/test_nosleep_{runtime,standalone,config,hotspot,wifi}.py`
and `tests/pty_helpers.py`. Standalone assertions now cover both launchers and
repository independence. The CLI guide derives from upstream `docs/nosleep.md`.
Test configuration preserves upstream exclusions for terminal rendering and CLI
entry dispatch while gating deterministic Python logic at 97% coverage.

Compatibility identifiers deliberately remain unchanged:
`$XDG_CONFIG_HOME/nosleep/config.json` (or `~/.config/nosleep/config.json`),
Keychain service `agenthangar.nosleep.hotspot`, and the Wi-Fi helper's per-source
`~/Library/Application Support/t/nosleep/<scope>` storage and bundle identity.
The latter is a compatibility path, not a dependency on t. Helpers remain bounded;
this extraction retains the existing single hotspot attempt per outage.

This extraction adds no shared controller, background service, login installation,
new recovery policy, app, installer or automatic updater. Those remain planned.
