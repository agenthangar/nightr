# Nightr design system

This is the implementation brief authorized by the launch plan. The user approved
concept 1, the moon with awake spark, and approved proceeding with implementation
after removing Wake for network access on 2026-11-14. Network-wake settings and
guidance are outside the approved product scope; normal-wake recovery remains.

## Decisions and regression checks

Use this index when changing the app, either preview, the CLI or the website. The November 14 mockup is the visual baseline. The decisions below record subsequent review feedback. The Swift preview loads the production views and uses synthetic observations. The browser preview exercises the same interactions with fictional data.

| Area | Decision | Implementation and evidence |
| --- | --- | --- |
| Brand and appearance | Use the desktop moon-and-spark icon in the pane header. Give the menu bar distinct active, inactive and force silhouettes. Respect light and dark appearance throughout sheets and menus. | `MoonSparkArtwork`, `SettingsToolbar`, `NativePresentationRenderer.checkArtwork` and the light/dark pane captures |
| Status | For confirmed Connected, Active, Automatic and saved credentials, color the circled check **and the label** green. Show a checking state while observations are pending. Use ordinary ink for Unknown, Ask to Join and Never. Keep the Wi-Fi Settings link a separate accessible action. | `NightrStatusLabel`, `CompactSettingsForm`, `checkStatusInk` in the native preview check and the browser confirmed-status tests |
| Main pane | Put protection and its actions first. Force mode uses an amber lightning bolt and a named action to end it. While forced, the Internet and Agent rows both read “Checks paused” in neutral ink. Ending force restores the previous intent. Stop ends protection. Clicking the menu icon opens the pane even with Settings open. Clicking elsewhere dismisses it. | `NightrPopover`, `MenuPopoverDismissal`, native pane fixtures and `testForceOverridesChecksButHonorsSafetyAndOriginalIntent` |
| Models and diagnostics | Show model name, runtime and generating or loaded/idle state up front. Show available throughput beside generation. Keep context and memory in details. Omit unexplained evidence, freshness and expiry rows. Use cyan for CPU and amber for GPU, with numeric labels. | `ActivityPresentation`, populated native pane preview and `design-preview/activity.html` |
| Settings | Center the window title, preserve toolbar icon padding and give the four tabs a common layout. Use system type, readable secondary ink, a shared checkbox, a fixed footer and one pending draft. | `SettingsLayout`, `CompactSettingsForm`, full-window keyboard, title, artwork and checkbox render checks |
| Rows and fields | Follow Advanced for all forms. Align labels and hints left and visible controls right. Use a compact menu, a single duration field with unit control, or a compact count field with a separate native stepper 6pt to its right. Keep explanatory copy beside the relevant option. | `CompactSettingsForm`, `NetworkChooser`, native protection-edge, chooser-anchor and count-stepper checks |
| Protection | Under “Keep Mac awake”, label each automatic condition with “When”. Offer temporary Force mode on the main pane and in Protection. Keep the battery row visible by default and enable its 20% cutoff on new configurations. Respect explicit opt-out and external power. | `testBatteryCutoffDefaultsAndSavedOptOut`, `testForceOverridesChecksButHonorsSafetyAndOriginalIntent`, native Protection capture |
| Connectivity | Show observed internet and hotspot preference first. Use the same row alignment for backup hotspot, delay and attempts. Choosing a network enables fallback in the draft. Reuse saved passwords and request a masked password for an unsaved secured network. | `NetworkChooser`, native three-tab geometry and secured/saved/open interaction checks, browser draft and credential tests |
| CLI and website | Preserve CLI flags, configuration semantics and explicit Stop. Use the approved icon and the website typography and navigation specified below. | CLI contracts and the website, icon and lifecycle checks in `design-preview/check-preview.cjs` |

For the evidence from the current review, see the [app and preview audit](docs/design-audit.md).

## Product

Nightr keeps a Mac awake while coding agents work. Explain observed protection,
activity, internet, battery and recovery clearly. Never imply remote control of
an iPhone's Personal Hotspot switch or guarantee work continues through system
sleep. An explicit Stop remains stopped on wake and login.

## Native app

Use familiar macOS menu bar and Settings conventions, system typography,
keyboard access, light/dark appearance and accessible controls. Put Start or Stop and the separate Force mode action above the diagnostics. Separate configured behavior from
observed state. On, Off, Paused, Recovering and Error have textual labels as well
as distinguishable glyph treatments. Do not rely on color alone.

Settings uses a compact native window 470pt wide and up to 630pt high with General,
Protection, Connectivity and Advanced sections. Use 15pt row labels and smaller secondary text and aligned 37pt rows. Keep padding modest and Save, Cancel
and Reset visible. Opening Settings selects General each time. A section link selects its named destination.
One draft spans all sections; switching never loses pending
values. Preserve every existing setting. Keyboard focus enters the selected tab,
stays inside the dialog, and returns to the invoking control on Save or Cancel.
Escape cancels; section tabs support arrow keys, Home and End. The Settings
window follows the selected light/dark appearance; its native palette must not
be overridden by default dark component variables. Standard and disabled buttons
need explicit light-appearance fills, borders and readable text as well.

Use the native checkbox style for binary Settings controls across all tabs.
The login and notification rows share the same trailing alignment, size, tint,
and checkmark. The notification checkbox reflects the permission reported by
macOS. Activating it requests permission or opens notification settings.

