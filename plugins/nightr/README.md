# Nightr plugin

One package for Codex, OpenAI desktop hosts and Claude Code, with one shared
`skills/nightr/SKILL.md`. See [setup and limitations](../../docs/plugins.md).

Requires macOS and a matching Nightr app installed at `/Applications/Nightr.app`
with native MCP support. The signed release containing this support is not yet
available. This is a local authoring package, not an installed or published plugin.

Both MCP configurations launch
`/Applications/Nightr.app/Contents/MacOS/nightr-native mcp` directly. There are no
download scripts, dependencies, lifecycle hooks or PATH-based alternatives.
Connecting inspects nothing until a tool is called and never starts protection.

All sessions share the same Mac user's app/controller state. Start and Stop are
global actions, not leases for a chat. Disconnecting or finishing a task does not
stop protection. Explicit Stop also works when the controller is absent or its
settings conflict. Status and configuration reads do not install or repair setup.
