# Nightr launch plan

Status: production implementation approved by the user on 2026-11-14 after
interactive design review. Moon + spark concept 1 remains locked. Remove Wake
for network access from the product; normal wake/login recovery remains in scope.

Extraction checkpoint: standalone launchers and helpers are implemented locally
and reviewed. Immutable snapshot `73d94f1d-76d7-46e1-8e85-57b64ffe08c5` passed
550 tests with one native-UI opt-in skip and 98.69% Python coverage. Python parsing
and individual zsh syntax checks passed. This validates extraction only; it does
not validate the planned app, controller, recovery changes or installation.

Preview revision checkpoint: `design-preview/index.html` implements the requested
compact Settings window, locked moon + spark, prebuilt download simulation,
independent internet verification and prominent inactive AgentHangar Nightr tab.
Snapshot `60aec03c-0dce-4579-8f75-c43b47d223d3` passed 33 offline model/flow checks.
Browser review confirmed readable sectioned Settings with retained drafts, the
prominent inactive tab and simulated DMG → Applications → launch → helper flow.
The final network-return path is verified by model checks and code review.
The user has approved proceeding to production implementation. No native app,
helper, login service or website deployment was installed at this checkpoint.

Tracking:
- Nightr: https://github.com/agenthangar/nightr/issues/1
- t integration: https://github.com/agenthangar/t/issues/454
- AgentHangar listing: https://github.com/agenthangar/agenthangar.github.io/issues/10

## Checkpoint 1 — extract and review the design

Extract the existing CLI/helpers/tests with upstream MIT attribution. Remove
runtime imports of t, preserve behavior/config/Keychain identifiers, and provide
the nightr executable plus nosleep compatibility. Keep the live installed t and
Nosleep untouched. Establish safe standalone checks and packaging scaffolding.

Create an interactive local HTML mockup for: native menu bar app and settings;
foreground/background CLI and JSON/plain output; complete t config navigation;
the approved moon + spark on light/dark menu bars and app/web/favicon/social surfaces;
responsive nightr.ai and AgentHangar product previews. All surfaces share sample
state and support Start/Stop, wake/login, battery and hotspot recovery scenarios.
Show the revised interface in the browser for explicit UI approval before
substantial controller/app implementation or pushing UI work. Icon approval is
already recorded and does not approve the revised interface.

## Shared controller and native app

macOS 13+, SwiftUI menu bar, prebuilt universal distribution for Apple Silicon and
Intel. App, CLI, power helper and required runtime ship together; retain a
CLI-only option. Prefer Homebrew or t installation as described below; a direct
DMG remains available. Users explicitly authorize the power helper during setup.
No Xcode, developer tools or separate Python
installation is required. Contributor builds belong in separate developer docs.
Keep foreground
commands and flags; add explicit start/stop and read-only status JSON. A private
versioned JSON Unix socket coordinates a single per-user monitor, checks caller
ownership, and rejects incompatible versions/conflicting run settings.

The app saves and applies validated settings at a loop boundary without dropping
the hold. CLI configuration retains next-run semantics. Preserve all display,
lock, agent/internet, requirement, grace/retry, battery and hotspot behaviors.
Never unlock the Mac. Preserve old configuration and Keychain names in v1.