The visual reference is [Rectangle Settings](https://rectangleapp.com/assets/images/shortcutScreenshot.jpg).
Borrow its native density and organization, not its product controls.

Use Advanced as the reference for form rows, including the hotspot chooser.
Align labels and optional hints on the left, center controls vertically, and
align their visible right edges to the form inset. Give required password entry
a key icon and an accent outline. Network name, Security and Password share the same field height, fill and inset. Keep the password field steady while the network name is being edited.

Keep both action buttons in equal-width columns and reserve two lines for the status description across pane states. Align the protection title and its description in one text column beside the status icon. Separate the protection buttons from Local models with a content-width divider and 20pt of space on each side. Use 10pt of vertical padding inside model rows and 14pt between diagnostic rows. Keep each model name close to its runtime.

The app and the hot-reload preview render the same native Settings form.
Protection uses four groups.

- **Force mode** has its own heading with a trailing checkbox. The heading turns amber when active. Checking or unchecking it takes effect immediately, uses the same commands as the menu bar pane, and preserves unsaved rule edits.
- **Keep Mac awake** groups the three automatic rules. Each label starts with “When”. During Force mode, dim and disable these three rules while preserving their selections. Local inference can independently keep the Mac awake.
- **When lid closes** aligns the Display menu and Lock Mac checkbox to the
  same trailing edge as the conditions.
- **On battery** enables Allow sleep below at 20% by default. Preserve an
  explicit opt-out and retain the threshold when disabled. On battery, Nightr
  releases its hold below the cutoff in either awake mode.

Hidden automatic conditions retain their selection and are excluded
from focus. An existing until-stopped configuration offers **Use automatic rules**, which stages the change for Save.
Only an intentional condition toggle normalizes `require=all`. Rendering,
browsing and unrelated Save preserve imported policies and empty legacy checks.
A newly edited empty Automatic selection shows “Select agent activity or internet availability.” The CLI retains its full legacy policy controls. All fields share one
Save/Cancel/Reset draft and battery safety applies regardless of the awake mode.

Connectivity places internet verification and the macOS Ask to join hotspots
preference at the top. The latter opens Wi-Fi Settings. Hotspot fallback groups
the enable checkbox, network chooser, delay and attempt limit. Selecting a
network enables fallback. Failed credential access exposes the repair action.

Settings keeps its header and actions outside the scrollable content. Only the
content pane scrolls, so the last source row cannot sit beneath the footer.


Avoid large status cards or repeated availability paragraphs. Unknown macOS
capabilities remain informational; no help button reads or changes OS settings.
Full prerequisites belong here, not in modal paragraphs.

The hotspot field displays the selected exact name in a trailing chooser button. The nested chooser has Saved, Nearby and Manual source tabs:
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

Use network stages the chosen SSID and enables fallback in the parent draft.
Parent Save applies the draft. Cancel or Escape discards the chooser edits.
Source tabs and network selection support keyboard navigation. Cancel outstanding
scans when the chooser closes and ignore out-of-date results. Previews use
synthetic networks.

Network security is separate from discovery availability. Saved is Keychain-only:
no credential fields or security choices. Omit password notices for a usable or previously entered credential. Use network stages the exact SSID,
without creating credentials for missing/unknown entries. Existing explicitly
validated pending metadata for the same SSID may be retained, but ordinary list
selection cannot write or clear Keychain metadata.

Nearby reuses an exact-SSID saved or validated pending password without displaying
an input by default. On Nearby, Change password opens an empty secure field for that network.
Use network stages the replacement and Settings Save commits it. A secured network missing both reveals the masked inline password and
requires it before Use network. The picker explains that authentication occurs at join time.
Selecting or saving a nearby network must leave the current connection intact. Unknown Nearby security requires explicit Open or
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
Advanced uses the adjustment-sliders glyph. **Automatic checks** contains
Check interval. **Before allowing sleep** groups Initial wait, Number of
rechecks and First retry delay. Show the scheduled wait as the initial wait plus
all retry delays, doubling each delay up to five minutes. Recalculate on edit. Place a short hint below each label.
Use exact integer fields with an integrated sec/min selector and a stepper for
counts. Preserve seconds when switching tabs and when saving. The interval range
is 1–3600 seconds, the grace range is 0–86400 seconds and the first delay range
is 1–300 seconds. Zero rechecks disables the delay and retains its value.
Validate the entered value before saving and keep keyboard focus while editing.

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
success. Use a 10-second cap, the saved Check interval (30 seconds by default), one active check and
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

Protection section headings share one semibold system type style and spacing.
Lid settings use a compact label/control grid so the display selector and lock
checkbox align without stretching across the window.

### Checking the macOS implementation against the preview

Use the Settings opened from the activity popover as the reference. The approved
revision is [88b93ca](https://github.com/agenthangar/nightr/blob/88b93cabf1f2be3e311a6bc4ab4f75aa796e1713/design-preview/activity.html).
Compare every Settings tab and the populated popover in both Light and Dark at
the same logical size. Use the same synthetic model and preference values.
Compare the visible symbol and label bounds inside each toolbar tile. In the
General tab, the gear starts about 14 points below the tile’s top edge.
The popover header uses the full-color desktop app icon. The menu bar uses the
monochrome template glyph.

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
