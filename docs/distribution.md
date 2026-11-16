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
through `SMAppService.agent` for headless controller restoration, paired with
`SMAppService.mainApp` for the visible menu bar app on subsequent logins. The
agent’s `--controller-only` mode remains headless; a visible app connects to an
existing owner instead of creating a second controller. A nonzero crash may restart it after throttling;
the controller's durable crash ledger bounds protection retries. Normal Stop
and Quit exit successfully and preserve disabled intent. CLI-only setup never
registers this service.

## Package ownership and updates

The shared stdlib installer is `scripts/nightr_install.py`. Its internal API is
`main(["install" | "update" | "check", "--json"])`; `t` vendors this same file.
`check` creates no persistent state, prompt, install or service registration.
It returns `installed`, `owner`, `version`, `availableVersion` and
`updateAvailable`. Failure returns a JSON `error` and nonzero exit status.
`adopt-homebrew` verifies a real cask receipt, the approved cask contract and
the canonical signed app. `adopt-direct` verifies the package receipt, canonical
app and published release, then obtains a verified rollback artifact. Adoption
preserves an existing package owner.

For a manually installed signed package without an ownership record,
`nightr setup --direct-updates` explicitly claims direct update ownership. When
Homebrew is unavailable, this requires both standard Nightr cask receipt
locations to be authoritatively absent. It also asserts that a custom-prefix
Homebrew does not own this copy; Nightr cannot prove absence in an unknown
custom prefix. The app's signatures, root ownership, team, version, package
receipt and rollback artifact still have to verify. A known Homebrew owner,
any Nightr cask receipt, or a failed receipt query blocks the claim. Automatic
adoption of an unowned app remains conservative and reports this explicit setup
route instead of guessing.

The authoritative per-user package record is
`~/Library/Application Support/Nightr/installation.json` (schema version 1):
`owner` (`direct` or `homebrew`), `appPath`, `version`, `teamID`, and direct-copy
`artifactSHA256`. Integration opt-in maintained by `t` is separate. Neither
enabling that integration nor uninstalling `t` transfers package ownership.
An update never installs a missing app. Stale user records are checked against
the actual signed installation and package receipt before replacement.

Direct updates fetch the GitHub release manifest over HTTPS and enforce its
exact repository asset URL, version, protocol, architectures and SHA-256. The
DMG is mounted read-only beneath the root-protected `/Volumes` namespace. App
and nested executable identifiers and Developer ID team must match; strict
signature validation and Gatekeeper assessment must pass. The package also
needs a matching Developer ID Installer signature. Apple's fixed system
Installer reads that verified immutable package. Unattended callers without
existing root authorization receive an actionable error.

A per-user lock excludes competing user operations. The signed package creates
stable root-owned machine locks beneath `/Library/Application Support/Nightr`:
`update.lock` uses a whole-file POSIX record lock and `controller.lock` uses
`flock`. The managed updater holds the exclusive update gate, quiesces its
controller while preserving enabled intent, then requires exclusive controller
access. Another user's live controller makes replacement fail. Controller
startup checks the root transaction marker both before and after taking its
shared guards.

The signed compiled installer guard is included in the package's Scripts and
installed in the root-owned privileged-tools directory. Before any payload
write, it publishes a durable pending root marker. Managed transactions bind
the marker to the kernel's update-lock owner PID, UID, process birth and boot
UUID, plus that user's private bounded request, exact package path and random
transaction UUID. The guard rechecks ownership and controller exclusion after
marker publication. Manual package installation uses the same marker barrier,
so ending preinstall does not reopen controller startup during payload writes.
Unrelated entries at the package's public command path are rejected.

Preinstall and postinstall must use the same root-owned extracted Scripts guard
vnode and directory. This continuity is a **required, unverified integration
assumption**, not evidence from unit tests or compilation. Each stage must also
come through the pinned Apple PackageKit service. A mismatch fails closed and
retains the marker. Verify the complete signed install and upgrade flow in an
authorized disposable macOS environment before public release.

Direct updates retain the prior checksummed DMG for rollback. Automatic
rollback is allowed only after the root guard has recorded verified completion
of the new payload. A pending operation may still be running in PackageKit
after its client fails or times out, so it cannot start a second installation
or clear the marker. Such an interrupted or orphaned transaction requires a
reboot before repair. After reboot, reinstalling the recorded original or new
signed package preserves the marker and root generation, binds the new trusted
Scripts invocation, and clears the barrier only after verified completion.
A complete signed app with its matching receipt can also be verified by the
fixed guard's explicit repair operation after reboot. Recorded original and
new versions remain available even if a rollback attempt failed.

