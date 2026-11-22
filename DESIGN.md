# Nightr design direction

This is the implementation brief authorized by the launch plan. The user approved
concept 1, the moon with awake spark, and approved proceeding with implementation
after removing Wake for network access on 2026-11-14. Network-wake settings and
guidance are outside the approved product scope; normal-wake recovery remains.

## Product

Nightr keeps a Mac awake while coding agents work. Explain observed protection,
activity, internet, battery and recovery clearly. Never imply remote control of
an iPhone's Personal Hotspot switch or guarantee work continues through system
sleep. An explicit Stop remains stopped on wake and login.

## Native app

Use familiar macOS menu bar and Settings conventions, system typography,
keyboard access, light/dark appearance and accessible controls. Put one primary
Start/Stop action above the diagnostic detail. Separate configured behavior from
observed state. On, Off, Paused, Recovering and Error have textual labels as well
as distinguishable glyph treatments. Do not rely on color alone.

Settings uses a compact native window approximately 600px wide with General,
Protection, Connectivity and Advanced sections. Use 15px labels, 13px explanatory
text and aligned rows around 30–34px high. Keep padding modest and Save, Cancel
and Reset visible. One draft spans all sections; switching never loses pending
values. Preserve every existing setting. Keyboard focus enters the selected tab,
stays inside the dialog, and returns to the invoking control on Save or Cancel.
Escape cancels; section tabs support arrow keys, Home and End. The Settings
window follows the selected light/dark appearance; its native palette must not
be overridden by default dark component variables. Standard and disabled buttons
need explicit light-appearance fills, borders and readable text as well.

