// Renders public/og.png (1200×630) from the real overview screenshot and the mark.
// Usage: npm run og. Uses the installed Google Chrome through Playwright.
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const root = new URL('../', import.meta.url);
const asset = (path) => new URL(path, root).href;
const font = asset(
  'node_modules/@fontsource-variable/schibsted-grotesk/files/schibsted-grotesk-latin-wght-normal.woff2',
);

const html = `<!doctype html>
<html><head><meta charset="utf-8"><style>
@font-face { font-family: 'Schibsted Grotesk'; src: url('${font}') format('woff2'); font-weight: 400 900; }
* { box-sizing: border-box; margin: 0; }
body { width: 1200px; height: 630px; overflow: hidden; background: #1b1b1b; color: #fafafa;
  font-family: 'Schibsted Grotesk', system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
.copy { position: absolute; left: 72px; top: 72px; width: 600px; }
.brand { display: flex; align-items: center; gap: 14px; font-size: 30px; font-weight: 700; letter-spacing: -0.01em; }
.brand svg { fill: none; stroke: #3fd9c3; stroke-linecap: round; stroke-width: 58; }
h1 { margin-top: 64px; font-size: 64px; line-height: 1.04; letter-spacing: -0.035em; font-weight: 750; }
p { margin-top: 28px; font-size: 24px; line-height: 1.4; color: #d4d4d4; }
.shot { position: absolute; right: 64px; top: 52px; width: 356px; border-radius: 18px; overflow: hidden;
  box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08), 0 30px 60px -20px rgb(0 0 0 / 0.7); }
.shot img { display: block; width: 100%; }
</style></head><body>
<div class="copy">
  <div class="brand">
    <svg width="40" height="40" viewBox="200 220 600 620" aria-hidden="true">
      <path d="M262 420H640A71 71 0 1 0 586 302"/><path d="M262 536H742" opacity=".85"/><path d="M262 652H562A70 70 0 1 1 508 767" opacity=".7"/>
    </svg>Second Wind
  </div>
  <h1>Codex and Claude usage limits in your menu bar</h1>
  <p>Free and open source. For macOS 14 and later.</p>
</div>
<div class="shot"><img src="${asset('public/screens/overview.png')}" alt=""></div>
</body></html>`;

const work = new URL('.qa/', root);
await mkdir(work, { recursive: true });
const page = new URL('og.html', work);
await writeFile(page, html);

const browser = await chromium.launch({ channel: 'chrome' });
const tab = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await tab.goto(page.href);
await tab.evaluate(() => document.fonts.ready);
await tab.screenshot({ path: fileURLToPath(new URL('public/og.png', root)) });
await browser.close();
