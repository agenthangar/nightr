# Nightr interactive design preview

Open [index.html](index.html) directly in a browser. It is self-contained: inline
CSS, JavaScript and original SVG, with system font fallbacks and no dependencies,
network calls or storage. Refreshing resets the sample. External source links
only navigate when explicitly clicked; installation and system actions are
clearly simulated. The preview creates no real machine effects.

For a loopback URL, from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory design-preview
```

Then open `http://127.0.0.1:8765/`. Stop the server with Ctrl-C.

## Native Settings preview on macOS

Open [the native pane preview](native/Open%20Settings%20Preview.command). It starts
in Force mode. Use the **Preview** menu bar item to switch from Settings to the pane. Open Settings again to
resume the same draft. Edits to the SwiftUI views reload in place. Quit Preview with ⌘Q.

Protection, network choices, and Save use an in-memory sample session. The
Wi-Fi Settings link opens the system pane.

## Walkthrough

1. **App & CLI:** Stop in the app, then enter `nightr status --json`. Try wake,
   login and crash; explicit Stop remains disabled. Start again in either surface.
2. **Settings:** The compact Settings window has General, Protection,
   Connectivity and Advanced sections. One draft survives section changes;
   Save applies it live, Cancel discards it, and Reset stages defaults. Arrow
   keys switch section tabs; Escape cancels and focus returns to the opener. Run
   `nightr config`, use arrows or j/k and Return, review and save a different
   display mode. Compare configured defaults with the active run snapshot.
   `nosleep config --show` and `nightr status --json` stay read-only.
3. **t integration:** Run `t config`. All real parent entries appear in order,
   replacing Nosleep with the proposed Nightr entry. Edit a sibling field,
   return, then open Nightr. Review/save or discard pending parent edits first.
   Returning from Nightr restores focus. Sibling fields are explicitly simplified
   synthetic examples, not a claim that the real t schemas were reproduced.
4. **Recovery:** Reset, choose Internet lost, then advance the **sample clock**
   by five minutes. Attempt 1 opens. Each attempt has a 30-second cap. Automatic
   waits are 30 seconds then 60 seconds. Retry now consumes the next remaining
   attempt, cannot overlap, and cannot reset the configured attempt budget (default 3). After
   exhaustion only explicit Try again starts another join cycle. Independent
   lightweight internet checks continue at the saved Check interval (default 30 seconds) while eligible. Choose
   Network returns, then +10s: verification clears the outage without a fourth
   join or another prompt. Path availability alone is not success.
5. **Interruptions:** Low battery, Stop, sleep, crash and denied permissions close
   active attempts. The same outage ledger and one-prompt count survive pauses;
   verified internet recovery clears them. Joining Wi-Fi without verified
   internet does not recover. Try notification denied, missing package,
   conflicting run, and disabled launch at login.
6. **Approved icon:** Moon + spark (concept 1) is locked across all surfaces.
   Inspect actual-size 16/18/22-pixel light/dark menu glyphs, state treatments,
   app icon, mock favicon and social card. Revised UI approval is separate.
7. **Websites:** Inspect nightr.ai at desktop/mobile width and the functioning
   AgentHangar tabs, including the prominent inactive Nightr/NEW tab. Download
   buttons simulate DMG → Applications → open → explicit helper authorization.
   The planned universal app includes its runtime and needs no Xcode or separate
   Python. There is no release download yet. UI approval stays in the conversation.

## Scope and limitations

This is a browser simulation awaiting design approval, not app/controller or
website production code. No commands, power operations, Wi-Fi joins, passwords,
Keychain actions, notifications, installers, downloads or login services run.
No credentials or personal configuration are loaded. All sample settings and
review notes are held only in memory.

