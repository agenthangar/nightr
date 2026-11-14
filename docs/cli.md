# Nightr CLI

The installed `nightr` and `nosleep` commands use the same native controller as
the menu bar app. They share saved defaults, enabled intent and recovery state;
a second invocation cannot create a parallel monitor. Nightr runs independently
of `t`. Release signing and distribution remain separate acceptance gates; see
[distribution](distribution.md) for the current delivery requirements.

## Start, stop and inspect

```sh
nightr                         # foreground protection; Ctrl-C stops it
nightr start                   # start or attach to the background controller
nightr stop                    # persist Off and release owned protection
nightr status                  # current observed state
nightr status --json            # versioned JSON; never starts the controller
```

Foreground Ctrl-C stops shared protection, including when another app or CLI
started it. The menu bar app's Stop and Stop and Quit actions persist the same
Off intent. Normal wake, path changes and login cannot override an explicit Stop.
Status is read-only and does not open setup, a picker or an authorization prompt.
Conflicting run settings are rejected while a monitor is already enabled.

JSON uses a versioned controller-response envelope. A successful reply has
`version: 1` and a `status` object; the hold is `status.holding` and enabled intent
is `status.state.desiredEnabled`. An Off controller still returns that object.
If status cannot be read, `status` is absent and `error` explains the failure:

```json
{"version":1,"error":"Nightr status unavailable: private controller socket is unavailable or unsafe"}
```

Treat an error or missing status as unavailable. It does not prove that persisted
intent is Off or that no process exists. Do not expect a top-level `holding`
field or infer protection from process availability alone.

Start needs the signed power helper to be ready. A requested hold can fail;
status reports setup, ownership, safety and recovery errors instead of treating
intent alone as successful protection. Nightr never unlocks the Mac or forces
immediate system sleep.

## Setup, preferences and updates

```sh
nightr setup                   # open native setup/settings
nightr setup --check           # report helper readiness without installing it
nightr setup --cli-only        # explicit helper authorization without login setup
nightr config                 # staged terminal editor: review, save or cancel
nightr config --show           # display saved defaults without writing
nightr config --edit           # edit JSON with VISUAL/EDITOR
nightr update --check          # inspect the recorded owner's update route
nightr update                 # request an owner-preserving package update
```

Setup handles machine readiness and explicit macOS authorization. It does not
reset preferences or start protection merely because setup was opened. CLI-only
setup registers the shared power helper without adding a login agent or starting
a monitor. Desktop setup manages its supported login services. Authorization may
remain pending in System Settings; a failed or incomplete setup needs attention
before protection can start.

Config edits everyday preferences. Defaults remain in
`${XDG_CONFIG_HOME:-~/.config}/nosleep/config.json`; existing configuration keys
and the `agenthangar.nosleep.hotspot` Keychain service are retained. The terminal
editor uses arrow keys or j/k, staged review and save/cancel. CLI edits apply to
the next run. Native app Settings share the schema and apply validated changes
at a controller loop boundary. Saving preferences does not silently install a
privileged helper. Imported requirement policies and any stored `inactivity`
value survive unrelated app edits; the app has no separate inactivity timer.

Updates follow the recorded Homebrew or direct-install owner. They preserve
configuration, credentials and enabled intent, and refuse concurrent active
controllers that cannot be safely quiesced. An incomplete installation transaction
blocks new protection until a trusted installation repair succeeds. A regular
update does not acquire a previously absent app.

## Foreground options and compatibility

Options override saved defaults for that run:

```sh
nosleep --display dim --lock off --checks agent
nosleep --checks internet --grace 900 --retries 3 --backoff 30
nosleep --require 1             # retain protection while busy OR online
nosleep --checks none           # keep awake until stopped, without checks
nosleep --hotspot off           # disable saved fallback for this run
nosleep --hotspot=on            # enable configured fallback for this run
```

| Setting | Options and values |
| --- | --- |
| Display on lid close | `-d`, `--display` with `off`, `on` or `dim` |
| Lock on lid close | `-l`, `--lock` with `on` or `off` |
| Automatic conditions | `-c`, `--checks` with `all`, `agent`, `internet` or `none` |
| Passing conditions | `--require all`, `--require none` or a positive count |
| Check interval | `-e`, `--every` seconds; default 30 |
| Grace | `-g`, `--grace` seconds; default 900 |
| Extra condition retries | `-r`, `--retries` from 0–10; default 3 |
| First condition retry delay | `-b`, `--backoff` from 1–300 seconds; default 30 |
| Saved hotspot fallback | `--hotspot on` or `--hotspot off` |

Mode values accept a separate argument or `=`. Display mode replaces the whole
display choice; locking remains independent. Bare `-d` retains saved dimming,
while `-d on` clears it. Bare `-l` enables locking; bare `-c` selects both checks.
Existing switches and groups remain supported: `-mLI`, `-dML`, `-AI`,
`-mLIe10`, `-mLIe 10`, `-Ld=dim`, `-Ld dim`, and the legacy `-dim` spelling.
The individual agent/internet toggles, forever and no-forever choices, and legacy
display/lock switches remain compatible; use `nosleep --help` for their spellings.

