"""Plugin distribution contract: repository reads only, no host/app launches."""
import json
from pathlib import Path
import re
import tomllib


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins/nightr"
CANONICAL = "/Applications/Nightr.app/Contents/MacOS/nightr-native"
TOOLS = {
    "nightr_status", "nightr_config", "nightr_setup_status", "nightr_start",
    "nightr_stop", "nightr_hotspot_retry_now", "nightr_hotspot_try_again",
    "nightr_hotspot_skip",
}


def read_json(path):
    return json.loads((PLUGIN / path).read_text())


def test_hosts_share_identity_and_portable_components():
    portable = read_json("plugin.json")
    claude = read_json(".claude-plugin/plugin.json")
    assert portable.pop("$schema") == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
    assert portable == claude
    assert portable["name"] == "nightr"
    assert re.fullmatch(r"0\.\d+\.\d+", portable["version"])
    assert portable["repository"] == "https://github.com/agenthangar/nightr"
    assert portable["license"] == "MIT"
    # Fixed default locations discover the same components without overlays.
    assert "skills" not in portable and "mcpServers" not in claude
    assert list(PLUGIN.rglob("SKILL.md")) == [PLUGIN / "skills/nightr/SKILL.md"]


def test_host_launches_cannot_diverge_or_bootstrap():
    portable = read_json("mcp.json")
    assert portable.pop("$schema") == "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json"
    assert portable == read_json(".mcp.json")
    assert portable == {"mcpServers": {"nightr": {
        "type": "stdio", "command": CANONICAL, "args": ["mcp"],
    }}}
    # A strict package allowlist excludes executable hooks, dependency managers,
    # alternate instructions and host-specific skills that could change intent.
    assert {str(p.relative_to(PLUGIN)) for p in PLUGIN.rglob("*") if p.is_file()} == {
        "plugin.json", "mcp.json", ".mcp.json", ".claude-plugin/plugin.json",
        "skills/nightr/SKILL.md", "README.md",
    }
    assert not any(p.is_symlink() for p in PLUGIN.rglob("*"))


def test_shared_skill_covers_exact_tool_surface_and_global_action_policy():
    skill = (PLUGIN / "skills/nightr/SKILL.md").read_text()
    assert set(re.findall(r"`(nightr_[a-z_]+)`", skill)) == TOOLS
    assert "Begin with `nightr_status`" in skill
    assert "All eight tools accept exactly `{}`" in skill
    assert "Never automatically start or stop" in skill
    assert "do not\nask for another confirmation" in skill
    assert "outcome is uncertain: do not replay it automatically" in skill
    assert "Stop remains available" in skill
    assert "does not provide a per-session lease or reference count" in skill
    assert "global state for the current\nMac user" in skill
    assert "Never request, read or expose passwords" in skill
    assert "signed\nrelease containing this MCP support is not yet available" in skill


def test_manual_setup_docs_preserve_native_prerequisite_and_host_paths():
    docs = (ROOT / "docs/plugins.md").read_text()
    assert CANONICAL in docs
    assert "claude --plugin-dir /absolute/path/to/nightr/plugins/nightr" in docs
    assert '"path": "./plugins/nightr"' in docs
    assert "approved-partner\nallowlisting" in docs
    assert "signed release containing this support is not\nyet available" in docs
    assert "Direct MCP registration does not load the skill" in docs
    assert "manually add" in docs
    assert "codex plugin add nightr@nightr-local" in docs
    toml_examples = re.findall(r"```toml\n(.*?)```", docs, re.DOTALL)
    parsed = [tomllib.loads(example) for example in toml_examples]
    assert {"plugins": {"nightr@nightr-local": {"enabled": True}}} in parsed
    assert {"mcp_servers": {"nightr": {"command": CANONICAL, "args": ["mcp"]}}} in parsed
