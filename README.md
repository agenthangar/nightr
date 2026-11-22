# Nightr

Keep your Mac awake while coding agents work.

Nightr is a native macOS menu bar app and CLI, extracted from
[AgentHangar t](https://github.com/agenthangar/t). Both interfaces use one
controller, one set of preferences and one Stop action.

**Pre-release:** the native implementation is under validation. A signed,
notarized installer has not been published. Do not use the source checkout as a
production power-management installation.

## Installation

The release package will include the app, CLI, power helper and Python runtime.
Users will not need Xcode, developer tools or a separate Python installation.
Once the signed release and matching Homebrew cask are published, install with:

```sh
brew tap agenthangar/tap
brew install --cask agenthangar/tap/nightr
```

AgentHangar t users can run `t install` and choose **Nightr** under
**Desktop Apps**. If you confirm the Homebrew installation, t adds the
AgentHangar tap if needed and verifies the published cask. The signed macOS
installer inside the DMG is the download alternative. It needs the public signed
release and works without Homebrew. Installation requires administrator
authorization. Run `nightr setup` afterward to approve the helper separately.

```sh
nightr setup                 # helper readiness and desktop setup
nightr setup --cli-only      # authorize the helper without a login app
nightr config                # everyday preferences
nightr start
nightr status --json         # read-only; does not start a controller
nightr stop
```

Run `nightr update` to update the installed package through its existing owner.

Use `nightr` without a subcommand for foreground monitoring. `nosleep` remains a
compatibility name. Existing config and Keychain service names are preserved.
Stop remains stopped across wake and login. Protection can resume after a normal
wake or verified internet recovery when enabled; agents manage their own
reconnections. Nightr does not execute work while the Mac is asleep.

Settings cover agent/internet checks, lid/display behavior, battery protection
and a saved hotspot. Hotspot recovery has a bounded attempt budget, independently
verified internet checks, and Saved/Nearby/Manual network selection. Nightr cannot
remotely switch on an iPhone hotspot. Network wake settings are not part of Nightr.

The menu and native CLI also show CPU and GPU utilization when available, loaded
models and runtime details. An opt-in Protection setting lets a local inference
integration keep the Mac awake while a model is working, including offline.
See [local model activity](docs/cli.md#local-model-activity).

Closed-lid protection uses a signed, authorized helper with an expiring lease.
It requires exclusive control of macOS's global sleep-disable setting; other
sleep utilities must not change that setting during a Nightr session.

See [distribution and signing](docs/distribution.md), the
[implementation plan](docs/implementation-plan.md), and the
[upstream attribution](docs/provenance.md). The extracted source-only CLI and its
legacy behavior are documented in [the compatibility guide](docs/cli.md).

## Agent controls

The native CLI provides a local stdio MCP server with `nightr mcp`. Its eight
tools inspect policy and readiness or explicitly Start, Stop and control a
bounded hotspot cycle. Read-only tools never launch the controller. Protection
is shared per user: connecting, disconnecting and finishing an agent task never
change it. Stop affects every client. See [MCP and plugin setup](docs/plugins.md)
and [the command contract](docs/cli.md#mcp-server). Signed release availability
remains subject to the pre-release notice above.

## Development

Contributor builds require a Swift toolchain and the macOS SDK. This requirement
does not apply to the planned prebuilt release. `swift build` compiles native
targets. `swift test` requires XCTest; Linux CI exercises portable logic and full
Xcode supplies macOS XCTest. Native desktop tests are opt-in.

After `swift build --product nightr-native`, a protocol-only working preview is
available with `python3 scripts/preview_mcp.py --binary .build/debug/nightr-native`.
It shows native discovery and tool definitions, without invoking the controller
or machine operations. `python3 scripts/check_mcp.py --binary .build/debug/nightr-native`
runs the fake protocol harness and bounded stdio process checks.

```sh
python3 -m pip install -r requirements-dev.txt
python3 -m pytest --cov --cov-fail-under=97
```

Tests use temporary user state and mocked power/network/credential operations.
Never install helpers, alter power settings, join Wi-Fi or change Keychain as a
test on a developer's Mac. `design-preview/` is a separate browser simulation;
`site/` is the static product website.