The default `--require all` requires every selected condition. A numeric policy
requires that many passing conditions; a running CLI validates the count against
the selected checks. `--require none` and forever mode retain saved condition
choices while disabling automatic checks. The requirement policy remains a CLI
compatibility control; the app preserves imported custom policies.

## Protection and recovery

While the lid is open, failed automatic conditions do not release the hold.
With the lid closed, each selected condition retains its grace period; activity
needs initial samples before an idle decision. Failed conditions receive the
configured extra retries with a doubling delay capped at five minutes. Internet
recovery refreshes activity sampling and grace. Display and locking choices
remain separate from the decision to allow sleep.

Automatic internet verification and saved-hotspot joins run only when automatic
monitoring and its internet condition are enabled. Forever, require-none and
checks-none modes, or disabling the internet condition, suppress them; explicit
Retry now cannot bypass those choices. Disabling those checks at a loop boundary
cancels active operations, and late results cannot rearm them. If a deliberate
policy change makes internet unnecessary, its connectivity pause can clear; Stop,
battery, inactivity, sleep and setup pauses retain their separate rules. A retained
hotspot outage does not keep an agent-only run awake after inactivity retries end.

Path availability and Wi-Fi association are not proof of internet access. Eligible
verification has one active operation, a ten-second cap and a thirty-second start
cadence. Normal wake requests fresh verification and refreshes condition samples.
Maintenance wakes and sleep do not run probes or joins. A connectivity-only pause
can recover while awake after verification; an inactivity release waits for a
normal wake. Nightr restores its own protection; coding agents handle their own
session reconnections.

Optional battery protection defaults to off with a saved threshold of 20%.
When enabled, a battery percentage below the threshold releases the hold, without
forcing sleep. The safety check applies in both awake modes and takes priority
over grace, retries and hotspot recovery. AC power does not trigger the cutoff.
Unsafe or unavailable battery safety data can pause protection. Plugging in or
recharging can clear a battery pause, while preserving any underlying inactivity
or connectivity pause. Repeated unclean controller restarts also have a bounded
recovery allowance; exhausted recovery requires an explicit Start.

## Saved hotspot and native network chooser

Use Connectivity in app Settings, `nightr hotspot setup`, or the hotspot fields
in `nightr config` to configure a trusted fallback. It is disabled by default.
The native chooser offers Saved, Nearby and Manual sources. Saved/configured
names remain selectable when discovery fails; a saved network is not necessarily
nearby or connected. Only a complete fresh scan can report a network as not seen.
Nearby shows the current connection first, then signal strength, with exact-SSID
deduplication. Manual entry preserves meaningful spaces and Unicode spelling and
accepts 1–32 UTF-8 bytes without control characters.

A chooser selection stages the exact name; it does not join a network. Saved
selections reuse available credentials without displaying them. Nearby or Manual
can stage a password when needed, and unknown security requires an explicit
choice. The parent Save commits the staged selection and credential operation;
Cancel discards pending changes. Credential failures leave the configuration
unchanged. Existing inaccessible credentials may need explicit access repair.
The installed app and worker use native Keychain access; the bundled rail editor
invokes the signed CLI for a private terminal password prompt. Raw passwords do
not enter command arguments, configuration, status JSON, IPC or logs.

Installed discovery uses the prebuilt worker and explicit native Location
permission setup. It does not require Xcode or compile a helper on the customer's
Mac. Unknown, denied, stale, Wi-Fi-off and unavailable observations remain distinct
from a verified nearby network. macOS may still deny a join or credential access.

The default outage delay is 300 seconds. Hotspot attempts are a separate setting:
three **total** joins per outage by default, configurable from 1–10. The active
outage captures its limit; editing the preference does not refill that budget.
Each attempt is capped at thirty seconds, with waits of 30, 60, 120, 240 and then
at most 300 seconds. The ledger survives sleep, battery pauses and crashes.

Retry now advances only a remaining attempt and never starts a parallel join.
After repairing credentials or permissions, an explicit Retry now can retry
within that same remaining budget. Skip fallback suppresses automatic attempts.
After exhaustion, only explicit Try again starts a new bounded cycle using the
running settings. Eligible internet checks continue after exhaustion; successful
association alone does not clear the outage. Verified internet recovery clears it.

Ordinary saved-SSID fallback needs an available broadcasting network and usable
credentials when the network requires them. For an iPhone this may require
turning on Personal Hotspot and Allow Others to Join. Nightr cannot switch on the
phone remotely. Apple Instant Hotspot is a separate macOS feature with device,
Apple Account or Family Sharing, radio and carrier prerequisites. Automatic
Auto-Join requires macOS 26 or later; earlier systems use their supported flow.
Nightr reports observed readiness or unknown status and leaves those settings to
System Settings. It does not configure network-wake preferences.

## Source compatibility

The checkout retains the extracted zsh/Python implementation and its tests for
compatibility and provenance. Without an installed native app, `./bin/nightr`
and `./bin/nosleep` can use that legacy source monitor, including its sudo-based
power route, single directed fallback attempt and locally built discovery helper.
Those source-only behaviors are not the installed native controller described
above. When the canonical signed app is installed, source aliases route to its
native CLI and fail closed during an incomplete installation. Tests isolate all
user state and disable that canonical-app routing; they never authorize real
power, Wi-Fi, credentials or desktop mutations.
