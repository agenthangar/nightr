# Distribution and power-helper boundary

Nightr targets macOS 13 or later on Apple Silicon and Intel. Release artifacts
are not available until genuine Developer ID signing and notarization have
completed. Contributor builds are not installable production releases.

## Installation

The release is `Nightr-VERSION-universal.dmg`. Open its signed **Nightr.pkg** to
install the root-owned `/Applications/Nightr.app` and the owned command link
`/usr/local/bin/nightr`. The package contains the native app, controller, narrow
power helper, network worker and both pinned standalone Python runtimes. No
Xcode, developer tools, separately installed Python or source build is needed.
The DMG also contains an app copy for inspection; dragging that copy does not
complete the required root-owned package installation.

Homebrew distribution uses a tap cask with the `pkg "Nightr.pkg"` artifact;
`brew install --cask agenthangar/tap/nightr` is the planned first-install route.
Do not advertise the cask as available until that tap publishes it. `t` can use
the same cask or Nightr's verified direct installer without installing Homebrew.
The signed package's command link is the CLI; a separate CLI formula is not
needed. CLI-only use of this package does not require the menu bar or a login
agent.

After installation, `nightr setup` opens explicit power-helper authorization.
The helper is a launchd-supervised `SMAppService.daemon` embedded in the signed
app. CLI-only setup authorizes that daemon without registering the login agent;
the app and CLI then use the same helper. Ordinary protection runs do not invoke
sudo or repeat an administrator prompt. This shared supervised route replaces
the extracted monitor's older direct `sudo pmset` approach. There is no
unsupervised privileged stdio engine, privileged worktree execution or silent
helper authorization. Protection starts only with enabled user intent.

The app's optional login service is the bundled `ai.nightr.agent.plist` registered
through `SMAppService.agent`. A nonzero crash may restart it after throttling;
the controller's durable crash ledger bounds protection retries. Normal Stop
and Quit exit successfully and preserve disabled intent. CLI-only setup never
registers this service.

## Package ownership and updates

The shared stdlib installer is `scripts/nightr_install.py`. Its internal API is
`main(["install" | "update" | "check", "--json"])`; `t` vendors this same file.
`check` creates no persistent state, prompt, install or service registration.
It returns `installed`, `owner`, `version`, `availableVersion` and
`updateAvailable`. Failure returns a JSON `error` and nonzero exit status.
`adopt-homebrew` verifies a cask receipt and canonical signed app;
`adopt-direct` verifies the package receipt, canonical app and published release,
then obtains a verified rollback artifact. Adoption preserves the package owner.

The authoritative per-user package record is
`~/Library/Application Support/Nightr/installation.json` (schema version 1):
`owner` (`direct` or `homebrew`), `appPath`, `version`, `teamID`, and direct-copy
`artifactSHA256`. Integration opt-in maintained by `t` is a separate record.
Neither enabling the integration nor uninstalling `t` transfers package ownership.
An update never installs a missing app. Owner conflicts fail with repair guidance.

A package lock excludes concurrent operations for one user. Homebrew-owned
updates delegate to `brew upgrade --cask agenthangar/tap/nightr`. Direct updates
fetch the GitHub release manifest over HTTPS, enforce the repository's exact
release-asset URL, version/protocol/architecture fields and SHA-256, then mount
the DMG read-only beneath the root-protected `/Volumes` namespace. The app's
identifier and Developer ID team must match, the app and nested executables
must pass strict signature validation, and the app and installer must pass
Gatekeeper assessment. The package needs a matching Developer ID Installer
signature. The only elevated operation is Apple's fixed `/usr/sbin/installer`
with that verified package on the immutable mounted volume. Unattended users
without existing root authorization receive an actionable error.

Updates quiesce the canonical controller through its signed internal
`package prepare-update` operation while preserving enabled intent. They keep
configuration, Keychain entries and runtime state in place. Direct updates
retain the prior checksummed DMG in the user's package cache, verify and mount
it again before rollback, and coordinate `package finish-update` only after
verifying the installed app. A failed rollback leaves protection stopped and
reports repair instructions; it does not claim success. Apple's Installer and
receipts are not an atomic filesystem swap. Homebrew owns its rollback policy;
Nightr resumes only a verifiably valid package after a Homebrew failure.

## Privileged power protocol

