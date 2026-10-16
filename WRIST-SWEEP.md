# Full-scene wrist sweep — 2026-10-16

The measurement now follows a marker inside PetPlay's ordinary wrist mount, with the normal
scene/IR producer, grip offsets, UI and renderer running. It measures uneven motion with fresh
frame IDs; duplicate detection is only supplementary. This implements the user's proposed
constant-rate controller sweep and paired panorama/projection control.

## Motion and scene instrumentation

`SETCONTROLLERMOTION` accepts `mode: "sweep"` in addition to stationary/sine. Position is analytic
in CLOCK_MONOTONIC time, with analytic velocity/acceleration. Each half-cycle travels between
−amplitude and +amplitude, using cosine velocity ramps over its first/last 10% and constant
velocity through the middle 80%. At 0.35 Hz and ±0.12 m the plateau speed is **0.18667 m/s**.
Reversal position and velocity are continuous. Yaw amplitude is zero in these measurements;
head pose stays fixed. The right controller is a quarter-cycle ahead of the left as in the
existing sine control. Finite-difference/periodicity/reversal tests exercise the native model.

Launch normal PetPlay with `--webxr-decoupled-renderer --wrist-motion-probe`. The latter adds a
magenta 100 mm square in the wrist's local coordinates, transformed by its ordinary mount,
scale, saved offset and fresh hand/grip anchor. At the default 0.235 wrist scale its side is
23.5 mm. It is not pickable and draws over UI for detection. Without the flag no marker exists.
It is a mesh sibling of the UI, not a replacement for the panel or a synthetic raw-controller
scene. It therefore measures the wrist mount's motion, **not separate text-cache/glyph motion**.

The renderer's opt-in `SETWRISTMOTIONPROBE true` appends the head-fixed redundant generation
strip from FRAME-IDENTITY.md to the normal scene. It preserves ordinary instances/UI/cameras
and restores the inbox arrays after drawing. Diagnostic asset/node IDs occupy a checked private
range. Activation occurs at a scene boundary and replays retained asset metadata once; later
asset deltas retain marker identity. `GETWRISTMOTIONPROBE` returns bounded per-render records:

- Generation, successful publication, sampled/publication monotonic times and prediction.
- Vsync counter/phase observations, render boundaries and texture identities.
- Wrist marker's resolved world center/corners, local anchor transform, and projected polygons
  for both captured eyes; head pose and source/capture optics are retained separately.

The Vulkan worker adds magenta count/first moments in the lower third of the 960² overlay images.
That ROI contains this fixed-head wrist setup while excluding the central desktop overlay and
upper ID strip. An absent marker invalidates the run. Changing head/mount placement may require
a new ROI control; do not interpret clipped/missing pixels as phase noise. The worker also logs
the first ID cell's X, so stereo grouping does not depend on the moving wrist's centroid.

## Perspective and panorama geometry

Keep the ordinary perspective headset and presentation paths. Orthographic rendering would
change the system being investigated. At fixed depth, a point's projected X is linear in world
X, but this wrist marker is tilted: its corners have different depths. The reference uses the
**area centroid of its projected quad**, not just the projection of its 3D center.

Source rendering and captured-eye optics are also distinct. In this full scene the source
projection's X scale was about 0.715, while the synthetic HMD's was 1. Panorama's combine
resamples the source into angular coordinates and the compositor projects that panorama.
Projection overlays likewise declare their source frustum to the compositor. Predicting final
capture pixels directly with the source matrix produced a large, position-dependent mismatch.
That initial geometry run was rejected. The corrected reference uses runtime headset optics
and preserves the source matrix separately; accepted image-centroid differences are subpixel.
No production optical conversion or projection matrix was changed to achieve this.

The rate analyzer constructs a constant-speed world reference per leg, projects the actual
quad at that reference, and compares it with observed pixels. This retains perspective shape
changes rather than flattening the camera to orthographic. Fixed offset and rate are fitted
per leg; a constant lag is not counted as shaking. It separately reports:

