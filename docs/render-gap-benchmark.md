# Render optimisation — issue #6

## Behaviour

The OCF supplies the output timeline, dimensions, frame rate and blank timecode. Grades supply finished picture.

- One full-length ProRes 4444 MOV grade is copied unchanged, including its own audio and metadata. Source and copy SHA-256 checksums are compared before publishing the output.
- Multiple grades covering every frame are assembled without a blank rush.
- Partial coverage reuses a structurally valid full blank rush when one already exists. Otherwise, only missing blank ranges are generated.
- Blank gaps use the same burn-in renderer as full blanks, starting at their actual OCF-relative timecode.
- Assembly copies compressed ProRes video packets. It remains video-only, as in the previous compositor. It takes video colour/alpha signalling from the grade, and timeline timecode from the OCF.
- Existing Render Modified filtering remains responsible for skipping current outputs. Explicit Render All continues to render the requested jobs.

All output is prepared in a temporary file next to the destination and validated before replacement. Missing/changed sources, cancellation and source/destination collisions cannot publish a successful output. Non-default output profiles retain the previous pipeline.

## Range cache

`BlankRushes/GapCache-v1/<identity>/ranges.json` records completed ranges and fingerprints. Identity includes canonical OCF path, source fingerprint, timeline, dimensions, frame rate, timecode, clip name and a burn-in version. Different same-named sources cannot share a range cache accidentally. Grade changes do not invalidate compatible blanks.

A requested gap can reuse a subset of an existing range or several cached ranges. Only uncovered portions are generated. Changed/missing cached files are rejected by fingerprint. Generated files are validated before their manifest is saved atomically. Cancelled temporary files are removed. Completed caches remain reusable; no automatic pruning or new cache-management UI is introduced here.

Legacy full blank rushes retain their normal filename. They must match the OCF's complete frame count, resolution, rational FPS, timecode and ProRes 4444 profile before reuse. Unusable legacy files are left untouched; the new path creates its own gap cache instead.

## Reproduction

Use an isolated local media directory. `OCF/` and `Grades/` contain independent copies, and `manifest.json` records source paths, copy paths, metadata, probes and checksums. Do not run preparation against production media folders.

```sh
python3 scripts/prepare-render-benchmark.py "$BENCHMARK_ROOT"
SOURCEPRINT_BENCHMARK_ROOT="$BENCHMARK_ROOT" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg@7/lib/pkgconfig \
swift test --package-path SourcePrintCore --filter RenderBenchmarkTests
```

The opt-in test invokes the old and new RenderService pipelines against identical fixtures. The default is three repetitions. `SOURCEPRINT_BENCHMARK_REPEATS` and `SOURCEPRINT_BENCHMARK_LIMIT` allow focused runs. Results are written to `results.json`; application caches are retained under uniquely named `Runs-*` folders, but rendered comparison movies are removed after verification to limit disk usage.

## Method and limitations

- Apple M4 Pro, 48 GiB memory, local Desktop/APFS storage.
- Actual 4096×2160 and 3840×2160 Birkenstock media copies, 25 fps; grades are ProRes 4444. OCFs are ProRes LT/Standard.
- Coverage fixtures use a 235-frame 4096×2160 OCF. Derived grades are remuxed copies of the test grade, with repetition only to construct the full-length fixture. They are benchmark material, not editorial outputs.
- Coverage: 10%, 49%, 51%, 90%, 99%, 100%; full coverage across multiple grades; a one-frame gap; alternating short grade/blank ranges; three real OCF/grade pairs.
- Revision sequence: initial grade, shorter grade, longer grade, shifted grade, unchanged rerender. Both pipelines retain their own caches throughout that sequence.
- Wall time includes service validation, copy/generation/assembly and output verification. External benchmark probing and picture comparisons are outside the timed region.
- All runs verify output dimensions, rational FPS, timecode, frame count and every compressed grade-frame hash against the previous pipeline. On the first repetition, any differing blank packets are decoded and every blank frame is compared via framemd5. Later repetitions repeat structural and grade-packet checks; `pictureMatchesBaseline` is omitted when that repetition did not repeat blank decoding.
- “Cold” means no application blank cache; filesystem caches are not flushed. Legacy runs first, so these are workflow measurements, not isolated disk-throughput measurements. Timing differences below a few tenths of a second should not be overinterpreted.
- This first benchmark does not measure network-share performance, long-form clips, per-render peak memory, energy or UI latency. Fractional FPS planning and a drop-frame gap boundary are covered separately by tests; the timed media is 25 fps.

