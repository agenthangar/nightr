# Nightr agent plugins

Tracking: https://github.com/agenthangar/nightr/issues/4.

`plugins/nightr/` is one local authoring package for OpenAI desktop hosts and
Claude Code. Both hosts discover the same `skills/nightr/SKILL.md` and launch
the same native MCP server. Neither host gets a separate controller or lease.

## Prerequisites and readiness

Requires macOS 13+ and a matching Nightr app with native MCP support installed
at `/Applications/Nightr.app`. A signed release containing this support is not
yet available. These packaging files do not establish release readiness or a
public directory listing. An older app without the `mcp` command is incompatible.

The launch command is fixed:

```text
/Applications/Nightr.app/Contents/MacOS/nightr-native mcp
```

The package does not install Nightr, download a runtime, use PATH lookup or run a
worktree binary. Missing app/setup must be repaired explicitly through Nightr's
normal installation and setup flow. Do not use a plugin connection as an
installer or permission-authorization shortcut.

## Codex and OpenAI local authoring

The portable manifest is root `plugin.json`; root `mcp.json` declares the stdio
server. Local marketplace support varies by host surface. The documented repo
source is `$REPO_ROOT/.agents/plugins/marketplace.json`. To test manually, add
the following catalog in a repository containing `plugins/nightr/`, preserving
any existing entries:

```json
{
  "name": "nightr-local",
  "interface": {"displayName": "Nightr local"},
  "plugins": [
    {
      "name": "nightr",
      "source": {"source": "local", "path": "./plugins/nightr"},
      "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
      "category": "Productivity"
    }
  ]
}
```

The source path is relative to the repository root. Current OpenAI documentation
supports portable manifests and local-marketplace plugins in Codex CLI and Codex
in the ChatGPT desktop app; `.codex-plugin/plugin.json` is an optional legacy
overlay. This package needs no overlay. See [official OpenAI packaging documentation](https://developers.openai.com/plugins/build/plugins).

For desktop authoring, restart ChatGPT, choose this source in the Plugins
Directory and install Nightr. For CLI authoring, installed `codex-cli 0.164.0`
exposes these commands (run manually after preparing the catalog):

```sh
codex plugin marketplace add /absolute/path/to/nightr
codex plugin add nightr@nightr-local
codex plugin list --marketplace nightr-local --json
```

To enable the local-marketplace plugin for a trusted project, merge this into
that project's `.codex/config.toml`:

```toml
[plugins."nightr@nightr-local"]
enabled = true
```

Host installs use a cached copy; refresh/reinstall after edits. Older Codex
versions may lack these plugin commands: use the direct MCP configuration below.
Only CLI help and documentation were inspected; actual host installation and
native-app connection remain unverified. This repository does not change
personal configuration or install the plugin for you.

Public OpenAI local-MCP submissions currently require approved-partner
allowlisting. This package is not submitted or publicly listed; it depends on
the separately installed native app and has not passed clean-install review.
See [desktop-only submission requirements](https://developers.openai.com/plugins/deploy/desktop-only).

## Claude Code local authoring

Load the plugin root for one session, substituting your checkout's absolute path:

```sh
claude --plugin-dir /absolute/path/to/nightr/plugins/nightr
```

Claude uses `.claude-plugin/plugin.json`, root `.mcp.json` and root `skills/`.
In that session, inspect `/mcp` for connection status and invoke `/nightr:nightr`
for the shared workflow. Do not point `--plugin-dir` at `.claude-plugin/`.
See [Claude's authoring guide](https://code.claude.com/docs/en/plugins/create)
and [manifest reference](https://code.claude.com/docs/en/plugins-reference).

## Direct MCP alternative

For Codex CLI/IDE, manually merge into `~/.codex/config.toml` (or a trusted
project's `.codex/config.toml`), preserving existing settings:

```toml
[mcp_servers.nightr]
command = "/Applications/Nightr.app/Contents/MacOS/nightr-native"
args = ["mcp"]
```

This is the documented [Codex stdio MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
It registers only the server; it does not install the plugin or shared skill.

If a host supports stdio MCP but cannot load this plugin layout, manually add
the following to its documented MCP server configuration. This is an example,
not a host-independent installation command. Do not also enable the plugin's
server in the same session. Direct MCP registration does not load the skill;
review and follow the [shared workflow](../plugins/nightr/skills/nightr/SKILL.md).

```json
{
  "mcpServers": {
    "nightr": {
      "command": "/Applications/Nightr.app/Contents/MacOS/nightr-native",
      "args": ["mcp"]
    }
  }
}
```

## Shared state and action boundaries

Start with `nightr_status`; `nightr_config` and `nightr_setup_status` are
read-only. All eight tools take `{}` with no overrides. Explicit intent permits
`nightr_start`, `nightr_stop`, `nightr_hotspot_retry_now`,
`nightr_hotspot_try_again` or `nightr_hotspot_skip`. The skill defines the
distinction between advancing an attempt and starting a fresh bounded cycle.

App, CLI and agent sessions share the current Mac user's settings, enabled
intent and controller. Start/Stop affect all of them. Stop persists disabled
intent even without a controller or with conflicting settings. Connecting,
disconnecting and task completion never start or stop protection automatically.
Connection loss does not revoke a previous Start.

A timeout after an action can mean the action happened but its reply was lost.
Do not automatically replay it; reconcile with read-only status and explain any
remaining uncertainty. Protection may be paused by battery, setup or ownership
guards. Association alone does not verify internet. Nightr cannot toggle an
iPhone hotspot or guarantee agent work across sleep.

The server exposes no password, configuration-write, helper-install or arbitrary
command tools. Do not compensate with shell commands or retry loops. Repair
guidance belongs in the app or explicit `nightr setup`, without automatic repair.

## Package verification

`tests/test_nightr_plugins.py` checks host identity, launch parity, the sole shared
skill and the absence of lifecycle hooks/bootstrap dependencies. It reads only
repository files and never launches the native app, host or controller. Native
MCP behavior is tested separately using isolated synthetic state. Real host
installation and a clean signed-app workflow remain acceptance steps once a
matching release exists.
