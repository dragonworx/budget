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
