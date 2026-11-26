// Visual and accessibility pass against a running preview (`npm run preview`).
// Usage: node scripts/qa.mjs [url]. Screenshots go to .qa/ (gitignored).
// Uses the installed Google Chrome so no Playwright browser download is needed.
import { mkdir } from 'node:fs/promises';
import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { AxeBuilder } from '@axe-core/playwright';

const url = process.argv[2] ?? 'http://localhost:4317/';
const out = fileURLToPath(new URL('../.qa/', import.meta.url));
await mkdir(out, { recursive: true });

const browser = await chromium.launch({ channel: 'chrome' });
const results = [];

async function page(name, { width, height, colorScheme, reducedMotion = 'no-preference' }) {
  const context = await browser.newContext({
    viewport: { width, height },
    deviceScaleFactor: 2,
    isMobile: width < 600,
    hasTouch: width < 600,
    colorScheme,
    reducedMotion,
  });
  const p = await context.newPage();
  const errors = [];
  p.on('pageerror', (error) => errors.push(error.message));
  p.on('console', (message) => message.type() === 'error' && errors.push(message.text()));
  const response = await p.goto(url, { waitUntil: 'networkidle' });
  assert.equal(response?.status(), 200, `Page response at ${url}`);
  const headerFilter = await p.locator('.site-header').evaluate((header) => getComputedStyle(header).backdropFilter);
  assert.match(headerFilter, /blur\(/, 'The sticky header blurs text underneath it');
  await p.waitForTimeout(reducedMotion === 'reduce' ? 300 : 1800);
  return { p, context, errors, name };
}

async function audit({ p, context, errors, name }) {
  const axe = await new AxeBuilder({ page: p }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
  const serious = axe.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  const overflow = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  results.push({
    name,
    errors,
    overflow,
    serious: serious.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(', ')}`),
    minor: axe.violations.filter((v) => !serious.includes(v)).map((v) => `${v.impact} ${v.id}`),
  });
  await context.close();
}

for (const colorScheme of ['dark', 'light']) {
  for (const [label, width, height] of [
    ['1440', 1440, 900],
    ['390', 390, 844],
  ]) {
    const run = await page(`${label}-${colorScheme}`, { width, height, colorScheme });
    await run.p.screenshot({ path: `${out}${run.name}-fold.png` });
    // Scroll through once so in-view reveals and lazy images settle before the full capture.
    await run.p.evaluate(async () => {
      for (let y = 0; y < document.body.scrollHeight; y += 400) {
        window.scrollTo(0, y);
        await new Promise((resolve) => setTimeout(resolve, 120));
      }
      window.scrollTo(0, 0);
    });
    await run.p.waitForTimeout(1200);
    for (const img of await run.p.locator('main img').all()) {
      await img.evaluate((el) => el.decode());
    }
    await run.p.screenshot({ path: `${out}${run.name}-full.png`, fullPage: true });
    await audit(run);
  }
}

{
  const run = await page('320-install', { width: 320, height: 700, colorScheme: 'dark', reducedMotion: 'reduce' });
  await run.p.locator('.hero a[href="#install"]').click();
  assert.equal(new URL(run.p.url()).hash, '#install');
  const install = run.p.locator('#install');
  assert.equal(await install.getByRole('link', { name: /download/i }).getAttribute('href'),
    'https://github.com/nicolasdmolina/codex-weekly-reset-guard/archive/refs/heads/main.zip');
  assert.match(await install.innerText(), /\.\/scripts\/install_app\.sh/);
  await audit(run);
}

// Reduced motion: everything must be visible at first paint with no entrance.
{
  const run = await page('1440-dark-reduced', { width: 1440, height: 900, colorScheme: 'dark', reducedMotion: 'reduce' });
  await run.p.screenshot({ path: `${out}${run.name}-fold.png` });
  await audit(run);
}

// Keyboard: skip link, then the first few stops.
{
  const run = await page('1440-light-focus', { width: 1440, height: 900, colorScheme: 'light' });
  await run.p.keyboard.press('Tab');
  await run.p.screenshot({ path: `${out}focus-skip-link.png`, clip: { x: 0, y: 0, width: 1440, height: 120 } });
  for (let i = 0; i < 6; i += 1) await run.p.keyboard.press('Tab');
  await run.p.screenshot({ path: `${out}focus-hero-cta.png` });
  await audit(run);
}

// Mobile tabs: arrow-key switching between app states.
{
  const run = await page('390-dark-tabs', { width: 390, height: 844, colorScheme: 'dark' });
  const tab = run.p.getByRole('tab', { name: 'All clear' });
  await tab.focus();
  await run.p.keyboard.press('ArrowRight');
  await run.p.waitForTimeout(700);
  const selected = await run.p.getByRole('tab', { selected: true }).textContent();
  run.errors.push(...(selected === 'Codex low' ? [] : [`tab switch failed: ${selected}`]));
  await run.p.locator('.screen-tabs').screenshot({ path: `${out}mobile-tabs-codex-low.png` });
  await audit(run);
}

await browser.close();
for (const r of results) {
  console.log(
    `${r.name}: serious=${r.serious.length} minor=${r.minor.length} overflow=${r.overflow}px errors=${r.errors.length}`,
  );
  for (const line of [...r.serious, ...r.minor, ...r.errors]) console.log(`  ${line}`);
}
process.exitCode = results.some((r) => r.serious.length || r.errors.length || r.overflow > 0) ? 1 : 0;