The manual clock exercises bounded hotspot recovery, battery priority, process
restart and persistent intent. Underlying network reachability is separate from
last verified internet. Path changes and normal wake coalesce into one bounded
10-second check; eligible periodic checks start at the saved Check interval (default 30 seconds) independently
of the hotspot join budget. Sleep runs no checks, and maintenance wake does not
rearm. Connectivity-only pause can recover while awake; inactivity release waits
for normal wake. Nightr restores its own protection; coding agents reconnect
themselves. Advanced legacy check options are editable and
represented in run snapshots; this preview does not reproduce the native
polling/inactivity detector or all old shell parsing edge cases. The controller
and actual CLI need their own tests after approval. A browser cannot verify
native macOS placement, permissions, real sleep/wake or assistive technology
behavior. Website typography uses local fonts only, with offline system
fallbacks. Download/install steps are simulated. Signed/notarized universal
distribution is the intended release contract, not an existing downloadable
artifact. Native macOS permissions, signing and the shipped runtime still need
production verification.

## Lightweight offline checks

No package installation is needed. With Node 18+:

```sh
node design-preview/check-preview.cjs
```

With the selected repository snapshot runner:

```sh
t runners runs start --tool codex --include design-preview -- node design-preview/check-preview.cjs
```

The check compiles both inline scripts and evaluates the pure sample controller
plus command/transaction flows in a minimal DOM adapter. It checks Stop intent,
recovery timing/budget, post-exhaustion network return, bounded/coalesced probes,
repeated sleep/wake, settings drafts/sections, locked icon/download copy,
cancellation, independent verification, permission and
battery guards, launch preference, matching/conflicting run options, legacy flag
modes, read-only output, the complete parent menu, sibling transactions, pending
gates, CLI rails, and generation of all five surfaces. It does not replace visual
browser review. No native macOS UI test is launched.

The chooser keeps Saved Keychain-only and provides the needed Nearby prompt.
Nearby networks with exact saved/pending credentials reuse them without an input;
missing secured credentials reveal an inline password, and unknown security
requires an explicit choice. Nearby security overrides are scoped to the exact
SSID and never inherit Manual's choice. Nearby Open never deletes a stored
Keychain entry. Manual remains editable with Open/Password required and its
existing saved-password reuse.

All tab/name/security changes clear the raw DOM input. Same-source refreshes may
preserve the same-identity node; Saved never receives it. Parent staging, atomic
Save/Cancel, retry after a simulated save failure, exact SSID validation and
null-prototype metadata maps remain intact. Demo text only; no real credential
or Wi-Fi operation runs.

Connectivity shows **Internet access** and **Ask to join hotspots** at the top.
An Automatic preference gets a green circled check and green text. A separate
Wi-Fi Settings action sits beside the reported value. The browser simulates
that action. Normal-wake recovery and its safety checks remain available.
The outer workbench discloses that the preview does not read macOS settings.
Settings scrolls only its content, leaving header/footer outside that pane.

Attempts is 1–10 total hotspot joins, default 3. An active outage retains its
captured limit; app edits affect the next bounded cycle. Explicit Try again uses
running settings; CLI config remains next-run-only. Pauses retain the consumed
budget. Thirty-second join caps and 30/60/120/240/300-second gaps remain bounded.
Internet verification continues independently after exhaustion.

The outer macOS sample selector provides generic Unknown, Setup needed, Eligible,
Ask and Earlier macOS profiles. Auto-join appears with concise actionable guidance; Instant Hotspot eligibility
remains context. No real capabilities,
accounts or settings are read. Native Wi-Fi
and credential implementation is still production work, not part of this preview.

For direct local review, append `#settings/protection`, `#settings/connectivity`
or `#settings/advanced` to the file URL or loopback URL. These links only open a
focused tab; query parameters are ignored and nothing is automatically saved.