## Results

| Scenario | Full blank median (range), s | Hybrid median (range), s | Hybrid blank frames generated |
| --- | ---: | ---: | ---: |
| coverage-10 | 1.31 (1.30–1.41) | 1.38 (1.37–1.39) | 211 / 235 |
| coverage-49 | 1.56 (1.55–1.58) | 1.15 (1.12–1.30) | 120 / 235 |
| coverage-51 | 1.56 (1.56–1.76) | 1.12 (1.11–1.17) | 115 / 235 |
| coverage-90 | 1.85 (1.84–1.86) | 0.95 (0.94–1.14) | 23 / 235 |
| coverage-99 | 1.96 (1.94–2.17) | 1.00 (0.87–1.07) | 2 / 235 |
| coverage-100 | 1.92 (1.88–1.98) | 1.28 (1.27–1.28) | 0 / 235 |
| full-multiple | 2.04 (1.97–2.07) | 0.92 (0.88–1.07) | 0 / 235 |
| one-frame-gap | 1.95 (1.90–1.96) | 1.03 (0.94–1.46) | 1 / 235 |
| Fragmented (120/235 grade frames, 51%) | 3.00 (2.99–3.02) | 3.59 (3.57–3.66) | 115 / 235 |
| real-A004C0098 | 1.60 (1.59–1.64) | 1.29 (1.26–1.35) | 158 / 257 |
| real-A004C0100 | 1.87 (1.85–1.87) | 1.03 (0.88–1.07) | 16 / 235 |
| real-DSCF0781 | 1.44 (1.44–1.47) | 1.02 (1.01–1.10) | 108 / 225 |

All 102 timed renders passed their applicable checks (12 cold scenarios plus 5 revision steps, two pipelines, three repetitions). The first repetition includes decoded comparisons for all differing blank frames; grade packets were checked on every render. Full-copy output also passed the service's whole-file SHA-256 comparison.

Across five renders in the revision sequence:

| Strategy | Median cumulative time | Range | Total blank frames generated | Final cache size |
| --- | ---: | ---: | ---: | ---: |
| Full blank | 4.88 s | 4.80–4.88 s | 235 | 52.4 MB |
| Hybrid | 4.14 s | 4.00–4.86 s | 85 | 19.0 MB |

The hybrid cache generated **45, 40, 0, 0, 0** additional blank frames over the five steps. In particular, shortening the grade required only the 40 newly exposed frames; later changes reused the existing cache. The full-blank path generated 235 frames upfront and none thereafter.

### Recommendation

Keep the hybrid behaviour and reuse existing full blanks. Most tested cold scenarios improved, especially high coverage and grade-only assembly. The fragmented case still costs more because it opens/generates many small ranges; no coverage-only threshold is justified. A full blank remains a useful upfront choice for highly fragmented/revision-heavy work, and an explicit preparation action remains a possible follow-up (not added to the UI here). Do not add an automatic fragmentation threshold from these short-clip measurements alone; benchmark longer timelines before doing so.

These results are exploratory local-SSD measurements, not a promise of the same percentage gains on network storage. No production project or source media was modified.

### App integration verification

The final build passed 83 targeted tests (81 render/linking/cache tests and two filesystem fingerprint tests). A throwaway four-job 4K batch completed in the macOS app, including the unchanged full-length grade copy, with all four attempts recorded as completed.