Settings follows the compact [Rectangle reference](https://rectangleapp.com/assets/images/shortcutScreenshot.jpg):
approximately 600px wide; General, Protection, Connectivity and Advanced sections;
15px labels, 13px help and aligned rows around 30–34px. Keep Save/Cancel/Reset
visible and one draft across sections. Preserve the underlying settings and
normal dialog focus containment, tab arrows, Escape and return focus. The app
hides the separate proposed inactivity timer until its relationship to check
grace is defined; retain its stored value and CLI compatibility meanwhile. CLI
configuration retains the staged rail interaction.

Explicit setup installs a narrow root-owned helper for fixed power operations;
no caller-supplied commands or privileged execution of worktree code. Leases and
a recovery journal restore owned power changes after failures. CLI-only use shares the same supervised signed helper, without registering a
login app. The original proposed sudo monitor route is superseded: a standalone
privileged process cannot guarantee cleanup after abrupt termination. No repeated admin prompts for ordinary app runs.

## Recovery and hotspot additions

Desktop setup launches at login by default, but protection starts only after the
user enables it. Persist desired enabled state separately from process health.
Normal wake/login resumes enabled protection; explicit Stop/foreground Ctrl-C/
Stop and Quit persists disabled. Automatic inactivity release waits for the next
normal wake; connectivity-only release waits for verified recovery while awake
or a fresh check after normal wake. Never immediately respawn and defeat sleep. Low battery
pauses until safe power conditions. Refresh samples/grace at wake, avoid rearming
on maintenance wakes, and bound crash restart attempts. CLI-only installation
does not add a login service.

Distinguish underlying path availability from the last verified internet result.
Normal wake and network path changes request a bounded check (10-second cap),
coalescing concurrent events into one active operation. Eligible periodic checks
start at the saved Check interval (30 seconds by default). Verification stays independent of hotspot join
eligibility and continues after the configured join budget is exhausted without
an extra join or another prompt. Association alone is not recovery. Only verified internet
clears the outage ledger and refreshes samples; Nightr then restores its own
enabled protection when safe.

Connectivity-only pause can recover while awake after verification without an
extra sleep/wake. Inactivity release still waits for a normal wake. No probes run
asleep or during maintenance wake, and network events cannot defeat Stop, unsafe
battery, setup/ownership errors, crash exhaustion or login opt-out. Coding agents
manage their own reconnections. The prototype models release scenarios, not the
native activity detector.

Production event sources:
- [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor):
  path updates trigger verification; they are not internet proof.
- [NSWorkspace.didWakeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification):
  register on `NSWorkspace.shared.notificationCenter`, refresh samples/grace on
  normal wake, and preserve the maintenance-wake exclusion.

Preserve hotspot discovery, exact-SSID joins and Keychain passwords. The app's
network chooser offers Saved, Nearby discovery (including refresh and permission
setup), and Manual entry. Keep configured names available when discovery fails;
saved does not imply nearby or connected. Choosing a network stages the exact
SSID until Settings is saved and never joins it or changes credentials. Preserve
meaningful spaces and validate 1–32 UTF-8 bytes without control characters.
The prototype uses synthetic saved records and scan results only; production
saved-network enumeration and permission handling still require implementation.
Recovery defaults to three total join attempts per outage, configurable from
1–10 in Connectivity independently of Advanced condition-check retries. Capture
the configured limit when each outage/cycle starts; edits apply to the next
outage or explicit Try again cycle without resetting an active or exhausted
budget. Preserve both limit and used count through sleep, battery pauses and
crashes. Start after the saved outage delay (default five minutes), with a
30-second timeout per attempt and waits of 30, 60, 120, 240, then 300 seconds.
Retry now advances only a remaining attempt and never starts a parallel join.
After exhaustion, explicit Try again starts a new bounded cycle using the new
configured limit; there is no automatic infinite loop. Internet checks verify
recovery independently of association. Stop, recovery, disabled fallback and
battery cutoff cancel pending attempts. Battery protection always wins.

Saved selections reuse Keychain credentials and never display a password field.
Selection may be saved without a usable credential; show the
missing credential state and direct setup to macOS Wi-Fi before attempting to
join. Never fabricate a saved password or treat unknown security as open.
Nearby selections reuse a usable saved credential for the exact SSID; otherwise
secured networks prompt inline before Use network. Unknown Nearby security
requires an explicit Open or Password required choice. Manual entry defaults
to Password required with an explicit Open alternative and offers inline input.
Known credentials for the exact SSID may be reused. Changing source tabs clears
transient password input; manual security choices never leak into Nearby,
and open networks do not request passwords. Instant Hotspot remains a separate
passwordless macOS path. Store real credentials only through the native Keychain
integration, never in configuration, status, arguments or logs. Commit config
only after a successful credential write; cancellation or failure must preserve
the previous configuration. The browser prototype uses only transient demo input
and synthetic credential metadata, with no Keychain access or real passwords.

Prompt once per outage, with optional native desktop notification permission and
persistent app/CLI guidance. Say “Turn on Personal Hotspot on your phone” when the
saved fallback is not broadcasting. Offer Retry now, Skip fallback and macOS Wi-Fi
settings. Explain Apple Instant Hotspot/Auto-Join separately: Nightr cannot claim
to remotely toggle an iPhone hotspot. No iPhone push notifications without a phone
companion. Locked/asleep Macs may not show a usable prompt, so recovery must not
depend on a user response. Missing credentials or denied permissions need repair,
not repeated blind password attempts. No credentials in preview, logs or arguments.

References: https://support.apple.com/en-ie/109321 and
https://support.apple.com/en-au/111785.

## t integration and migration

Offer optional interactive macOS installation from t install and t config; no
automatic app installation on Linux or unattended setup. An explicit unattended
install request can install the package, but cannot silently authorize privileged
helper setup. Delegate to a versioned, checksum-verified Nightr release and the
recorded package owner. Stop a legacy monitor before
migration, change only owned links, preserve data and rollback. Remove bundled
source only after migration is validated. t uninstall leaves Nightr installed;
t update coordinates upgrades only for the enabled integration described below.
Update help, command inventory, examples, completion and install/release tests.

### Command-first installation and updates

The user's preferred entry points are Homebrew, `t install nightr` and `t update`.
Homebrew acquisition requires a public signed release and a matching published
cask. A verified direct installation requires the public signed release.

- Publish `agenthangar/tap/nightr` as a macOS cask containing the signed app and
  its CLI binary link. The manual steps are `brew tap agenthangar/tap` followed
  by `brew install --cask agenthangar/tap/nightr`.
- In `t install`, choose Nightr under **Desktop Apps** to start the guided route.
  Confirming the Homebrew installation allows t to add the fixed tap after
  checking the public release, then verify the cask before installation.
  The signed direct package is a separate route for users without Homebrew.
  Keep agent installation routes unchanged. The canonical noun/verb route is
  `t system apps install nightr`, with `t install nightr` as the requested
  compatibility convenience. Classify both in the command inventory and preview
  the entry, review, cancellation, failure and already-installed states before
  implementation.
- `nightr setup` checks and completes machine readiness after installation:
  app/CLI location, owned command links, helper authorization, permission guidance
  and login-service registration. Re-running repairs only owned components,
  preserves settings/credentials and never starts protection without intent.
  Keep acquisition/upgrades in Homebrew, t or the direct installer; a CLI-only
  setup reports its supported mode and offers the appropriate app-install path
  rather than silently adding an app. Do not add `nightr install`: that proposed
  command was never released and needs no compatibility alias.
- `nightr config` edits normal preferences: activity/network checks, grace,
  battery cutoff, hotspot fallback and desired login behavior. Reuse the same
  settings schema in app Settings. `config --show` remains read-only. Setup may
  offer to open this existing editor for initial preferences; it must not create
  a second configuration flow or reset preferences on repair. A configuration
  edit must not silently install privileged components or bypass an OS permission
  prompt. Missing prerequisites get an actionable `nightr setup` instruction.
- `t update` (canonical `t system update`) includes Nightr when its t integration
  manages updates. Selecting installation through t records this integration;
  independently installed copies can opt in without reinstalling. A regular
  update never installs a previously absent app. Read-only update checks remain
  read-only and report each component independently.
- Keep one update owner per installation. For a Homebrew-owned copy, both t and
  `nightr update` delegate to `brew upgrade --cask agenthangar/tap/nightr`. For a
  directly installed copy, they use Nightr's signed-release updater. A first
  update of a manually installed AgentHangar cask verifies its owner before
  recording it. The app's update action follows the same owner. Do not silently
  convert ownership, overwrite another install, create two apps or run competing
  updaters.
- Scope updates to the installed canonical package, never a development worktree.
  Serialize install/update operations; verify version, checksum and signing;
  preserve configuration, credentials and enabled intent. Coordinate controller
  restart and helper compatibility, report partial failures and support rollback.
  t uninstall does not uninstall Nightr; t update may upgrade it as explicitly
  managed above but does not remove it or replace its installation owner.

The DMG is an alternative for users who prefer downloading an app. All entry
points deliver the same prebuilt release with bundled dependencies and the same
explicit first-time helper authorization. No manual dragging is needed for
Homebrew or t installation. Extend the preview with these command-first paths;
the current DMG-only walkthrough does not yet show this revision.

Acceptance adds fresh install with/without Homebrew, existing/CLI-only installs,
repeat setup, owner-preserving upgrades, no-install-on-update, skipped Linux,
noninteractive privilege handling, concurrent-update exclusion, partial failures,
rollback and preservation of active intent/config/credentials.

Homebrew references: [cask app and binary artifacts](https://docs.brew.sh/Cask-Cookbook#stanza-binary)
and [tap-qualified installation](https://docs.brew.sh/Taps).

### Connectivity and normal-wake tracking

Instant Hotspot and Auto-Join remain distinct from saved-SSID fallback. Use
supported OS guidance and truthful unknown statuses; Automatic requires macOS
26+. Nightr cannot remotely toggle the phone. Normal wake resumes enabled
recovery, while Stop, unsafe battery, setup errors and maintenance wake remain
guards. Verify internet independently after path changes and normal wake.

Wake for network access, Wake-on-LAN and wireless wake configuration are removed
from the launch scope at the user's request. They do not reliably resume coding
work when internet returns. Do not show these rows or setup dialogs.

Use simulation/unit tests for open/closed lid, AC/battery, unknown permissions,
phone absent/present, captive portals and exhausted join budgets. Real power,
network and credential mutations require a dedicated authorized environment.

Primary reference: [Apple Instant Hotspot and Auto-Join](https://support.apple.com/en-us/109321).

## Websites and delivery

Keep nightr.ai's static source in this repo and deploy via GitHub Pages. Add Nightr
after t in agenthangar.github.io's tool tabs using existing styles, analytics,
keyboard/deep-link/no-JS/mobile patterns. Product page: app visuals, CLI examples,
Download for macOS, real capabilities and source/releases. Use the approved
moon + spark. The inactive Nightr tab uses its glyph, a clear approximately 18px
label, legible amber NEW badge and background/border emphasis; selected state has
a distinct underline. Preserve existing AgentHangar branding and sibling tabs.

Distribute a prebuilt, signed and notarized universal DMG containing a signed
PKG with a bundled runtime and protected helper.
Follow [Apple's notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution):
Developer ID signatures for all distributed executables, hardened runtime for
app/CLI targets, secure timestamps, notarization and a stapled ticket. Validate
the actual artifact before release. The preview simulates the download flow and
has no artifact URL; intended distribution is not a claim of completed signing.

Domain is registered in Cloudflare. Verify Pages ownership and configure apex/
www while preserving unrelated records; DNS-only initially, HTTPS and canonical
apex verified before public links. Do not change DNS before the site is ready.

Release sequence: independently validated CLI; approved prototype; implemented
and verified app/controller/helper; Nightr release; t migration; product hosting/
Cloudflare; AgentHangar listing. Review diffs and required CI, squash auto-merge
ready approved PRs under repo policy; run canonical t update after its merge.

## Acceptance

Standalone install without t; alias/flags/config compatibility; one monitor;
shared app/CLI state and Stop; live setting changes; wake/login/battery/crash/
permissions/recovery cases; hotspot prompt, retry budget, cancellation and
internet verification; owned installer/uninstaller/rollback/worktree isolation;
responsive accessible websites, icon sizes, valid links and HTTPS. Run extracted
tests, 97% Python coverage, shell syntax, CLI contract, native compilation and
browser preview tests. Native desktop tests/macOS CI stay opt-in. No power,
network, credential or personal-config mutations during testing.

## Connectivity readiness display

The macOS section contains only Auto-join iPhone hotspot. Its status box reflects
joining mode: checked for verified Automatic, empty for Ask/Unavailable, dash
for Not checked. Instant Hotspot eligibility is prerequisite context. Use
supported observation or report unknown; never equate OS version with enabled
settings. Keep the System Settings guidance brief. No network-wake rows.

Credential integration reference: [Apple CoreWLAN functions](https://developer.apple.com/documentation/corewlan/corewlan-functions).
