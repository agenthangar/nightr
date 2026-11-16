#!/usr/bin/env python3
"""Safe native MCP checks: fake backend + protocol-only real process traffic."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
META = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}}


def exchange(process, message, *, fragmented=False):
    data = json.dumps(message).encode() + b"\n"
    if fragmented:
        process.stdin.write(data[:7])
        process.stdin.flush()
        data = data[7:]
    process.stdin.write(data)
    process.stdin.flush()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(5), "MCP response timed out"
    line = process.stdout.readline()
    assert line.endswith(b"\n") and len(line) <= 65_537, line
    response = json.loads(line)
    assert response["jsonrpc"] == "2.0" and response["id"] == message["id"]
    return response


def process_checks(binary, env):
    process = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        discover = exchange(process, {"jsonrpc": "2.0", "id": "discover", "method": "server/discover", "params": {"_meta": META}}, fragmented=True)
        assert discover["result"]["resultType"] == "complete"
        assert discover["result"]["capabilities"] == {"tools": {}}
        tools = exchange(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {"_meta": META}})
        assert len(tools["result"]["tools"]) == 8
        invalid = exchange(process, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"_meta": META, "name": "nightr_start", "arguments": {"force": True}}})
        assert invalid["error"]["code"] == -32602
        if sys.platform != "darwin":
            unsupported = exchange(process, {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"_meta": META, "name": "nightr_setup_status", "arguments": {}}})
            assert unsupported["result"]["structuredContent"]["helperReadiness"] == "unsupported"
        process.stdin.close()
        assert process.wait(3) == 0
        assert process.stdout.read() == b"" and process.stderr.read() == b""
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    legacy = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        initialized = exchange(legacy, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "synthetic-check", "version": "1"}}})
        assert initialized["result"]["protocolVersion"] == "2025-11-25"
        legacy.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{}}}\n')
        legacy.stdin.flush()
        listed = exchange(legacy, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert len(listed["result"]["tools"]) == 8 and "resultType" not in listed["result"]
        legacy.stdin.close()
        assert legacy.wait(3) == 0 and legacy.stderr.read() == b""
    finally:
        if legacy.poll() is None:
            legacy.kill()
            legacy.wait()
    for args in [["mcp", "--help"], ["mcp", "--port", "8080"]]:
        result = subprocess.run([binary, *args], input=b"", capture_output=True, env=env, timeout=3)
        assert result.returncode != 0 and result.stdout == b"" and b"usage: nightr mcp" in result.stderr
    eof = subprocess.run([binary, "mcp"], input=b"", capture_output=True, env=env, timeout=3)
    assert eof.returncode == 0 and eof.stdout == eof.stderr == b""
    blocked = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        # Do not read stdout: a backpressured peer must cause bounded shutdown.
        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {"_meta": META}}
        blocked.stdin.write((json.dumps(request).encode() + b"\n") * 64)
        blocked.stdin.flush()
        assert blocked.wait(5) == 0
    finally:
        if blocked.poll() is None:
            blocked.kill()
            blocked.wait()
    print("MCP process checks passed (discovery/list/invalid-arguments only)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="nightr-mcp-check-") as temporary:
        temporary = Path(temporary)
        env = {key: value for key, value in os.environ.items() if not key.startswith("COV_CORE_")}
        env.update(HOME=str(temporary), XDG_CONFIG_HOME=str(temporary / "config"), XDG_STATE_HOME=str(temporary / "state"))
        smoke = temporary / "mcp-smoke"
        subprocess.run(["swiftc", "-parse-as-library", *sorted(map(str, (ROOT / "Sources/NightrMCP").glob("*.swift"))), str(ROOT / "native-tests/MCPProtocolSmoke.swift"), "-o", str(smoke)], check=True, env=env, timeout=120)
        subprocess.run([smoke], check=True, env=env, timeout=10)
        process_checks(str(options.binary.resolve()), env)


if __name__ == "__main__":
    main()
