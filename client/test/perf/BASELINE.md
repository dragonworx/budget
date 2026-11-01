# Timeline perf baseline (spec 005, phase 1)

Recorded 1 Nov 2026 (AEDT) on the box. Before = 8b282da + harness (402527d);
after = phase 1 (88bb0c4). Raw files: /workspace/perf-phase1/.

## flutter_tester, debug, 1600×900, 35y pan (`pan_bench_test.dart`)

| case | before median / p95 | after median / p95 | budget |
|---|---|---|---|
| lane-less 13.5k occ | 2,074 / 2,413 ms | 258 / 285 ms | ≤ 300 ✓ |
| lane-less 54k occ | 5,565 / 6,042 ms | 269 / 287 ms | ≤ 400 ✓ |
| lanes 13.5k | 204 / 228 ms | 219 / 245 ms | ≤ 225 ✓ (runs 198–226) |
| lanes 54k | 198 / 212 ms | 224 / 265 ms | ≤ 225 ✓ (runs 197–224) |
| new label TextPainter layouts / frame | not counted | 0 | ≤ 200 ✓ |
| new TextPainters on replayed pan frames | – | 0 | 0 ✓ |

Label candidates (dots past the crowding check) stay 3,828 / 3,860 per
frame: output-identical placement can't drop them.

## Playwright, profile web build + PERF_HUD, PERF 50k at 35y (`tool/perf/pan_35y.mjs`)

| profile / phase | before p50 / p95 frame | after p50 / p95 frame | notes |
|---|---|---|---|
| desk pan | 221 / 6,356 ms | 195 / 6,236 ms | long tasks 12 (17.9 s) → 9 (11.3 s); /balance during drag 2 → 1 |
| desk zoom | 888 / 5,678 ms | 837 / 5,796 ms | |
| mob6 pan | 892 / 72,190 ms | 855 / 59,739 ms | recorded only |
| mob6 zoom | 44,927 / 53,758 ms | 792 / 29,534 ms | recorded only |
| mob4 pan | 1,079 / 25,088 ms | 725 / 24,950 ms | recorded only |
| mob4 zoom | 16,795 / 36,140 ms | 546 / 36,451 ms | recorded only |

The web p95 is set by one multi-second long task per gesture (also present
before); that is not label layout, so the ≥3× web expectation is not met in
phase 1 (LOD, spec 006). The after-run's settle doesn't wait for the
debounced /balance fetch, so settledMs is not comparable.

`tool/perf/calibrate.mjs` (unthrottled, 5 runs): median 236.6 ms.

# Phase 2 (spec 006: client LOD, group markers, label budget), d0e4611

## flutter_tester debug median at 35y (`test/perf/pan_bench_test.dart`)

Budget: ≤ 40 ms at 1600×900, ≤ 25 ms at 390×844.

| size / mode | before (50k / 1M) | after 50k | after 200k | after 1M | budget |
|---|---|---|---|---|---|
| 1600 lane-less | 279 / 778 ms | 11.9 ms | 9.0 ms | 8.4 ms | ≤ 40 ✓ |
| 1600 lanes | ~220 ms | 15.2 ms | 16.2 ms | 15.3 ms | ≤ 40 ✓ |
| 390 lane-less | – | 5.4–6.5 ms | 5.4–6.5 ms | 5.4–6.5 ms | ≤ 25 ✓ |
| 390 lanes | – | 7.4–7.6 ms | 7.4–7.6 ms | 7.4–7.6 ms | ≤ 25 ✓ |

## Playwright, profile web build + PERF_HUD, PERF 50k at 35y (`tool/perf/pan_35y.mjs`)

Headless Chromium renders WebGL through SwiftShader, so rasterisation is
CPU-bound; absolute numbers are pessimistic versus real GPUs. "Before" is
the phase 1 after-run above.

| profile / phase | rAF p95 before → after | max frame after | long tasks after (count / total / longest) | heap |
|---|---|---|---|---|
| desk pan | 6,236 → 133 ms | 467 ms | 32 / 3.8 s / 252 ms | 51 MB |
| desk zoom | 5,796 → 250 ms | 500 ms | 29 / 5.0 s / 493 ms | 51 MB |
| mob6 pan | 59,739 → 767 ms | 767 ms | 15 / 5.3 s / 769 ms | 35.6 MB |
| mob6 zoom | 29,534 → 550 ms | 550 ms | 19 / 5.8 s / 522 ms | 35.6 MB |
| mob4 pan | 24,950 → 583 ms | 583 ms | 18 / 4.9 s / 586 ms | 40.1 MB |
| mob4 zoom | 36,451 → 383 ms | 450 ms | 22 / 5.7 s / 436 ms | 40.1 MB |

The harness records long-task count, total and longest only; with 15–32
tasks per run the long-task p95 is ≈ the longest. The multi-second task
per gesture was CanvasKit rasterising antialiased multi-contour coarse
paths (`drawPicture` ≈ 5 s vs ≈ 25 ms Dart paint); coarse fills and the
lane ribbon are now non-antialiased (L0 unchanged).

Gates met: flutter_tester medians; mob6 heap ≤ 80 MB (35.6 MB).

Gates not met: DESK p95 ≤ 8 ms / max ≤ 16 ms; MOB-6x p95 ≤ 33 ms /
max ≤ 50 ms; 0 long tasks during gestures on MOB-6x; touch latency p95
≤ 40 ms (not measured: harness latency empty); real-device checklist
not done; no browser 200k/1M numbers (no PERF_SYNTH).

Not built in phase 2: viewport ValueNotifier (`_applyViewport` still
setStates per frame); pointer coalescing; holding v1 decode until 120 ms
after a gesture; 0 idle frames; `PERF_SYNTH`; prewarm/time-slice of the
LOD and cluster builds; shader caching; combined bucket-level changes
beyond what exists.

# Phase 2 fix (groups / exact markers with lanes), e2acfa4

Real streams always have lanes, so before e2acfa4 the coarse group overlay
never drew and the numbers above omit it. Now at coarse tiers occurrences use
the group overlay (lane ribbon kept); step dots and lane hit-tests are off there.

## flutter_tester debug median at 35y

| size / mode | phase 2 (50k / 200k / 1M) | fix (50k / 200k / 1M) | budget |
|---|---|---|---|
| 1600 lane-less | 11.9 / 9.0 / 8.4 ms | 12.3 / 8.3 / 8.1 ms | ≤ 40 ✓ |
| 1600 lanes | 15.2 / 16.2 / 15.3 ms | 14.6 / 15.2 / 15.8 ms (occ 0.2 → 1.4 ms) | ≤ 40 ✓ |
| 390 lane-less | 5.7 / 6.5 / 5.4 ms | 5.5 / 5.7 / 5.5 ms | ≤ 25 ✓ |
| 390 lanes | 7.4 / 7.6 / 7.5 ms | 7.2 / 7.2 / 7.1 ms | ≤ 25 ✓ |

## Playwright rAF p95 (2 runs each; frames quantise to 16.7 ms)

| profile | phase 2 | fix run 1 / run 2 |
|---|---|---|
| desk pan | 133 ms | 150 / 133 ms |
| desk zoom | 250 ms | 217 / 250 ms |
| mob6 pan | 767 ms | 617 / 683 ms |
| mob6 zoom | 550 ms | 650 / 650 ms (paint p95 137 → 149 / 216 ms) |
| mob4 pan | 583 ms | 417 / 417 ms |
| mob4 zoom | 383 ms | 367 / 350 ms |

mob6 zoom is ~100 ms worse in both runs: the glyphs, badges and coarse labels
it now draws (previously skipped with lanes). Everything else is level or better.
