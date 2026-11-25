# Nightr website

Static site for nightr.ai. Serve locally with `python3 -m http.server 8945 --directory site --bind 127.0.0.1`.
The site has no build or JavaScript dependency.

The website and root README share the native menu bar screenshot in
`assets/screenshots/`. The current capture uses the merged app from
`da1a4e3` (PR #56). To refresh it on macOS, run `swift build --product NightrApp`
from the repository root, then `.build/debug/NightrApp --render-presentations OUTPUT_DIRECTORY`.
Copy `popover-on-dark.png` from that output.
The renderer uses synthetic data and runs without starting the controller.
After updating the capture, run `node design-preview/render-readme-banner.cjs`
with Playwright available to refresh the repository README banner.

Publish the `site/` directory with GitHub Pages after review. `CNAME` specifies the intended apex; it does not configure DNS. Preserve unrelated Cloudflare records. DNS changes and HTTPS verification belong to the deployment step.

Use the GitHub Releases index for downloads until a public artifact and its
installer instructions are verified. Link directly to a DMG only after verifying
its release URL.