During UI verification, macOS blocked reads of the Desktop fixtures (first at provenance attributes, then at video open). The same footage rendered successfully from isolated temporary copies at `/tmp/SourcePrint-Gap-Demo`; the benchmark inputs and results remain on Desktop. This Desktop-access issue is separate from the renderer and remains an environment limitation. Fingerprinting now reads size, modification time and inode directly with `stat`, avoiding unnecessary extended-attribute reads. The 102 timed measurements above precede this filesystem-only adjustment; safety tests and the app batch were rerun after it.

## Unchanged warm rerenders — 5 November 2026

Each of the same 12 scenarios received one cache-populating render per pipeline, followed by five unchanged rerenders per pipeline. Both caches persisted; outputs were removed between runs so this measures explicitly requested output regeneration, not Render Modified skipping an up-to-date output. Execution order alternated (hybrid first on odd repetitions). The filesystem cache was not flushed.

**120 measured warm renders plus 24 setup renders passed. Every warm render added zero blank frames and left cache frame counts, byte sizes and file counts unchanged.** Output timeline/format and graded packet hashes were checked on every render; differing blank pixels were compared during setup. Timing covers the render service including its validation and output writing, excluding the harness checks.

| Scenario | Full blank median (range), s | Gap/copy median (range), s | Gap/copy time change |
| --- | ---: | ---: | ---: |
| coverage-10 | 0.307 (0.301–0.310) | 0.324 (0.319–0.332) | +5.5% |
| coverage-49 | 0.404 (0.387–0.414) | 0.412 (0.410–0.428) | +2.1% |
| coverage-51 | 0.423 (0.396–0.476) | 0.419 (0.418–0.457) | -0.9% |
| coverage-90 | 0.529 (0.511–0.586) | 0.581 (0.532–0.624) | +9.8% |
| coverage-99 | 0.553 (0.536–0.605) | 0.571 (0.556–0.654) | +3.2% |
| 100% — unchanged file copy + SHA-256 | 0.544 (0.535–0.622) | 1.189 (1.187–1.205) | +118.4% |
| 100% — multiple grades | 0.674 (0.660–0.724) | 0.786 (0.779–0.841) | +16.7% |
| one-frame-gap | 0.669 (0.658–0.729) | 0.791 (0.777–0.833) | +18.2% |
| Fragmented (~51% actual coverage) | 1.883 (1.865–1.934) | 2.008 (1.979–2.351) | +6.7% |
| real-A004C0098 | 0.413 (0.405–0.420) | 0.439 (0.435–0.451) | +6.5% |
| real-A004C0100 | 0.569 (0.564–0.694) | 0.689 (0.674–0.818) | +21.1% |
| real-DSCF0781 | 0.397 (0.391–0.455) | 0.412 (0.407–0.437) | +3.8% |

Positive percentages mean slower. These are short local 4K clips; small absolute differences should not be generalised to long timelines or network storage.

**Conclusion:** the current gap pipeline is not generally faster for unchanged warm rerenders. Most cases are close or modestly slower; fragmentation remains about 7% slower (2.008 s versus 1.883 s), compared with about 20% slower in the earlier cold benchmark. The benefit is reduced initial blank generation and reuse when grade lengths change, not faster steady-state assembly. The 100% single-grade shortcut is a distinct workload: it preserves the complete file and verifies source/copy SHA-256, while the legacy path remuxes video packets. It costs 1.189 s versus 0.544 s warm in this fixture.

This comparison measures the complete current implementations. The new path also performs extra source/cache/output validation; it does not isolate the cost of opening fragmented files alone. Existing full blanks remain reusable. Further work should profile warm validation/assembly and the verified-copy path before choosing an automatic full-blank threshold.

Reproduce independently without overwriting the original cold results:

```sh
SOURCEPRINT_BENCHMARK_ROOT="$BENCHMARK_ROOT" \
SOURCEPRINT_BENCHMARK_REPEATS=5 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg@7/lib/pkgconfig \
swift test --package-path SourcePrintCore --filter RenderBenchmarkTests.testLocal4KWarmBenchmark
```

Raw results: `warm-results.json` under the local benchmark root; disposable caches: `WarmRuns-*`. No production media or projects were changed.

