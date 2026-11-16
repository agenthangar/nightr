#!/usr/bin/env python3
"""Show native MCP discovery and tools without invoking controller operations."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    options = parser.parse_args()
    meta = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {}}
    messages = [{"jsonrpc": "2.0", "id": index, "method": method, "params": {"_meta": meta}}
                for index, method in enumerate(["server/discover", "tools/list"], 1)]
    with tempfile.TemporaryDirectory(prefix="nightr-mcp-preview-") as home:
        env = {key: value for key, value in os.environ.items() if not key.startswith("COV_CORE_")}
        env.update(HOME=home, XDG_CONFIG_HOME=home + "/config", XDG_STATE_HOME=home + "/state")
        result = subprocess.run([str(options.binary.resolve()), "mcp"],
                                input="".join(json.dumps(message) + "\n" for message in messages),
                                capture_output=True, text=True, env=env, timeout=5, check=True)
    if result.stderr:
        raise RuntimeError(result.stderr)
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(responses) == 2 and all("result" in response for response in responses)
    print("Nightr MCP · native protocol preview")
    print("Discovery and tool definitions only. No controller or machine operations invoked.\n")
    print(json.dumps(responses[0]["result"], indent=2))
    print("\nAvailable tools (all accept {}):")
    for tool in responses[1]["result"]["tools"]:
        kind = "read only" if tool["annotations"]["readOnlyHint"] else "explicit action"
        print(f"\n{tool['name']} · {kind}\n  {tool['description']}")


if __name__ == "__main__":
    main()