Configuration, Keychain entries and runtime state remain in place. All fallible
cache and ownership-record work completes before the managed guard finishes
and locks are released. Only then may `package finish-update` resume the prior
owned intent, subject to a fresh durable Stop check. A resume failure reports
the committed version and never rolls back an already resumed controller.
Apple's Installer and receipts are not an atomic filesystem swap.

Homebrew uses only the reviewed PKG-only cask template. The exact qualified
cask, version, URL, checksum and absence of extra hooks are checked before the
same resolved Homebrew executable runs with automatic updating and API
installation disabled. This is a preflight audit, not atomic source pinning;
concurrent changes by the account managing Homebrew or its tap are outside the
guarantee. An unavailable or different contract fails closed for a Homebrew-owned
copy; a fresh installation may use the verified direct package instead.

Nightr releases its update gate while Homebrew invokes the guarded package.
On every exit it reacquires the gate and requires an absent marker, valid
actual app/guard/nested signatures, matching package receipt and real Homebrew
receipt before updating ownership metadata or resuming. Homebrew owns its
rollback policy. Python never rolls back its payload or clears another
transaction's marker. A Homebrew failure remains a failure even when the
original valid version can safely resume.

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

The manual **Signed macOS candidate** workflow is candidate-only: it has no
publication step or contents-write permission. Dispatch `release.yml` on `main`
with a stable patch `version` (for example `0.1.0`). It checks out the exact
dispatch SHA, uses the hosted `macos-15` image with Xcode 26.2 explicitly selected,
and prints the Xcode/Swift versions. A stable tag is not required for a candidate.
The `release` environment requires genuine Developer ID Application **and
Installer** certificates. Configuration names are `NIGHTR_TEAM_ID`,
`NIGHTR_APPLICATION_IDENTITY`, `NIGHTR_INSTALLER_IDENTITY`,
`NIGHTR_SIGNING_CERTIFICATE_P12`, `NIGHTR_SIGNING_CERTIFICATE_PASSWORD`,
`NIGHTR_NOTARY_KEY_P8`, `NIGHTR_NOTARY_KEY_ID`, and `NIGHTR_NOTARY_ISSUER_ID`.
The exported P12 must contain both signing identities and their private keys.
Credentials stay in the existing ephemeral workflow keychain and are removed
before installer acceptance; cleanup runs on failure too. Do not run signing
or acceptance on a contributor's Mac.

Signing uses hardened runtime and secure timestamps; the app, package and DMG
are notarized and stapled. Every notarization must return `Accepted` and a
submission ID. Failures retain bounded compiler/signing diagnostics and attempt
to fetch the notary log. `scripts/verify_release.py` verifies the actual mounted
artifact, signatures, package, architecture slices, bundled runtimes and tickets
without installing, launching UI, changing power or touching credentials.

After safe unit/coverage and Swift checks and the signed build, the candidate
workflow runs `scripts/check_installer.py --disposable-github-runner` against the
actual DMG. The script also requires GitHub-hosted macOS runner markers and
refuses existing Nightr apps, command links, guards, root state or package
receipts; it never removes them. It verifies the DMG read-only, mounts it
read-only, installs its signed PKG through Apple's noninteractive Installer,
and verifies the expected team/version, app and guard signatures, matching
receipt, root-owned canonical command link, payload ownership, exact root lock
modes and absent transaction marker. It repeats installation of the **same
package** and repeats those checks. Both passes are required to establish the
PackageKit Scripts-guard vnode continuity assumption for these paths. A failed
guard remains fail-closed; the script never clears a pending marker.

Installed CLI `--version`/`--help` and the native bundled Python's isolated SSL
import run with temporary HOME/XDG paths. A read-only launchd query must show the
power helper remains unregistered. `setup --check` is deferred because it uses
production power/network sampling; helper readiness is not asserted. The test
does not launch UI, register services or start protection. Helper/login
authorization, a **version-changing update**, and reboot recovery remain
**untested** by this candidate workflow and are still required before public
release. Unit tests and successful candidate checks do not satisfy those gates.