## Longer 4K generation and bounded concurrency (2026-11-05)

Three cold repetitions per configuration, 4096×2160 ProRes 4444 at 25 fps, 1- and 5-minute timelines, 50%/90% grade coverage, 2/30 gaps, and 1/2/4 generation workers. Worker order reverses between passes. These tests exercise the real blank generator and compressed-packet assembler. Grade packets are synthetic stand-ins sourced from the full blank master: useful for isolating generation, but not representative of real-picture compressed file sizes or network I/O. Earlier real-camera short-clip benchmarks remain the end-to-end comparison.

Both benchmark tests passed: 246 long-timeline phase measurements and 18 four-job batch measurements. Frame counts, FPS, timecode and graded packet hashes were checked. Selected first/last gap boundary frames were decoded and compared to the full blank in the first pass (not an exhaustive decoded comparison).

### Cold generation medians (seconds)

| Timeline | Grade coverage | Gaps | 1 worker | 2 workers | 4 workers |
| --- | ---: | ---: | ---: | ---: | ---: |
| 60s | Full blank baseline | 1 | 6.04 | — | — |
| 60s | 50% | 2 | 3.10 | 2.74 | 2.73 |
| 60s | 50% | 30 | 4.57 | 3.35 | 2.96 |
| 60s | 90% | 2 | 0.71 | 0.60 | 0.60 |
| 60s | 90% | 30 | 2.31 | 1.15 | 0.79 |
| 300s | Full blank baseline | 1 | 32.84 | — | — |
| 300s | 50% | 2 | 16.36 | 15.18 | 15.06 |
| 300s | 50% | 30 | 17.23 | 15.20 | 15.00 |
| 300s | 90% | 2 | 3.19 | 2.88 | 2.90 |
| 300s | 90% | 30 | 4.57 | 3.39 | 3.10 |

Four-worker configurations with only two gaps can run at most two jobs concurrently. These are generation-only timings, not total render times.

### Comparable four-job batch

Four 60-second timelines, 50% grade coverage, 30 gaps each. The worker limit applies globally. Full-blank strategy generates four whole files; gap strategy generates 120 ranges.

| Strategy | 1 worker | 2 workers | 4 workers |
| --- | ---: | ---: | ---: |
| full | 24.65s | 22.94s | 23.66s |
| gaps | 18.22s | 13.92s | 12.42s |

### Overheads, safety and interpretation

- Generated-file validation was about 0.08s for two gaps versus 1.15s for 30. File count has a measurable fixed cost.
- Synthetic assembly medians for two/30 gaps were 0.11/0.37s at 60s and 0.45/1.61s at 300s. Full-master assembly was 0.13/0.62s and 0.45/2.83s. These isolated measurements exclude the production service's other checks and do not override the earlier warm end-to-end results.
- Peak sampled test-process RSS was 409 MB for long cases and 418 MB for batches. This excludes codec-service/GPU memory. Largest main-actor scheduling probe delay was 7.85ms; this is a responsiveness proxy, not a measurement of actual app scrolling or CPU utilisation.
- The first parallel pilot crashed in FFmpeg drawtext/FreeType font access. A shared lock now protects filter construction, frame retrieval and destruction, with explicit graph lifetime ownership. VideoToolbox encoding and file writing may still overlap. The full repeated suite passed after that fix.
- Parallel scheduling is **benchmark-only**. Production range generation remains serial; cache publication and cancellation have not been integrated with a parallel scheduler.

**Decision:** gap generation has substantial merit on longer timelines, even at 50% coverage. Two workers are a sensible next integration target; four mostly benefit many tiny gaps and offer little for long gaps. Keep existing full-blank reuse, avoid a percentage-only fallback threshold, and preserve warm-render findings: unchanged renders are not generally faster. Before enabling parallel app generation, integrate a global worker limit, cancellation and serialized cache publication, then test the bundled static FFmpeg build under concurrent app rendering.

All 83 targeted safety/model/queue/refresh tests passed after the concurrency guard. A pre-existing queue test's fixed 100ms wait raced with processing; it now asserts queue state at the first-item start event.