The visual reference is [Rectangle Settings](https://rectangleapp.com/assets/images/shortcutScreenshot.jpg).
Borrow its native density and organization, not its product controls.

Protection is one simple decision followed by two quiet details:
- **Keep Mac awake:** native grouped radios, “Automatically” / “Until I stop,”
  map directly to `forever=false/true`. Only Automatically shows the compact,
  left-aligned “Agent is active” and “Internet is available” checkboxes. With
  both selected and `require=all`, show only “Both must apply.” A single selected
  condition needs no helper. Imported non-all policy shows “Custom CLI policy
  retained” instead. No separate Protection heading or introduction is needed.
- **When lid closes:** a compact Display selector (Off / On / Dim) and left-aligned
  “Lock Mac” checkbox, preserving the existing settings.
- **On battery:** one row, “[checkbox] Allow sleep below [20] %.” Disabling it
  preserves the number. The only helper is “Plug in or recharge to resume.” It
  applies in both awake modes, releases the hold on low battery, and never
  forces sleep. AC power does not trigger the cutoff.

Use modest spacing and quiet divider lines; do not create extra cards or distant
checkboxes. Keep the mode radios keyboard-native and preserve their focus when
switching. Hidden automatic conditions retain their selection and are excluded
from focus. Mode switches do not rewrite either `checks` or the legacy `require`.
Only an intentional condition toggle normalizes `require=all`. Rendering,
browsing and unrelated Save preserve imported policies and empty legacy checks.
A newly edited empty Automatic selection shows “Select one, or choose Until I
stop.” The CLI retains its full legacy policy controls. All fields share one
Save/Cancel/Reset draft and battery safety applies regardless of the awake mode.

Connectivity uses the same quiet native layout as Protection: no duplicate panel
title or introductory paragraph, 15px semibold foreground group headings, modest
spacing and subtle dividers. Keep three groups:
- **Connection:** one low-contrast strip with a small Wi-Fi glyph, a truthful
  state label and discreet Sample marker. Separate independently verified
  internet from probing, stale data and association alone. Use at most one
  concise outage line, such as “Hotspot attempt 2 of 3.” “3 attempts used · still
  checking internet” is only valid while verification is eligible; asleep,
  stopped and unsafe states must say checks are paused.
- **Hotspot fallback:** a left-aligned “Use saved hotspot” checkbox, with nearby
  indented labels “Hotspot” (selected name and Choose) and “Try after.” Preserve the exact seconds value and
  its visible unit. Disabling fallback disables the two fields without clearing
  their values. Show the configured total attempt limit and clarify that internet checks continue.
- **macOS settings:** “Status only · change in System Settings.” The single
  “Auto-join iPhone hotspot” box reflects only the joining setting: Automatic is
  checked, Ask/Unavailable is empty, Not checked has a dash. Instant Hotspot
  device eligibility is prerequisite context, never a conflicting status box.
  Keep the compact high-contrast 20px status box and status-aware guidance button;
  it is not an OS switch. Defaults remain unknown and fixtures live outside the
  product. The dialog identifies current status, purpose and System Settings path.
  The single outer disclosure says “Preview does not read macOS settings.”

Settings keeps its header and actions outside the scrollable content. Only the
content pane scrolls, so the last source row cannot sit beneath the footer.


Avoid large status cards or repeated availability paragraphs. Unknown macOS
capabilities remain informational; no help button reads or changes OS settings.
Full prerequisites belong here, not in modal paragraphs.

The hotspot field displays the selected exact name plus **Choose…**, not an inline
free-entry field. The nested chooser has Saved, Nearby and Manual source tabs:
- Saved retains the configured name even when absent from discovery. Distinguish
  saved/configured status from availability. Only a complete fresh scan may say
  Not seen; incomplete, denied, failed or stale observations mean availability
  is unknown.
- Nearby lists the current Wi-Fi first, then strongest signal, with exact-SSID
  deduplication. Case and spaces distinguish networks. Use a realistic four-network
  default sample; adversarial names belong in tests. Refresh and, only when needed,
  Enable discovery are synthetic actions. All permission/scanning/empty/off/stale/
  unavailable/error fixtures are selected in the outer workbench, not as debug
  controls in the product dialog.
- Manual accepts the exact Wi-Fi name without trimming or Unicode normalization.
  Validate 1–32 UTF-8 bytes, no Unicode Cc control characters and no unpaired UTF-16
  surrogates. Keep leading/trailing or all-space names when valid. Escape names in
  HTML. Use the same validator for chooser, parent Save and CLI preview settings.

One chooser-local selection survives tab changes and refreshes. Use network changes
only the parent's pending SSID; parent Save applies it. Cancel/Escape discards the
chooser selection and returns focus to Choose. The chooser neither starts/joins
networks nor changes credentials, fallback enablement, permissions or OS state.
Native source-tab arrows and radio selection remain keyboard accessible. Refresh
uses a generation token and cancellation so a late result cannot resurrect a
closed chooser or replace a newer observation/selection. No real Wi-Fi scan runs.

Network security is separate from discovery availability. Saved is Keychain-only:
no credential fields or security choices. Use network stages the exact SSID,
without creating credentials for missing/unknown entries. Existing explicitly
validated pending metadata for the same SSID may be retained, but ordinary list
selection cannot write or clear Keychain metadata.

Nearby reuses an exact-SSID saved or validated pending password without displaying
an input. A secured network missing both reveals the masked inline password and
requires it before Use network. Unknown Nearby security requires explicit Open or
Password required; it is never inferred open. Store local Nearby choices in a
separate exact-SSID, null-prototype override map, never in Manual's choice. Nearby
Open may classify the network but never authorizes deleting an existing Keychain
entry. Only an explicit Manual Open conversion may stage that deletion.

Manual remains an editable form defaulting to Password required, with Open as an
alternative and exact saved-password reuse. Manual and Nearby alone may stage a
validated credential write. No parent Password row, separate Change button or
extra password step is shown. Instant Hotspot remains a distinct passwordless
macOS feature.

Raw passwords remain DOM-only and are cleared on every tab, name or security
transition, cancel and commit. A refresh/scan in the same source, exact SSID and
security may preserve the input node without serializing its value. Never place
raw values in state, JSON, logs, storage or markup attributes. All arbitrary SSID
metadata keys use Maps or null-prototype dictionaries. Atomic parent Save/Cancel
and failed-save Retry behavior are unchanged.

Use network stages the selected SSID, its security classification and any pending
credential action. Parent Cancel discards them. Parent Save first simulates the
credential operation, then commits metadata/configuration together. A simulated
failure commits neither, keeps the draft and focuses Retry Save. Saved security
classification persists separately from the saved-password boolean. Explicit
security changes replace incompatible pending metadata. Scan completion preserves only a same-source, same-identity Manual/Nearby password node; Saved never receives it. This is transaction simulation, not
an implementation of secure credential storage.

Hotspot attempts is a separate integer setting, default 3, range 1–10 **total**
join attempts. Capture its limit per outage/cycle. App edits apply to the next
cycle, not an active budget; explicit Try again starts a new bounded cycle using
the running settings. CLI config changes remain next-run-only. Preserve limit,
consumed count and prompt ledger through sleep, battery pause and crash. Each
attempt has a 30-second cap; gaps are 30, 60, 120, 240, then at most 300 seconds.
Exhaustion never automatically starts another cycle, while independent internet
checks continue. User-facing status and JSON show the actual captured limit.
Advanced health-check retries remain a different setting.

Instant Hotspot requires eligible nearby devices using the same Apple Account or
Family Sharing, Wi-Fi/Bluetooth and a compatible carrier plan. It needs neither
a saved Wi-Fi password nor Allow Others to Join. Automatic Auto-Join on Mac needs
macOS Tahoe 26+; earlier versions use their supported manual/ask flow. Ordinary
saved-SSID fallback is distinct and requires a broadcasting network, potentially
saved credentials and Allow Others to Join. Nightr cannot toggle the phone.

Normal wake triggers fresh bounded internet verification. Maintenance/dark wake
must not rearm protection. Nightr does not configure or surface network-wake
preferences.
Advanced uses the adjustment-sliders toolbar glyph and two 15px semibold groups,
without a duplicate panel title or technical footer:
- **Automatic checks:** “Check every,” with “How often to check the conditions
  selected in Protection.”
- **Before allowing sleep:** “Wait before retrying,” with “Keep awake through
  pauses or lost internet before retrying”; “Extra attempts,” with “Retry failed
  conditions before allowing sleep”; and “First retry delay,” with “Later waits
  double, up to 5 minutes.” Zero attempts shows “No extra attempts” and disables
  the delay while retaining its value.

Use one bottom line: “These limits apply when the lid is closed.” Pair each time
slider with an exact integer input and the full word “seconds.” Interval sliders
span 1–300 (full input 1–3600), grace 0–3600 (full input 0–86400), and first delay
1–300. Extra attempts is an integer 0–10. Preserve valid values outside convenient
slider windows; browsing and Save never clamp or round. Exact duration hints such
as 900 seconds = 15 minutes are display-only and retain any remainder. Input
and slider events synchronize in place without rerendering or focus loss.
Fractions, empty and invalid values receive inline errors. Disabled fields are
skipped by keyboard navigation.

The app no longer exposes a separate inactivity timer. Preserve the existing
`inactivity` value and CLI compatibility on all unrelated app edits. Its
relationship to grace and native activity detection remains an unresolved
production design decision; do not invent behavior or expose a placeholder knob.
The other underlying settings and CLI ranges remain unchanged.

Guidance dialogs take focus above Settings and return to their original button;
Escape closes the guidance first. Local hashes #settings/protection,
#settings/connectivity and #settings/advanced open the corresponding focused tab,
without reading query values or saving preferences. Default startup is unchanged.

## Network return and wake

Keep underlying path availability separate from independently verified internet.
Path changes and normal wake request a bounded check rather than declaring
success: 10-second cap, 30-second eligible start cadence, one active check and
coalesced events. Lightweight checks continue after the configured hotspot join budget is
exhausted without granting another join or prompt. Verified recovery clears the
outage ledger and refreshes samples.

No probes or joins run asleep or during maintenance wake. Explicit Stop, unsafe
battery, missing setup, ownership conflicts, exhausted crash recovery and login
opt-out take priority. Connectivity-only pauses may restore enabled protection
while awake after verification; inactivity release still waits for normal wake.
Nightr restores its own protection. Individual coding agents handle their own
reconnections; never claim to reconnect their sessions.

Use [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor)
for path events and [NSWorkspace.didWakeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification)
registered on the shared workspace's notification center. A path event is a
verification trigger, not proof of usable internet.

## CLI

Use `nightr setup` for first-run machine readiness and repair (helper, permissions,
owned links and login integration), and `nightr config` for everyday preferences.
Both use shared settings where appropriate; setup never resets user choices.
Installation and updates belong to the package manager or installer, not a
redundant `nightr install` command. Keep status/config display read-only.

Show Instant Hotspot/Auto-Join and saved Wi-Fi fallback as distinct features.
Setup explains OS prerequisites and unknown or unsupported states; config edits
fallback policy. Never imply that Instant Hotspot requires a password/Allow
Others to Join or that older macOS has Automatic Hotspot. Network-wake settings
are outside the approved product scope.
Follow the extracted t terminal contract: cyan headings, green healthy states,
amber pending/grace/retry states, red errors, muted explanatory/footer text,
inline rails, arrow-key or j/k navigation, Enter to edit, staged review/save/cancel.
Static/JSON output never opens a picker or install prompt. Source design:
https://github.com/agenthangar/t/blob/main/ui/README.md.

The t integration preview must include the complete real parent menu and working
isolated sibling flows. Label the proposed Nightr entry. Preserve parent focus,
pending edits and save/discard navigation. Do not present inert menu items.

## Websites

Reuse AgentHangar's current dark warm-gray/amber direction: background #141516,
raised #1c1d1f, ink #ebe7df, muted #b8b3a8, accent #f2a93b. Space Grotesk is the
website heading/body typeface, IBM Plex Mono the technical face; local/system
fallbacks must work offline. Existing source:
https://github.com/agenthangar/agenthangar.github.io/blob/main/styles.css.

Product copy: “You sleep. Your agents don't.” Pair it with the concrete promise:
keep your Mac awake for coding-agent work, with battery and connectivity controls.
Show the app and CLI, explain install requirements honestly, and link source.
Prototype copy must label proposed capabilities; no invented testimonials/stats.

Use **Download for macOS** as the primary product action. The intended release
is a prebuilt universal app for Apple Silicon and Intel, delivered in a signed
and notarized DMG containing a signed macOS installer. The package installs the
app, CLI, protected helper and runtime. The user path is Download → Installer →
open → explicit helper authorization. No Xcode,
developer tools or separate Python installation should be required. Contributor
build instructions belong in developer documentation. Until a release artifact
exists, simulate the flow and state clearly that no download is available. Do
not invent artifact URLs or imply signing/notarization is already complete.

Preserve AgentHangar's existing hero, roof/H logo and sibling tabs. Insert Nightr
directly after t. The inactive tab needs the moon glyph, approximately 18px label,
legible amber NEW badge and subtle amber background/border; selection adds a
separate underline. Preserve mobile and keyboard sibling navigation.

## Icons and approval

The approved and locked direction is the original **moon with awake spark**,
concept 1. Use it across every app and website surface. Other exploratory
concepts are no longer selection options. Render actual-size monochrome menu
glyphs (16/18/22px) on light/dark bars, app icons, favicon tabs and website marks.
State variations remain legible without color. The user approved the revised
interface and implementation on 2026-11-14, with network-wake settings removed.

## Preview contract

`design-preview/` is an isolated browser simulation, not product code. All app,
terminal, phone, network and installer actions act only on synthetic in-memory
state. Never send passwords or invoke real commands. Label fictional data,
simulated external actions and what the user should try. Provide reset and a
guided walkthrough. The preview must work directly from its index.html and from
a loopback static server, including mobile-sized viewports.

Protection section headings share one 15px semibold foreground style and spacing.
Lid settings use a compact label/control grid so the display selector and lock
checkbox align without stretching across the window.

### Checking the macOS implementation against the preview

Use the Settings opened from the activity popover as the reference. The approved
revision is [88b93ca](https://github.com/agenthangar/nightr/blob/88b93cabf1f2be3e311a6bc4ab4f75aa796e1713/design-preview/activity.html).
Compare every Settings tab and the populated popover in both Light and Dark at
the same logical size. Use the same synthetic model and preference values.

The debug app’s `--render-presentations OUTPUT_DIRECTORY` command renders the
production Settings window offscreen, including its title bar, and checks the
title position, window dimensions, General controls and keyboard navigation.
Inspect these captures beside the browser reference before merging presentation
changes. During signed installation acceptance, open Settings from the menu bar
and check window controls and focus. General contains login and notification
controls. A confirmed helper authorization request belongs in the popover or
explicit setup flow.

## Native connectivity references

- [Apple Instant Hotspot and Auto-Join](https://support.apple.com/en-us/109321):
  eligible nearby account/family devices can join without a password or Allow
  Others to Join; Automatic on Mac requires macOS Tahoe 26 or later.
- [CoreWLAN](https://developer.apple.com/documentation/corewlan): the macOS Wi-Fi
  interface/network API to investigate for native discovery and association.
  [NEHotspotConfigurationManager](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager)
  is not a general native-macOS Wi-Fi solution.

Do not commit actual device capability observations, account data or credentials.
The browser profiles are generic synthetic examples only.
