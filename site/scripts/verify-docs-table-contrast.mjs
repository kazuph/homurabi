#!/usr/bin/env node
/**
 * Playwright: docs の table th のコントラスト比（WCAG）を計測。
 * Usage: node scripts/verify-docs-table-contrast.mjs [baseUrl]  (default http://127.0.0.1:8787)
 */
import { chromium } from 'playwright';

const base = process.argv[2] || 'http://127.0.0.1:8787';
const paths = ['/docs/sinatra', '/docs/sequel-d1', '/docs/runtime', '/docs/architecture'];

function parseRgb(s) {
  const m = String(s).match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+)\s*)?\)/);
  if (!m) return null;
  return { r: +m[1], g: +m[2], b: +m[3], a: m[4] !== undefined ? +m[4] : 1 };
}

/** docs ダーク時の --docs-bg (#111827) 上に半透明背景を合成した RGB */
function compositeOnDocsDark(bg) {
  const bottom = { r: 17, g: 24, b: 39 };
  if (!bg || bg.a >= 1) return { r: bg.r, g: bg.g, b: bg.b };
  const a = bg.a;
  return {
    r: bg.r * a + bottom.r * (1 - a),
    g: bg.g * a + bottom.g * (1 - a),
    b: bg.b * a + bottom.b * (1 - a),
  };
}

function luminance(r, g, b) {
  const f = (c) => {
    c /= 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}

function contrastRatio(fg, bg) {
  const L1 = luminance(fg.r, fg.g, fg.b);
  const L2 = luminance(bg.r, bg.g, bg.b);
  const lighter = Math.max(L1, L2);
  const darker = Math.min(L1, L2);
  return (lighter + 0.05) / (darker + 0.05);
}

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1440, height: 900 },
  colorScheme: 'dark',
});

const results = [];
for (const p of paths) {
  await page.goto(`${base}${p}`, { waitUntil: 'networkidle', timeout: 60000 });
  const row = await page.evaluate(() => {
    const el = document.querySelector('.docs-main th');
    if (!el) return null;
    const cs = getComputedStyle(el);
    return {
      color: cs.color,
      backgroundColor: cs.backgroundColor,
    };
  });
  if (!row) {
    results.push({ path: p, error: 'no th' });
    continue;
  }
  const fg = parseRgb(row.color);
  const bgRaw = parseRgb(row.backgroundColor);
  let ratio = null;
  if (fg && bgRaw) {
    const bg = compositeOnDocsDark(bgRaw);
    ratio = Math.round(contrastRatio(fg, bg) * 100) / 100;
  }
  results.push({
    path: p,
    ...row,
    backgroundCompositeRgb: bgRaw ? compositeOnDocsDark(bgRaw) : null,
    contrastRatio: ratio,
    wcagAAPass: ratio != null && ratio >= 4.5,
  });
}

await browser.close();
console.log(JSON.stringify(results, null, 2));