1. Captured centroid minus the geometry actually rendered for that decoded ID: spatial/
   resampling error and any content mismatch.
2. Rendered world position minus its constant-speed leg: irregularity already present in
   the rendered pose sequence.
3. Captured motion minus the projected constant-speed reference: apparent image-motion error.

Apparent timing residual divides pixel error by projected speed. It **includes spatial
quantization/resampling** and is not a physical latency measurement. The reference is a synthetic
75 Hz captured-frame ordinal, not CPU GPU-copy submission time. Recorded copy cadence must
support that continuous grid; large cadence gaps reject the run. These captures had post-warmup
copy intervals between roughly 12.7 and 13.95 ms, with medians near 13.33 ms.

The first 30 stereo pairs are warmup. Only plateau samples with an extra 50 ms guard on each
side are fitted; turnarounds are excluded. Both sweep directions must be represented.

## Same-session comparison under VRChat

The capture layer now accepts subsequent labelled stream requests **after every previous slot
has drained**. It reuses the eight staging slots/worker and requires the same queue family;
it never overwrites an output file. Thus panorama/projection and desktop visibility can be
compared in one runtime/VRChat home session instead of restarting the game between phases.

Normal PetPlay ran at its default 3560² source-eye renderer setting, with real desktop capture.
A temporary 1.1 m desktop overlay, 1.5 m ahead, used the first half of the 3840×1080 desktop.
The runner toggled that display host's visibility and switched the ordinary render owner through
`webxr.SETPRESENTMODE`, restoring previous mode/visibility and controller motion after each run.
It did not launch a second diagnostic renderer or replace the normal UI scene.

VRChat's log confirmed VR initialization on the synthetic HMD and home-world room load. A public
compositor snapshot identified scene PID **180844**, matching VRChat.exe, with scene GPU time
**3.121 ms**. That is one snapshot, not a percentile. The synthetic scene app's eye images were
only 512²; this is not the user's real HMD workload. Driver-direct mode disables Linux async
reprojection. Scene and overlay remain separate driver layers; only the overlay layer is read.

Each accepted condition captured **900 images / 450 stereo pairs**, with every ID decoded,
matching successful wrist-renderer publication records, no readback drops and a present marker.

| Condition, VRChat home | Maximum per-leg p95 motion residual, L / R | Maximum per-leg p95 apparent timing residual, L / R |
| --- | --- | --- |
| Panorama, desktop hidden | 0.209 / 0.163 px | 1.13 / 0.88 ms |
| Panorama, desktop visible | 0.197 / 0.222 px | 1.07 / 1.20 ms |
| Projection, desktop hidden (retry) | 0.227 / 0.201 px | 1.23 / 1.09 ms |
| Projection, desktop visible | 0.194 / 0.159 px | 1.05 / 0.86 ms |

These are the **largest leg-specific p95s**, not pooled p95s or between-run confidence bounds.
Rendered-world rate residual p95s were below 0.002 mm in this analytic synthetic control. That
number is not physical controller accuracy. Projection/desktop-visible had one repeated ID
per eye in its full 450-pair record; the other accepted conditions had none. Repeats outside
accepted plateau samples do not explain the small plateau residuals.

There is no substantial desktop-on penalty or panorama-specific high-frequency shake in these
short controls. This does not invalidate the user's observation. It narrows what this fixed-head,
precisely scripted driver and reduced VRChat scene workload currently reproduces.

### Exclusions and validation

- Initial no-VRChat baseline used source-camera optics for expected capture pixels. Its
  geometry/phase analysis is rejected; raw data is retained, not silently recalibrated.
- The first corrected activation after a renderer restart raced an already-selected asset-delta
  frame and found no marker metadata. The probe now activates/replays at the frame boundary;
  that failed attempt did not generate an accepted stream.
- First projection/desktop-hidden run dropped two readback samples (898 copied / 2 dropped).
  It is rejected. A fresh labelled retry captured 900 / 0 and supplied the table's result.