Advanced pairs exact numeric inputs with a sec/min selector or count stepper.
The full ranges and associated rendered-state checks are in the
[design system](../DESIGN.md#decisions-and-regression-checks).

The short macOS guides are informational only. Instant Hotspot uses eligible
nearby devices with the same Apple Account or Family Sharing, Wi-Fi/Bluetooth and
a compatible carrier plan. It needs no saved Wi-Fi password or Allow Others to
Join; those may be relevant to the separate, broadcasting saved Wi-Fi fallback.
Automatic Auto-Join on Mac requires macOS Tahoe 26+; earlier versions use their
supported manual/ask flow. Normal wake initiates guarded internet verification; no network-wake setting is
read or changed. Full production prerequisites and references remain in DESIGN.md and the launch
plan. Guide dialogs contain short status/purpose/path instructions and return focus
to their source row.

Historical network-wake removal snapshot
`72ed66f7-552b-4567-8727-85f9d8a2d52b` passed **92 checks** after the removal.
The harness retains normal sleep/wake, recovery, attempt, credential and theme
checks and explicitly rejects removed network-wake controls and fixture fields.
No fresh browser verification is claimed for this bounded removal; the previous
content-scroll and light/dark palette checks remain applicable.

A newly edited empty Automatic selection blocks Save with “Select agent activity or internet availability.” Imported empty configurations are retained on unrelated Save.
Cancel discards the full draft and Reset explicitly stages defaults. Disabling
the battery option keeps the cutoff; it releases the hold on unsafe battery power
and resumes on AC or sufficient charge, without forcing the Mac to sleep.

The prior network-return revision passed 33 checks; browser review covered its
Settings, prominent inactive Nightr tab and simulated download steps. Native
sleep/wake, permissions and actual network operations remain outside this preview.

## Activity and local-model proposal

`activity.html` is the isolated synthetic proposal for issue #23. Serve it through
the same loopback server and review `/activity.html`. It changes no app,
controller or actual CLI. It reads no live configuration or model content and
makes no requests to live services and performs no storage writes or system actions.

The 318px popover shows the desktop icon, protection state, Start or Stop
and a separate Force mode action. Two compact model/runtime rows appear below the actions; **All 4…** reveals the
remaining observations. Generating, loaded idle, loaded with unknown activity,
inventory only and expired observations stay distinct. Each row opens a plain
details dialog with current state/runtime and useful reported Memory, Context
window and Time generating/rate values only when known. Unverified observations
do not acquire a current loaded state or rate. Escape returns focus to the row.
Agent Active and verified Internet Connected use a green circle-check; checking,
unknown and unavailable observations retain explicit text. CPU/GPU is informational.

**Settings…** opens the full existing General, Protection, Connectivity and
Advanced controls through `index.html?activity-settings=1`, a narrowly gated
same-origin frame. This reuses the established Settings editor and hotspot
chooser instead of maintaining a reduced copy. The frame obtains defaults from
its existing full schema, receives the activity's saved settings/observations and
theme, and owns one draft. Save applies that complete draft once to activity;
Cancel/Escape discards it. A hotspot child's Escape closes only that child and
returns focus to Choose; closing Settings returns focus to its opener. Section
switches retain the draft, including display/lock, timing, battery, notifications,
login and hotspot preferences. Native credentials and Wi-Fi actions remain simulated.

Automatic protection evaluates the saved `checks` and legacy `require` policy;
Existing until-stopped configurations retain `forever` until the user chooses automatic rules. Unrelated edits preserve imported check policies.
**When a local model is generating** is an independent Automatic
opt-in for online and offline use. It starts off. Existing until-stopped configurations retain its value.
The saved battery-enable option and exact cutoff apply in either awake mode.
Stop, sleep and unsafe configured battery always win. Other preferences remain
editable and retained; they do not initiate real system actions. JSON exports
the same complete saved configuration used by the popover and plain CLI.

The collapsed **Preview controls** exercise offline inference, loaded idle,
unknown MLX, independent runtimes, unsupported GPU, long escaped model names,
Stop/Quit, battery, sleep and wake. Metadata renewal is simulated every 5s with a
15s lease using the manual sample clock. Expired/unknown inference never qualifies.
Inactivity pause in Automatic mode waits for normal wake or explicit Start;
fresh metadata cannot resume it. Startup checking has a bounded 15s grace and
then remains Unknown without evidence. Idle terminals never prove activity.
Stop and Quit closes the popover; reopening via the moon keeps protection Off.

Activity copy and authored embedded Settings/chooser separators avoid middle
dots; user-entered SSID characters are preserved. All values are fabricated,
proposed CLI fields are illustrative, and no real runtime compatibility is
claimed. Browser checks cannot verify native accessibility, runtime APIs or
power behavior. Explicit preview approval still precedes production work.