The helper exports only four fixed operations: acquire, renew, release and
read-only status. Renew may apply a validated battery threshold to an existing
lease. No operation accepts executable paths, shell text, environment variables,
file paths or arbitrary power keys. The root helper invokes only fixed
`/usr/bin/pmset -g` and `/usr/bin/pmset -a disablesleep 0|1` operations with a
five-second execution bound and capped output. Battery safety uses IOPowerSources.

Both XPC directions require Apple's signing anchor, the actual configured
Developer ID team, and the exact app/controller/helper signing identifier.
Unsigned or missing-team builds fail closed. App and controller identifiers are
`ai.nightr.app` and `ai.nightr.controller`; the service and helper identifier is
`ai.nightr.powerhelper`. The helper verifies its own signature and canonical
root-owned bundle contents. The shared `/Applications` directory is normally
admin-writable; ServiceManagement's signed embedded-daemon validation and explicit
OS authorization form that namespace boundary. Nightr never elevates an
executable selected from it through sudo.

One root-held global lock covers all users. A lease binds the authenticated XPC
UID, connection and random generation. A separate one-second helper timer
expires the lease after 30 seconds using `mach_continuous_time`, including time
spent suspended. Battery cutoff, disconnect and release restore the held change.
Launchd restarts a crashed helper so its journal is recovered before acquisition.
The journal directory is fixed at `/var/db/ai.nightr.powerhelper`, root-owned
0700; its 0600 regular file is accessed relative to a verified descriptor with
no symlink following. Pending original-zero state is atomically persisted and
fsynced before mutation. Active state follows verified mutation. A pending or
active journal restores zero on startup. A failed restoration retains the
journal and blocks acquisition.

`disablesleep` is a global OS setting with no kernel ownership token. Nightr
requires an **exclusive writer agreement**: other power utilities must not write
it while Nightr holds it. Nightr refuses a preexisting value of one. An observed
external reset to zero invalidates the lease and never rearms automatically.
An external write of the same value is unknowable, so Nightr does not claim
strict OS ownership or interference-free coexistence with other writers. Its
safe original-zero restoration is conditional on that agreement.

## Release manifest and signing

Tags are independently patch-versioned, beginning with `v0.1.0`. Each release
publishes exactly the universal DMG and `nightr-release.json`:

```json
{
  "schemaVersion": 1,
  "version": "0.1.0",
  "platform": "macos",
  "minVersion": "13.0",
  "architectures": ["arm64", "x86_64"],
  "teamID": "ACTUALTEAM",
  "bundleID": "ai.nightr.app",
  "controllerID": "ai.nightr.controller",
  "helperID": "ai.nightr.powerhelper",
  "protocolVersion": 1,
  "asset": {
    "name": "Nightr-0.1.0-universal.dmg",
    "url": "https://github.com/agenthangar/nightr/releases/download/v0.1.0/Nightr-0.1.0-universal.dmg",
    "sha256": "ACTUAL_ARTIFACT_SHA256",
    "size": 123
  }
}
```

The example placeholders are not a usable manifest or an available release.
The GitHub HTTPS release is the acquisition authority; a bare detached signature
without a separately pinned trust root would add no authenticity and is omitted.
Apple Developer ID/notary validation is independently required for execution.

The manual release workflow requires a reviewed stable tag on `main`, configured
release environment and genuine Developer ID Application **and Installer**
certificates. Configuration names are `NIGHTR_TEAM_ID`,
`NIGHTR_APPLICATION_IDENTITY`, `NIGHTR_INSTALLER_IDENTITY`,
`NIGHTR_SIGNING_CERTIFICATE_P12`, `NIGHTR_SIGNING_CERTIFICATE_PASSWORD`,
`NIGHTR_NOTARY_KEY_P8`, `NIGHTR_NOTARY_KEY_ID`, and `NIGHTR_NOTARY_ISSUER_ID`.
The exported P12 must contain both signing identities and their private keys.
Signing uses hardened runtime and secure timestamps; the app, package and DMG
are notarized and stapled. `scripts/verify_release.py` verifies the actual mounted
artifact, signatures, package, architecture slices, bundled runtimes and tickets
without installing, launching UI, changing power or touching credentials.

`packaging/runtime-lock.json` pins python-build-standalone release 20261110,
CPython 3.13.18, both architecture URLs and SHA-256 digests verified from that
upstream release. The build bundles and signs all runtime Mach-O files. Release
construction fails when signing or notarization configuration is absent. No
release is published until all acceptance checks pass; local unsigned builds
are not evidence of signed-release readiness.