- An independent analyzer fixture gives every frame a unique ID and an alternating **±3 ms
  pose-time error**. The rate analysis detects approximately 3 ms residual while geometry for
  each rendered ID remains correct. The zero-jitter fixture stays clean. This specifically
  verifies sensitivity to rapid shaking that does not involve duplicated frames.
- Focused tests also cover mount-chain resolution, projected-quad versus projected-center
  geometry, ID strip attachment/restoration and the native magenta/ROI detector.

## Reproduction and evidence

Build the driver/layer first with SteamVR off:

```sh
zig build capture-layer test install -Doptimize=ReleaseSafe
```

From PetPlay, use the scoped lab with enough time for game startup, and the guarded keepalive:

```sh
python3 utils/petplay-ovrdriver-lab.py run --driver-direct --direct-server --x11-compositor --capture-layer --seconds 300
deno run -A utils/petplay-ovrdriver-lab-probe.ts --hold-open=270
# Start normal PetPlay with desktop DISPLAY environment and the opt-in marker:
deno task server -- --webxr-decoupled-renderer --wrist-motion-probe
# Launch VRChat, verify VR initialization/home load and visible desktop, then:
deno run -A --no-check utils/petplay-wrist-sweep.ts /absolute/capture/images desktop-visible panorama home > logs/wrist-result.json
python3 utils/petplay-wrist-sweep-analyze.py logs/wrist-result.json /absolute/capture/images
# Repeat using desktop-hidden and projection. Use a fresh final suffix for retries.
PYTHONDONTWRITEBYTECODE=1 python3 utils/petplay-wrist-sweep-analyze-test.py
```

The capture directory comes from `logs/ovrdriver-lab/latest-native-capture.json`. The desktop
must have an actual virtual overlay handle/texture; capture activity alone does not prove it
is shown. Keep the screen away from the lower-third marker ROI to avoid occlusion. Labels are
bounded; existing files are never replaced. The runner requires the normal independent render
owner and restores its presentation mode, display visibility and previous driver motion.

Accepted ignored local evidence lives under `logs/ovrdriver-lab/`:

- `native-capture-2c7vc903/images/ws-pano-off-home.*`, `ws-pano-on-home.*`,
  `ws-proj-on-home.*`, `ws-proj-off-retry.*`.
- `ws-home-panorama-desktop-hidden.json`, `ws-home-panorama-desktop-visible.json`,
  `ws-home-projection-desktop-visible.json`, `ws-home-projection-desktop-hidden-retry.json`,
  with corresponding `-analysis.json` files.
- `wrist-sweep-matrix-summary.json`, `wrist-home-timing.ndjson`, `wrist-app.log` and
  `wrist-keepalive.log`. Failed baseline/activation/drop records remain alongside them.

All apps were stopped afterward; exact original SteamVR settings/driver registrations were
restored. The PetPlay host exited with a closed-WebSocket/IPC dispatch error during shutdown,
after the accepted captures; its log is retained. This was not a steady-state capture failure. No production pacing defaults, optical calibration, smoothing or saved layout were
changed. Raw captures remain local and ignored; no measurement data was uploaded.

## What remains

The next useful challenge is a head/controller relative-motion test and a more representative
scene render load, while keeping this full-wrist tag and image analysis. The real controller
has its own pose sampling/prediction noise; the current driver supplies exact analytic velocity
and acceleration. The real HMD also uses a different async/composition path. Finally, the marker
is a mesh attached to the wrist mount: panel/text-only jitter needs an additional UI/text
measurement, not a claim based on this marker alone. Confirm the eventual mechanism under the
user's actual HMD + VRChat home + visible desktop condition before choosing a production fix.

Validation: native driver/ABI/transport tests and five capture-layer tests passed; 12 focused
TypeScript runtime tests and the independent phase-injection fixture passed. The renderer
typecheck still reports 188 imported dependency diagnostics, with none pointing to the modified
render-owner or wrist-probe module. Probe CLI typechecks and both git whitespace checks passed.