Reproduce:

```sh
SOURCEPRINT_BENCHMARK_ROOT="$BENCHMARK_ROOT" \
SOURCEPRINT_BENCHMARK_REPEATS=3 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg@7/lib/pkgconfig \
swift test --package-path SourcePrintCore --filter LongRenderBenchmarkTests
```

Raw local results: `long-results.json` and `batch-results.json`. Long fixtures and rendered outputs are disposable synthetic media.

App smoke check: the rebuilt, code-signature-verified bundled app completed four synthetic 5-minute 4K jobs (21.9–24.0s each, serial production scheduler). Scrolling to the bottom/top and switching Media/Linking worked during rendering. All four outputs were independently probed: 7,500 frames, 25 fps, ProRes 4444, start TC 01:00:00:00. This checks UI functionality, not smoothness quantitatively or parallel production scheduling. The throwaway project remains open for manual testing.

## App integration: two concurrent gap workers

The app now uses two concurrent generation workers, shared across render services in the process. This supersedes the earlier benchmark-only status. Independent missing ranges are planned together, generated and validated in a bounded task group, then published serially through one atomic manifest update. Requests for the same cache identity are serialized and reload the manifest after waiting. Existing full blanks and cached subranges remain reusable.

Cancellation propagates to both workers, waits for their cleanup and removes staging files. Previously published cache entries and rendered outputs remain intact. Frame progress aggregates both workers and ignores late updates after generation finishes. Stop now discards pending jobs and keeps the queue busy until cancellation has unwound, preventing duplicate jobs on Render All and overlapping restarts.

87 targeted tests pass, including global worker permits, cancelled waiters, same-cache exclusion, concurrent cache reuse, cancellation preserving an existing manifest, cleanup and retry. Production uses the existing font/filter serialization guard while allowing encoding and file writes to overlap.

Bundled-app verification passed: cancelled during parallel generation, confirmed no partial outputs/manifests/staging files, then restarted exactly four jobs. All four 5-minute synthetic 4K jobs completed (21.0–22.4s each). Scrolling and switching tabs worked during generation. Each output independently verified as 7,500 frames, 4096×2160 ProRes 4444 at 25 fps, TC 01:00:00:00; all 3,750 graded picture packet hashes match the grade source. Each cache manifest contains exactly the two required 1,875-frame gaps. The throwaway Parallel Gap Render Demo is open in the rebuilt app. These are smoke-check timings, not a repeated controlled comparison.
## Final stress validation — 5 November 2026

The integrated two-worker renderer passed the following local-SSD stress checks using disposable outputs/caches and copied or synthetic 4K media. Original project/media were untouched.

- **198 end-to-end render measurements:** 102 cold/revision renders plus 24 warmup and 72 unchanged warm renders, comparing the full-blank and gap/copy strategies. All passed. Every unchanged warm render added zero blank frames and left cache frame counts, file counts and byte sizes unchanged.
- Each render checked OCF frame count, FPS, resolution and timecode. Graded packet SHA-256 values were compared directly with the original grade source slices, as well as with the legacy output. First-pass differing blank frames were decoded and compared with the full-blank reference. Full-grade copies also underwent whole-file SHA-256 verification.
- **Six 4K frame-rate cases:** 24, 25, 50, 24000/1001, 30000/1001 drop-frame and 60000/1001 drop-frame. Cold/warm renders included one-frame gaps at the beginning, middle and end, overlapping VFX, and drop-frame minute boundaries. Frame counts, start/end TC, rate, dimensions, source grade packets and unchanged warm manifests passed.
- **Five-minute production-service case:** 7,500 frames, 30 gaps, 50% grade coverage. Cold, warm and revised renders passed. Cache stayed at 3,750 frames/30 files on the unchanged repeat; removing one grade added exactly its 125 newly exposed frames (3,875 frames/31 files).
- **24 simultaneous requests across three caches:** exactly 18 blank frames generated and 126 reused, with six unique valid files per cache and no staging leftovers.
- **12 parallel cancellation/retry cycles:** cancelled work left no partial media or manifest; every immediate retry succeeded. Existing-cache preservation, cancelled permit waiters and full-copy cancellation/source protection also passed their separate tests.
- Mutating a source during rendering and deleting a grade both failed safely, preserving the previous successful output.