The always-run artifact step retains only `dist`'s DMG, generated manifest/cask
and `installer-acceptance.json`, named with version, dispatch SHA and run ID, for
14 days. An initialized report records `not_started` if build or earlier checks
fail; acceptance records each pass independently and a bounded error on failure.
Review both the report and the job logs. A manifest/cask in this artifact is a
candidate template: its future release URL is not evidence of a published asset.
This workflow cannot create a GitHub release, even after limited acceptance
passes. Publication remains deferred until the broader acceptance is complete
and a reviewed publication path is added. Track that work in
[issue #3](https://github.com/agenthangar/nightr/issues/3).

### Disposable managed-upgrade acceptance

The separate manual **Signed managed upgrade acceptance** workflow
(`upgrade-acceptance.yml`) accepts `baseline_run_id` and `final_run_id`: successful
main-dispatch **Signed macOS candidate** runs for `0.0.0` and `0.1.0` respectively.
Both candidates must come from the **same source SHA**, and that SHA must be an
ancestor of the acceptance workflow's exact checked-out main commit. This permits
new acceptance tooling to validate older retained products without changing the
notarization checkpoint workflow's stricter same-SHA recovery rule. Keep main
fixed while any pending checkpoint still requires that rule.

Configure the public repository variable `NIGHTR_TEAM_ID` independently of the
candidate files; this job has no release environment or signing secrets. The
fetch step alone receives a read-only GitHub token. It verifies the fixed
repository/workflow, successful manual main runs, exact artifact names and run
ownership, bounded downloads, four flat regular-file ZIP entries, passing fresh
and reinstall reports, manifest identity/team and actual DMG hashes. Downloaded
casks are never executed. These are retained candidate artifacts, not published
release acquisition.

On a fresh GitHub-hosted `macos-15` runner, the existing `check_upgrade.py`
acceptance harness then runs unchanged under its real nonroot UID/HOME and PTY.
It installs the signed baseline, performs explicit verified direct adoption and
a real managed `0.0.0` to `0.1.0` update, and checks the resulting signed payload,
receipt, root marker, private request, owner/cache records and locks. No signing,
helper/login authorization or protection starts. Public release HTTPS acquisition,
controller `finish-update`/resume and rollback/reboot recovery remain untested.

The workflow always retains **only** `candidate-provenance.json` and
`upgrade-acceptance.json`, named with acceptance SHA/run ID, for 14 days. Provenance
records candidate source SHA separately from workflow SHA, authenticated run and
artifact IDs, archive/manifest/DMG hashes, available GitHub artifact digests and
the precise input acceptance results. A fetch failure leaves upgrade acceptance
`not_started`; a passing report is limited acceptance, not release approval.

### Resuming slow notarization

Candidate builds retain a separate `nightr-checkpoint-VERSION-SHA-RUN_ID`
Actions artifact on normal failure or timeout. Its explicit file allowlist is
`checkpoint.json`, the exact submitted `Nightr.zip`, the signed universal
`ai.nightr.installguard`, and (once constructed) the exact submitted `Nightr.pkg`
and `submitted.dmg`, plus bounded Apple logs. No source, build cache, credentials,
keychain, HOME or environment dump is retained. Submitted bytes and hashes stay
unchanged; stapling modifies separate working copies. Checkpoints are recovery
inputs, **not verified installable releases**. Abrupt runner loss before the
always-run upload may still lose them.

Submission and waiting are separate. The build atomically records each returned
Apple submission ID before waiting up to 25 minutes. A timeout or `In Progress`
result leaves that submission pending and retains its signed product; it does
not reject it or authorize another submission. `Invalid`/`Rejected` is a failed
notarization with its bounded log. An upload that fails before returning an ID
is recorded as `submission_unknown`; reconcile Apple history before proceeding.
The tool never automatically resubmits an unknown or pending submission.

To resume, dispatch **Signed macOS candidate** (`release.yml`) on `main`, with
the same `version` and `resume_run_id` set to the completed run that uploaded the
checkpoint. Leave `resume_run_id` blank only to start a new build. The workflow
checks the GitHub repository, known workflow identity, main-dispatch event, exact
source SHA, run ID and artifact name before accepting those inputs. The selected
run must be complete, and **its source SHA must equal the new dispatch SHA**:
main must remain at that commit for this initial recovery path. An older
pre-checkpoint run has no recoverable product merely because Apple has its ID.

The trusted checked-out tooling validates the bounded checkpoint, every product
size/hash, safe app ZIP paths/symlinks, actual signing team, bundle/package
version and universal executable slices. It executes no artifact code during
credential import or recovery. It waits on the original app/package/DMG IDs,
requires Apple's `Accepted` result, checks available notary-log artifact binding,
and staples/verifies working copies before continuing. Installer acceptance
still runs only after signing-state cleanup. Candidate-only publication and all
remaining release-acceptance requirements remain in force.

`packaging/runtime-lock.json` pins python-build-standalone release 20261110,
CPython 3.13.18, both architecture URLs and SHA-256 digests verified from that
upstream release. The build bundles and signs all runtime Mach-O files. Release
construction fails when signing or notarization configuration is absent. No
release is published until all acceptance checks pass; local unsigned builds
are not evidence of signed-release readiness.
