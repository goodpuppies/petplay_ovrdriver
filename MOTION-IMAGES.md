# Automated controller image measurements — 2026-10-16

The synthetic driver can now distinguish smooth native controller-following motion from
intentionally under-updated overlay motion in the compositor's output pixels. This validates
the measurement baseline; PetPlay's panorama/projection comparison remains to be run.

## Capture mechanism

The optional pure Zig Vulkan layer has two separate diagnostics. `request` still produces
blocking static PPM controls. A private `stream` request containing an alphanumeric label
starts a bounded motion experiment (later labelled experiments can reuse the ring once it drains):

- Preallocate eight persistently mapped, host-visible, coherent **CPU-cached** staging slots
  (about 28 MiB at this profile's two 960×960 eye images).
- For 450 eligible producer submissions, queue copies of that submission's eye images on the
  same queue, restoring observed layouts. Each slot has its own command pool and fence.
- Later submissions poll `vkGetFenceStatus`; they never wait for a readback fence. Only after
  completion does an atomic state transition expose the mapped pixels to a CPU worker.
- The worker measures dominant-red pixel count and first moments, writes compact NDJSON,
  then releases the slot. Busy slots cause counted drops; they are never overwritten or waited
  on. The completion file is written after all accepted slots have drained.
- Teardown joins the CPU worker and may wait for pending fences. A timeout retains pending
  GPU resources until device destruction. Allocation failure disables capture conservatively.

The worker makes no Vulkan calls. Queue/fence/command-pool operations stay on the submission
thread. The ring starts with allocation/first-use overhead; analysis excludes the first 30
captured submissions. Capture-off/on cadence summaries exclude their first ten wakes.

An initial host-coherent, uncached allocation took roughly 100 ms to scan one image on this
AMD system. Bounded backpressure prevented unbounded memory use, but that run was unusable.
Requiring HOST_CACHED brought typical analysis below 0.6 ms per eye. There is deliberately no
silent fallback to uncached memory for this experiment.

The fixed synthetic head also entered SteamVR standby during early tests. The scoped launcher
now sets `power.pauseCompositorOnStandby=false` and long screen/controller timeouts, with exact
original settings restored on exit. No physical HMD is registered during these sessions.

## Probe and analysis

Build in this submodule:

```sh
zig build capture-layer test install -Doptimize=ReleaseSafe
```

From PetPlay, start the lab and immediately run the guarded probe in another terminal after
its socket appears and the compositor starts:

```sh
python3 utils/petplay-ovrdriver-lab.py run --driver-direct --direct-server --x11-compositor --capture-layer --seconds 30
# Read the images directory from logs/ovrdriver-lab/latest-native-capture.json.
deno run -A utils/petplay-ovrdriver-lab-probe.ts --motion-images --capture-dir=/absolute/images/path > logs/ovrdriver-lab/motion.ndjson
python3 utils/petplay-ovrdriver-motion-images-analyze.py logs/ovrdriver-lab/motion.ndjson /absolute/images/path
```

The probe refuses a non-synthetic HMD. It attaches a 25 mm red quad to the left controller,
commands translation-only motion (0.7 Hz, ±120 mm), measures 225 capture-off and 500 capture-on/
drain wakes, and records public zero-prediction poses with CLOCK_MONOTONIC query brackets.
It restores the previous controller motion configuration and destroys its overlay afterward.

Add `--motion-step-control` to the probe for the deliberately faulty control: an absolute
quad transform published every fifth 75 Hz wake, using the public controller pose. The native
controller itself still moves smoothly. The full-wrist follow-up now supports labelled sequential experiments in one compositor session; see WRIST-SWEEP.md.

The analyzer validates stream accounting, two eyes per submission, no drops, and marker presence.
It fits offset + sine + cosine at the commanded frequency, separately per image inode and per
stereo eye. Stereo grouping uses fitted image offsets and rejects duplicate submissions in one
eye. Fixed phase lead and gain are reported separately from residual motion error. This avoids
calling constant prediction offset jitter. Unexpected repeats require measured movement below
0.2 px while the fitted trajectory predicts more than 1.5 px movement; natural turning points
are excluded by that condition.

## Measured controls

Both completed runs captured 900 images from 450 submissions, without drops or output failures.
After excluding 30 warmup submissions, each eye contributes 420 consecutive samples.

| Measurement | Native controller-relative quad | Deliberate 15 Hz absolute-transform control |
| --- | --- | --- |
| Motion residual, p95 per eye | 0.345 / 0.368 px | 13.230 / 13.209 px |
| Motion residual, maximum | 0.414 / 0.421 px | 13.921 / 13.926 px |
| Unexpected repeated positions | 0 / 0 | 267 / 284 |
| Fitted phase lead relative to copy submission | +13.00 / +12.94 ms | −40.85 / −40.93 ms |
| Capture-off wake p95 | 13.350 ms | 13.352 ms |
| Capture-on/drain wake p95 | 13.348 ms | 13.345 ms |
| WaitFrameSync errors | 0 | 0 |

The native control's public pose residual p95 was 0.005 mm. Its CPU image-analysis p95 was
0.556 ms per eye. These runs do not show a substantial cadence disturbance from capture at
this idle workload. The intentionally choppy control demonstrates detection of large repeated
frame motion independently of the driver's smooth public poses.

Local ignored evidence under `logs/ovrdriver-lab/`:

- Smooth: `motion-images-3.ndjson`, `motion-images-3-analysis.json`,
  `native-capture-x2wdiza4/images/`.
- Choppy: `motion-images-stepped.ndjson`, `motion-images-stepped-analysis.json`,
  `native-capture-10l2iyiw/images/`. Probe command included `--motion-step-control`.
- These first completed probe logs precede the explicit `publication` metadata field; identify
  their publication mode by the recorded commands above. New runs include that field.

## Interpretation and next step

Producer-copy CPU timestamps are not display timestamps. Fence observation is usually one
submission later; the approximately 13 ms poll delay is not measured GPU execution time.
Fitted phase lead is not a motion-to-photon result or a recommended publication delay.
Subpixel residuals include rasterization/threshold quantization and timing noise.

The synthetic driver-direct backend disables Linux asynchronous reprojection. This experiment
has no VRChat workload and does not reproduce the physical HMD's scheduling environment.
It has not established a coherent pose/texture publication API or solved panorama jitter.

Next, reuse this exact trajectory and image measurement for equivalent markers rendered through
PetPlay's panorama and projection presenters, with identical scene content and fresh render poses.
Record pose sample/prediction time, texture publication and capture identity alongside the image
series. Compare residuals and repeats before varying workload or prediction. A synthetic result
then needs confirmation under the real HMD/async path and VRChat's home-world workload.

## PetPlay presenter comparison

`--render-images=projection` or `--render-images=panorama` on the guarded lab probe now launches
PetPlay's real independent render-owner actor. It creates the marker once as a raythree scene,
bypasses scene/IR delivery, and resolves its anchor from the actual synthetic left controller's
fresh predicted raw device transform. It intentionally bypasses controller-tip offsets, matching
the native relative-quad baseline. Both renderer modes use the same 25 mm red marker at the
same driver origin. The existing generated-animation probe remains available unchanged by default.

The render-owner debug option is `SETMOTIONPROBE {enabled:true,nativeController:true}`.
Native-controller probe rows now include CLOCK_MONOTONIC sample/publication timestamps and the
rendered controller X coordinate, alongside prediction, render duration, textures, and publication
phase. These timestamps are approximate observations around the existing tracking operation;
they are not its exact internal query time or a GPU completion timestamp.

Additional lab-probe options:

- `--render-pacing=vsync|presenter|frame-sync` (panorama only; default vsync).
- `--render-rotation` alternates eligible panorama output textures.
- `--render-eye-size=1024` changes source eye resolution; default 512, range 256–2048.

Each capture needs a fresh scoped lab session because the readback ring accepts one experiment
per compositor lifetime. Launch the probe with the desktop DISPLAY/XAUTHORITY environment so
raylib can create its GL context. The image analysis command is unchanged. The result includes
both the CPU renderer log and GPU-derived image moments. The standalone lab probe explicitly
exits after actors and OpenVR shut down, because the process-worker backend otherwise retains
a parent-side event source.

Initial idle-workload results at **512×512 source eyes**, 960×960 captured eyes:

| Renderer | Image residual p95, two eyes | Repeat candidates, two eyes | Fitted lead |
| --- | --- | --- | --- |
| Projection / presenter | 0.903 / 0.948 px | 3 / 0 | about −0.5 ms |
| Panorama / vsync | 1.763 / 1.569 px | 16 / 0 | about +12.9 ms |
| Panorama / presenter | 1.874 / 1.584 px | 14 / 0 | about −0.5 ms |
| Panorama / presenter / rotated output | 1.749 / 1.566 px | 14 / 0 | about −0.5 ms |

All four captured 900 images without drops or output failures. Rotation used two distinct
panorama textures versus one without rotation; its residuals stayed similar. Matching pacing
changed the constant phase by about one display period, while panorama's residuals remained
similar. These observations do not support concluding that either output reuse or the chosen
pacer alone explains this synthetic result.

**These residuals are not pure timing jitter.** Projection samples a 512² eye image; panorama
additionally resamples it into an angular texture and back into the compositor eye. A 25 mm
marker at 0.5 m covers only roughly a dozen source pixels. Thresholded centroids and repeated
positions can reflect spatial quantization and resampling. Repeat candidates are not yet proof
that the same texture/frame was consumed twice. Higher-resolution and stationary/known-position
geometry controls are needed before attributing the small difference to scheduling. The 15 Hz
positive control above remains much larger (13 px p95).

Evidence under the ignored lab directory:

- `render-projection.ndjson`, `render-projection-analysis.json`, `native-capture-379hfya3/images/`.
  The first probe saved its full result but the parent process was then killed at its harness
  timeout; the standalone-tool exit fix was applied afterward. Scoped runtime restoration passed.
- `render-panorama.ndjson`, `render-panorama-analysis.json`, `native-capture-zo3ysz2_/images/`.
- `render-panorama-presenter.ndjson`, matching analysis, `native-capture-x2b8rzx3/images/`.
- `render-panorama-presenter-rotated.ndjson`, matching analysis, `native-capture-2sexxzeh/images/`.

The last two include shared-monotonic producer timestamps. This is a controlled renderer-only
comparison, not the complete PetPlay application or the real-HMD/VRChat validation.

### Resolution control

A further panorama/vsync run changed only source eye resolution to **1024×1024** (output capture
remained 960×960). P95 image residual fell to **0.846 / 0.784 px**, maximum 1.357 / 1.248 px,
with **zero repeat candidates in either eye**. It captured all 900 images without drops. The
fitted lead stayed approximately +12.8 ms and producer publication cadence remained near 75 Hz.
Evidence: `render-panorama-vsync-1024.ndjson`, matching analysis, and
`native-capture-buau5lp8/images/` under the local ignored lab directory.

This is evidence that source resolution/resampling accounts for a substantial part of the
small baseline panorama residual. It is not evidence that the real-HMD jitter is solved by
resolution. No production presenter calibration was changed. Before interpreting smaller
centroid differences as missed compositor latches, add an independently decodable frame ID
that survives the panorama resampling, then correlate captured identity with the existing
producer publication/timing log. Continue to keep spatial errors, repeated frame consumption,
and variable prediction horizons separate.

### Follow-up: decoded frame identity

The native-controller probe now includes a head-fixed generation strip, with validity checks
and correlation against the publication log. See [FRAME-IDENTITY.md](FRAME-IDENTITY.md).
It supersedes centroid repeat candidates as the test for repeated rendered content. The first
panorama/vsync ID run had no repeated or skipped IDs; projection showed occasional adjacent-eye
generation mismatches. Neither result yet explains the physical-HMD bug.
