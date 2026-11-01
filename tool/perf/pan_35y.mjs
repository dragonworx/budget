#!/usr/bin/env node
// Timeline pan / zoom benchmark (spec 005 R4 + clarification).
//
//   NODE_PATH=$(npm root -g) node tool/perf/pan_35y.mjs \
//     [--profile=desk|mob6|mob4] [--app=http://127.0.0.1:8000] \
//     [--stream='PERF 50k'] [--runs=1] [--shot=out.png]
//
// Run against a PERF_HUD profile build served with an API on a `_perf`
// database seeded by server/tool/perf_seed.dart (dev login must be on):
//   flutter build web --profile --source-maps --pwa-strategy=none \
//     --dart-define=API_BASE_URL= --dart-define=PERF_HUD=true
//
// It dev-logs in, opens the stream by name at a 35-year view (saved view),
// then (1) drags 2,000 px over 3 s (back and forth so the data stays in
// view) and (2) zooms 35y -> 1y -> 35y (desk: Ctrl+wheel; mob: two-finger
// pinches over CDP touch events). It prints window.__budgiePerf for each
// phase and the /balance requests with their transfer vs decoded sizes.
//
// Profiles: desk = 1600x900 @1x, mouse + wheel. mob6 / mob4 = 390x844 @3x,
// isMobile + hasTouch, CPU throttled 6x / 4x (CDP), network 9 Mbps down /
// 1.5 Mbps up / 150 ms RTT. Mobile numbers are recorded, not gated.
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, ...v] = a.replace(/^--/, '').split('=');
    return [k, v.length ? v.join('=') : '1'];
  }),
);
const PROFILE = args.profile || 'desk';
const APP = (args.app || 'http://127.0.0.1:8000').replace(/\/$/, '');
const STREAM = args.stream || 'PERF 50k';
const PROFILES = {
  desk: { viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1, cpu: 1, net: null, touch: false },
  mob6: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, cpu: 6, net: true, touch: true },
  mob4: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, cpu: 4, net: true, touch: true },
};
const prof = PROFILES[PROFILE];
if (!prof) throw new Error(`unknown profile ${PROFILE}`);
const MAX_DAYS = 12785;

const browser = await chromium.launch();
const { cpu, net, touch, ...ctxOpts } = prof;
const ctx = await browser.newContext({ ...ctxOpts, timezoneId: 'Australia/Sydney' });
const page = await ctx.newPage();
const cdp = await ctx.newCDPSession(page);
const W = (ms) => page.waitForTimeout(ms);
const errors = [];
page.on('pageerror', (e) => errors.push(e.message.slice(0, 200)));

// /balance requests: transfer (encoded) vs decoded bytes.
await cdp.send('Network.enable');
const reqs = new Map();
cdp.on('Network.requestWillBeSent', (e) => {
  if (/\/api\/streams\/[^/]+\/balance/.test(e.request.url)) reqs.set(e.requestId, { url: e.request.url, decoded: 0, transfer: 0, encoding: '' });
});
cdp.on('Network.responseReceived', (e) => {
  const r = reqs.get(e.requestId);
  if (r) r.encoding = e.response.headers['content-encoding'] || e.response.headers['Content-Encoding'] || '';
});
cdp.on('Network.dataReceived', (e) => {
  const r = reqs.get(e.requestId);
  if (r) r.decoded += e.dataLength;
});
cdp.on('Network.loadingFinished', (e) => {
  const r = reqs.get(e.requestId);
  if (r) r.transfer = e.encodedDataLength;
});

// Sign in (dev bypass), find the stream, save a 35-year view on it.
await page.goto(`${APP}/api/auth/dev-login?redirect=/manifest.json`);
const stream = await page.evaluate(async (name) => {
  const r = await fetch('/api/streams', { headers: { 'x-requested-with': 'fetch' } });
  const j = await r.json();
  return (j.streams || j).find((s) => s.name === name);
}, STREAM);
if (!stream) throw new Error(`no stream named ${STREAM}`);
const seed = Date.UTC(...stream.seedDate.split('-').map((v, i) => (i === 1 ? v - 1 : +v))) / 864e5;
await page.evaluate(
  async ({ id, view }) => {
    const r = await fetch(`/api/streams/${id}/view`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json', 'x-requested-with': 'fetch' },
      body: JSON.stringify(view),
    });
    if (r.status !== 200) throw new Error(`saving the view: ${r.status} ${await r.text()}`);
    for (const k of Object.keys(localStorage)) if (k.startsWith('budget_view:')) localStorage.removeItem(k);
    localStorage.setItem('budget_events_docked', '0');
  },
  { id: stream.id, view: { start: seed, days: MAX_DAYS } },
);

if (cpu > 1) await cdp.send('Emulation.setCPUThrottlingRate', { rate: cpu });
if (net) {
  await cdp.send('Network.emulateNetworkConditions', {
    offline: false,
    latency: 150,
    downloadThroughput: (9e6 / 8) | 0,
    uploadThroughput: (1.5e6 / 8) | 0,
  });
}
const t0 = Date.now();
await page.goto(`${APP}/#/streams/${stream.id}/timeline`);
await page.waitForFunction(() => !document.getElementById('bl') && window.__budgiePerf, null, { timeout: 300000 });
await W(4000 * Math.max(1, cpu / 2));
const loadMs = Date.now() - t0;
if (args.shot) await page.screenshot({ path: args.shot.replace('.png', '-loaded.png') });

// Plot centre: the largest flt canvas / platform view area is the chart;
// use a point a little above the middle of the viewport.
const vw = prof.viewport.width, vh = prof.viewport.height;
const cx = vw / 2, cy = touch ? vh * 0.33 : vh * 0.45;

