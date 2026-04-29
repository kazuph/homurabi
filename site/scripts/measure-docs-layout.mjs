#!/usr/bin/env node
/**
 * Playwright: docs レイアウト幅を viewport ごとに計測。
 * Usage: node scripts/measure-docs-layout.mjs [baseUrl]  (default http://127.0.0.1:8787)
 */
import { chromium } from 'playwright';

const base = process.argv[2] || 'http://127.0.0.1:8787';
const paths = ['/docs', '/docs/quick-start', '/docs/migration'];
const viewports = [
  { name: '1440', width: 1440, height: 900 },
  { name: '1920', width: 1920, height: 900 },
  { name: '1280', width: 1280, height: 900 },
  { name: '768', width: 768, height: 900 },
];

const browser = await chromium.launch();
const results = [];

for (const vp of viewports) {
  const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } });
  for (const p of paths) {
    const url = `${base}${p}`;
    await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
    const m = await page.evaluate(() => {
      const vw = window.innerWidth;
      const body = document.body.getBoundingClientRect();
      const shell = document.querySelector('.docs-shell');
      const main = document.querySelector('.docs-main');
      const shellEl = shell?.getBoundingClientRect();
      const mainEl = main?.getBoundingClientRect();
      let rightGap = 0;
      if (shellEl) {
        rightGap = Math.max(0, vw - shellEl.right);
      }
      const grid = shell ? window.getComputedStyle(shell).gridTemplateColumns : '';
      return {
        vw,
        bodyWidth: Math.round(body.width),
        shellWidth: shellEl ? Math.round(shellEl.width) : 0,
        mainWidth: mainEl ? Math.round(mainEl.width) : 0,
        rightGapPx: Math.round(rightGap),
        gridTemplateColumns: grid,
      };
    });
    results.push({ viewport: vp.name, path: p, ...m });
  }
  await page.close();
}

await browser.close();
console.log(JSON.stringify(results, null, 2));
