'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const root = path.join(__dirname, '..');
const icon = 'design-preview/nightr-app-icon.png';
const capture = 'site/assets/screenshots/popover-on-dark.png';
const output = path.join(root, 'docs/assets/readme-banner.png');

function pngSource(file) {
  return 'data:image/png;base64,' + fs.readFileSync(path.join(root, file), 'base64');
}

async function render() {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({
      viewport: { width: 880, height: 456 },
      deviceScaleFactor: 2,
    });
    await page.setContent(`<!doctype html>
      <html lang="en"><head><meta charset="utf-8">
      <title>Nightr README banner</title>
      <style>
        * { box-sizing: border-box; }
        body { margin: 0; font-family: "Space Grotesk", system-ui, sans-serif; }
        main {
          position: relative;
          display: grid;
          grid-template-columns: 1fr 210px;
          align-items: center;
          gap: 26px;
          width: 100vw;
          height: 100vh;
          padding: 0 44px 0 54px;
          overflow: hidden;
          isolation: isolate;
          border: 1px solid #40382b;
          border-radius: 20px;
          color: #ebe7df;
          background:
            radial-gradient(ellipse at 88% 10%, #533c21 0%, transparent 55%),
            linear-gradient(120deg, #141516 35%, #252018);
        }
        main::before {
          content: "";
          position: absolute;
          z-index: -1;
          inset: -186px -185px auto auto;
          width: 668px;
          height: 668px;
          border: 1px solid #f2a93b24;
          border-radius: 50%;
        }
        .brand {
          display: flex;
          align-items: center;
          gap: 12px;
          font-size: 26px;
          font-weight: 700;
          letter-spacing: -.035em;
        }
        .headline {
          margin: 24px 0 0;
          font-size: 58px;
          line-height: 1.04;
          font-weight: 750;
          letter-spacing: -.055em;
          white-space: nowrap;
        }
        .headline em { color: #f2a93b; font-style: normal; }
        .capture {
          display: block;
          width: 100%;
          height: auto;
          border-radius: 12px;
          box-shadow: 0 0 0 1px #ebe7df22, 0 14px 44px #0009;
        }
      </style></head>
      <body><main>
        <div>
          <div class="brand"><img src="${pngSource(icon)}" width="44" height="44" alt="">nightr</div>
          <h1 class="headline">You sleep.<br>Your agents <em>don’t.</em></h1>
        </div>
        <img class="capture" src="${pngSource(capture)}" alt="Nightr menu bar pane">
      </main></body></html>`);
    await page.evaluate(async () => {
      await document.fonts.ready;
      await Promise.all([...document.images].map(image => image.decode()));
    });
    fs.mkdirSync(path.dirname(output), { recursive: true });
    await page.locator('main').screenshot({ path: output, omitBackground: true });
  } finally {
    await browser.close();
  }
}

render().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