const perf = () => page.evaluate(() => window.__budgiePerf.snapshot());
const resetAll = async () => {
  reqs.clear();
  await page.evaluate(() => window.__budgiePerf.reset());
};
// Input goes out on a fixed schedule over CDP without waiting for each
// event to be handled (a slow frame doesn't stretch the gesture; the
// browser coalesces moves as it would for a real finger or mouse).
const pending = [];
const send = (method, params) => pending.push(cdp.send(method, params).catch(() => {}));
const touchSend = (type, points) => send('Input.dispatchTouchEvent', { type, touchPoints: points.map(([x, y], id) => ({ x, y, id })) });
const mouseSend = (type, x, y, extra = {}) => send('Input.dispatchMouseEvent', { type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1, ...extra });
async function schedule(events, durationMs) {
  const start = Date.now();
  for (let i = 0; i < events.length; i++) {
    const due = start + (i * durationMs) / Math.max(1, events.length - 1) - Date.now();
    if (due > 0) await W(due);
    events[i]();
  }
  const sent = Date.now() - start;
  await Promise.all(pending.splice(0));
  return sent;
}
// Waits until no chart paint for a second (at most 3 minutes).
async function settle() {
  const end = Date.now() + 180000;
  let last = -1, quietSince = Date.now();
  while (Date.now() < end) {
    const f = await page.evaluate(() => window.__budgiePerf.snapshot().paints);
    if (f !== last) { last = f; quietSince = Date.now(); }
    else if (Date.now() - quietSince > 1000) return;
    await W(250);
  }
}

// 2,000 px of drag in 3 s, back and forth by `amp` px (60 Hz steps).
async function drag() {
  const amp = Math.min(800, vw * 0.4);
  const steps = 180, step = 2000 / steps;
  const path = [cx + amp / 2];
  let x = path[0], dir = -1;
  for (let i = 0; i < steps; i++) {
    let nx = x + dir * step;
    if (nx < cx - amp / 2 || nx > cx + amp / 2) { dir = -dir; nx = x + dir * step; }
    path.push((x = nx));
  }
  const ev = touch
    ? [() => touchSend('touchStart', [[path[0], cy]]), ...path.slice(1).map((px) => () => touchSend('touchMove', [[px, cy]])), () => touchSend('touchEnd', [])]
    : [() => mouseSend('mouseMoved', path[0], cy, { buttons: 0, button: 'none' }), () => mouseSend('mousePressed', path[0], cy), ...path.slice(1).map((px) => () => mouseSend('mouseMoved', px, cy)), () => mouseSend('mouseReleased', path[path.length - 1], cy)];
  return schedule(ev, 3000);
}

// 35y -> 1y -> 35y.
async function zoom() {
  const ev = [];
  if (touch) {
    // Pinches of 2.4x (60 -> 144 px apart); 4 in, 4 out (2.4^4 ~ 33).
    const pinch = (from, to) => {
      const n = 20;
      ev.push(() => touchSend('touchStart', [[cx - from / 2, cy], [cx + from / 2, cy]]));
      for (let i = 1; i <= n; i++) {
        const d = from + ((to - from) * i) / n;
        ev.push(() => touchSend('touchMove', [[cx - d / 2, cy], [cx + d / 2, cy]]));
      }
      ev.push(() => touchSend('touchEnd', []));
      for (let i = 0; i < 6; i++) ev.push(() => {});
    };
    for (let i = 0; i < 4; i++) pinch(60, 144);
    for (let i = 0; i < 4; i++) pinch(144, 60);
  } else {
    // Ctrl+wheel = a browser pinch: scale exp(-deltaY / 200) per event.
    const total = Math.log(MAX_DAYS / 365) * 200;
    const n = 24;
    const wheel = (dy) => () => send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: cx, y: cy, deltaX: 0, deltaY: dy, modifiers: 2 });
    ev.push(() => mouseSend('mouseMoved', cx, cy, { buttons: 0, button: 'none' }));
    for (let i = 0; i < n; i++) ev.push(wheel(-total / n));
    for (let i = 0; i < n; i++) ev.push(wheel(total / n));
  }
  return schedule(ev, ev.length * 16);
}

const summary = (r) => {
  const list = [...r.values()];
  return {
    count: list.length,
    transferKB: Math.round(list.reduce((a, b) => a + b.transfer, 0) / 1024),
    decodedKB: Math.round(list.reduce((a, b) => a + b.decoded, 0) / 1024),
    encodings: [...new Set(list.map((b) => b.encoding || 'identity'))],
  };
};

const runs = +(args.runs || 1);
const out = { profile: PROFILE, stream: STREAM, loadMs, runs: [] };
for (let run = 0; run < runs; run++) {
  await resetAll();
  const panT0 = Date.now();
  const dragMs = await drag();
  await settle();
  const panSettledMs = Date.now() - panT0;
  const panPerf = await perf();
  const panBalance = summary(reqs);
  if (args.shot && run === 0) await page.screenshot({ path: args.shot.replace('.png', '-pan.png') });
  await resetAll();
  const zoomT0 = Date.now();
  const zoomMs = await zoom();
  await settle();
  const zoomSettledMs = Date.now() - zoomT0;
  const zoomPerf = await perf();
  const zoomBalance = summary(reqs);
  if (args.shot && run === 0) await page.screenshot({ path: args.shot.replace('.png', '-zoom.png') });
  out.runs.push({ pan: { ms: dragMs, settledMs: panSettledMs, perf: panPerf, balance: panBalance }, zoom: { ms: zoomMs, settledMs: zoomSettledMs, perf: zoomPerf, balance: zoomBalance } });
}
if (errors.length) out.errors = errors;
console.log(JSON.stringify(out));
await browser.close();
