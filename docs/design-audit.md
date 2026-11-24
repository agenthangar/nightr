# App and preview design audit

[Design decision index](../DESIGN.md#decisions-and-regression-checks) · [Review issue 48](https://github.com/agenthangar/nightr/issues/48)

| Surface | Finding and change | How to verify |
| --- | --- | --- |
| Connectivity | Automatic used green for its glyph and ordinary ink for its label. Connected, Active, Automatic and a saved credential now use the same native confirmed-state component. Ask to Join, Never and Unknown retain neutral ink. The adjacent Wi-Fi link has its own accessible name and action. | The native fixture locates the rendered word and inspects its pixels separately from the glyph. It exercises all four hotspot modes in light and dark. The browser test also checks computed color and keyboard focus. |
| Main pane and model details | The activity preview and lifecycle preview had drifted on force controls. The pane now shows the force action and restores prior intent when force ends. The populated activity fixture shows runtime and state before opening details. | In the native preview, open the generating and idle model rows. The debug renderer captures both detail views in both appearances. The browser interaction check exercises force restoration, dismissal and reopening. |
| Settings | The HTML Protection pane overflowed by 69 logical pixels at the default size. Old condition indents and overlapping group margins also broke the row grid. The browser now uses compact trailing controls. Advanced uses exact durations and count fields. | The browser measures all four tabs at the default size. The native renderer checks final rows and footer actions in all tabs. Native layout tests measure visible control edges with the cutoff enabled and disabled. |
| Hotspot chooser | Saved, Nearby and Manual need stable heading and footer positions. An unsaved secured network needs a visible masked password input. Selecting a network stages fallback together with the SSID. | The native fixture traverses the actual controls in both appearances, compares anchors, and selects secured, saved and open rows. Offline browser contracts cover credentials, cancellation, failed Save and retry. |
| Click-away | The detached preview window could survive a click in another app. The hot-reload host now shares the native outside-click monitor and dismisses its fallback window on deactivation. | The AppKit fixture delivers the dismissal callback with a sheet open, after closing the sheet, and after reopening. The browser uses a real pointer click outside the pane. On macOS, a click delivered through Quartz to a separate fixture window also dismissed the running menu bar preview. |

## Repeat the checks

Run the offline contracts with `node design-preview/check-preview.cjs`. With Playwright and its managed Chromium headless shell available, run `node design-preview/check-browser.cjs`. Set `NIGHTR_PREVIEW_CAPTURES` to an existing directory to keep browser and native fixture screenshots.

On macOS, run `swift build --product NightrApp`, then `.build/debug/NightrApp --render-presentations OUTPUT_DIRECTORY`. The native preview fixture is opt-in and runs with `"design-preview/native/Open Settings Preview.command" --check`. Open the same launcher without arguments for the interactive hot-reload preview. All fixture data is synthetic.
