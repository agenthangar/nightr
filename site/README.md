# Nightr website

Static site for nightr.ai. Serve locally with `python3 -m http.server 8945 --directory site --bind 127.0.0.1`.
The site has no build or JavaScript dependency. All illustrative app data is synthetic.

Publish the `site/` directory with GitHub Pages after review. `CNAME` specifies the intended apex; it does not configure DNS. Preserve unrelated Cloudflare records. DNS changes and HTTPS verification belong to the deployment step.

Until a validated signed release is published, keep source/releases as the primary actions and installation instructions clearly marked as planned. Replace those notices only after checking the actual release artifacts and installer instructions. Do not invent download URLs.
