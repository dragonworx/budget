#!/usr/bin/env node
// CPU calibration (spec 005 clarification): runs a fixed dart2js workload
// (tool/perf/calibrate_workload.dart) in headless Chromium, unthrottled,
// and prints the median of N runs. Compare it with the same script on the
// reference phones (audit §5) to relate box numbers to real devices.
//
//   NODE_PATH=$(npm root -g) node tool/perf/calibrate.mjs [--runs=5] [--throttle=1]
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, ...v] = a.replace(/^--/, '').split('=');
    return [k, v.join('=') || 'true'];
  }),
);
const runs = Number(args.runs ?? 5);
const throttle = Number(args.throttle ?? 1);
const here = dirname(fileURLToPath(import.meta.url));
const out = join(mkdtempSync(join(tmpdir(), 'calib-')), 'w.js');
execFileSync('dart', ['compile', 'js', '-O2', '-o', out, join(here, 'calibrate_workload.dart')], {
  stdio: 'ignore',
});
const js = readFileSync(out, 'utf8');
const browser = await chromium.launch();
const times = [];
let checksum;
for (let i = 0; i < runs; i++) {
  const page = await browser.newPage();
  if (throttle > 1) {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: throttle });
  }
  const done = page.evaluate(
    () => new Promise((res) => (window.__calibrateDone = (ms, c) => res([ms, c]))),
  );
  await page.addScriptTag({ content: js });
  const [ms, c] = await done;
  times.push(ms);
  checksum = c;
  await page.close();
}
await browser.close();
times.sort((a, b) => a - b);
console.log(
  JSON.stringify({ runs, throttle, medianMs: times[runs >> 1], minMs: times[0], maxMs: times[runs - 1], checksum }),
);