Across the regression suite, render matrix and new stress suite: **199 tests passed, three external-footage tests skipped, zero remaining failures** (202 tests total across three runs). The initial broad run exposed stale test fixtures: missing rational FPS in mock segments, raw URL equality across macOS /var and /private/var aliases, and unavailable Theory Holiday footage on EVO-POST. Mock metadata/path assertions were corrected; the three external-fixture tests now explicitly skip when that footage is unavailable. No production renderer change was needed from this stress run.

These XCTest runs use Homebrew FFmpeg 7. The bundled/static-FFmpeg app was separately verified in the preceding four-job cancellation/restart smoke test. Network-storage stress and exhaustive testing of every camera format remain outside this local matrix; this is not an all-input guarantee.

Local raw measurements: /private/tmp/SourcePrint-Stress-6rftjo6o/results.json and warm-results.json. Logs: /tmp/sourceprint-stress-suite.log (initial broad run), /tmp/sourceprint-edge-stress.log and /tmp/sourceprint-regression-suite.log (clean rerun). Completed disposable caches/outputs were cleaned to limit disk usage.

Reproduce the render matrix with SOURCEPRINT_BENCHMARK_ROOT pointing at prepared fixtures, SOURCEPRINT_BENCHMARK_REPEATS=3 and SOURCEPRINT_STRESS_CLEANUP=1, filtering RenderBenchmarkTests. Filter RenderStressTests for the new edge cases; its long test additionally requires long-ocf.mov (the synthetic 7,500-frame 4K fixture) under the benchmark root.

### 20,000-frame / 50-grade edit stress demo (6 November 2026)

Retained disposable Desktop demo, 3840×2160 at 25 fps. Synthetic H.264 OCF provides the timeline; ProRes 4444 solid-colour grades provide finished picture. Baseline has 50 × 200-frame grades spaced every 400 frames, starting at frame 100. Revision shortens ten grades by 50 frames, splits ten into two 90-frame grades with a 20-frame hole, and merges five pairs into 600-frame grades spanning their old gaps. Final count is 55 grades.

| Pass | Render time | Newly generated blank frames | Required blank frames | Cache files |
|---|---:|---:|---:|---:|
| Baseline cold | 42.8s | 10,000 | 10,000 | 51 |
| Baseline unchanged | 6.3s | 0 | 10,000 | 51 |
| Shorten / split / merge | 13.4s | 700 | 9,700 | 71 |
| Revised unchanged | 3.2s | 0 | 9,700 | 71 |

All four passes verified 20,000 compressed video packets against their intended grade or cached-blank source, plus output frame count, resolution, FPS and start/end timecode. Existing cache file fingerprints remained unchanged. The revised UI reports **66 blank segments · 9,700 frames**: five old cached files are no longer needed because merged grades cover them. They remain cached for later revisions. No renderer changes were needed. These are single local synthetic runs, not averaged real-footage performance measurements; render timings exclude the subsequent packet-hash verification.

Opt-in test: `HeavyGapDemoTests.testTwentyThousandFramesFiftyGradesAndEdits`. Prepare a fresh disposable directory with `Stress20K.mov` (20,000 frames, 3840×2160, 25 fps, TC 01:00:00:00) and `Fixtures/grade-seed.mov` (one 3840×2160 ProRes 4444 frame at 25 fps), then run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg@7/lib/pkgconfig \
SOURCEPRINT_HEAVY_DEMO="$DEMO_ROOT" \
swift test --package-path SourcePrintCore --filter HeavyGapDemoTests
```

The test retains generated grades, cache, final output, baseline/revised parent metadata and `results.json` for app inspection. It skips directories already containing generated grades or cache to preserve previous demos and the meaning of cold-run assertions.
