# Measuring consumed frame identity — 2026-10-16

Centroid motion alone cannot distinguish a repeated frame from spatial quantization. The
renderer diagnostic now embeds a separately decodable generation strip in both eyes. This
builds on [MOTION-IMAGES.md](MOTION-IMAGES.md); all captures remain producer-side GPU copies,
not physical display scans or motion-to-photon measurements.

## Encoding and validity

The native-controller probe renders forty head-fixed cells above the moving red marker.
Green is zero and blue is one. In left-to-right order:

- Four fixed opening bits, `0010`.
- Sixteen generation bits, least significant bit first.
- The sixteen complementary generation bits.
- Four fixed ending bits, `1101`.

Cell centers are 35 mm apart, width 25 mm and height 35 mm, at head-local y=0.22 m,
z=-1 m. Each cell has two prebuilt material/geometry instances; the inactive one moves behind
the camera, preserving the asset baseline. The existing non-native generated-animation probe
keeps its original 16 red/blue cells. The strip is diagnostic scene content only.

`imageFrameId` in the optional pure Zig Vulkan layer scans a bounded upper image band for
forty separate dominant green/blue runs. It does not require an assumed stereo eye offset
or a single exact sample pixel. It checks run widths, sentinel patterns and complementary
words, then requires at least three agreeing scan lines and no conflicting valid line. RGBA
and BGRA are supported. ID validity, generation, agreeing rows and conflicts are written beside
each image's marker moments and producer submission ID.

This is redundancy, not an atomicity guarantee or an error-correcting code. For example, a
coordinated corruption of both complementary words could form a different valid ID. The
analyzer additionally requires every accepted ID to occur in the successful renderer publication
log. Offline decoder controls cover absent/incomplete patterns, bad complement, conflicting
valid scan lines and channel order. IDs are 16-bit and must not wrap within a capture; current
probe durations remain below 10,000 renders.

## Accounting and reproduction

Use the guarded `--render-images=projection` / `--render-images=panorama` probes and capture
commands in MOTION-IMAGES.md. The image analyzer additionally reports:

- Valid identity coverage for all 900 captured images, including warmup.
- Per-eye repeated IDs, skipped producer IDs and backward delivery, with event submissions.
- Whether the two images in a compositor producer submission contain the same ID.
- Sample-to-copy-submit and publication-end-to-copy-submit CPU intervals, correlated by ID.

The first 30 stereo submissions are excluded from delivery statistics, leaving 420 pairs.
Unknown or invalid IDs reject the measurement. Stereo grouping still uses marker stereo
position and checks one image per submission per eye. A repeated ID proves repeated captured
content, while an ID gap can also mean a rendered generation was never selected. Producer
logs must be consulted before assigning a cause. CPU copy-submission times are not the exact
compositor state-read or GPU-execution times.

`--render-stall-control` pauses the render owner for about 100 ms after capture has started,
using the existing freeze-rendering debug control, then resumes it. The compositor and driver
continue. This is a positive control for repeated captured IDs without new publications.
It is recorded as an intervention in the probe JSON and does not affect production defaults.

## Initial synthetic results

At 75 Hz, 512² source eye resolution, 960² captured eyes, fixed synthetic head and translation-only
0.7 Hz controller motion, the initial ID-enabled captures found:

| Configuration | Repeated IDs per eye | Skipped IDs per eye | Stereo mismatches / 420 |
| --- | --- | --- | --- |
| Projection / presenter | 8 / 1 | 8 / 1 | 7 |
| Panorama / vsync | 0 / 0 | 0 / 0 | 0 |
| Panorama / presenter | 2 / 2 | 2 / 2 | 0 |

All decoded IDs in those runs matched successful publications. Both eyes' generation sequences
were monotonic; projection's mismatches were adjacent generations, not arbitrary IDs. Its repeat/
skip pairs occurred predominantly in one eye. This is direct evidence that the separately
submitted projection eyes can contain different rendered generations in this configuration.
It does not identify whether the responsible compositor snapshot occurs during IPC processing,
state reads or another internal phase. A decoded frame ID also does not establish coherence
between that texture and its independently published projection pose.

Panorama's vsync run showed **no repeated generations**, despite the earlier marker-centroid
heuristic sometimes flagging repeats. Those earlier centroid candidates therefore cannot be
used as evidence of repeated compositor frames. Panorama/presenter introduced a few common-eye
repeat/skip events in this run. Sample-to-copy-submit median was about 2.3 ms for panorama/vsync
versus 11.2 ms for projection/presenter, but these CPU intervals are not display latency.

The ID strip increases renderer work: the panorama/vsync render-duration median rose to about
0.70 ms and p95 to 0.93 ms in this run, versus a single-marker baseline around 0.15 ms. This
observer effect matters when comparing phase-sensitive paths. No production pacing setting
has been changed based on these results.

Local ignored evidence under `logs/ovrdriver-lab/`:

- Projection: `render-panorama-id-projection.ndjson`, corresponding `-analysis.json`,
  `native-capture-up6yx9zd/images/`. The filename prefix is a harness artifact; publication
  metadata explicitly identifies the projection mode.
- Panorama/vsync: `render-panorama-id-panorama.ndjson`, corresponding analysis,
  `native-capture-e3r0x6de/images/`.
- Panorama/presenter: `render-panorama-id-panorama-presenter.ndjson`, corresponding analysis,
  `native-capture-gdf3lfbg/images/`.

The synthetic driver-direct backend disables Linux async reprojection. There is still no
real-HMD or VRChat workload in these tests, and the reported panorama-only physical-controller
jitter has not been reproduced. This baseline is a tool for separating frame delivery from
pose prediction and resampling, not a replacement for that validation.

### Repeat and positive-control checks

A second fresh projection session reproduced the difference: **6 / 1 repeats**, the same
number of skipped IDs, and **5 / 420 stereo pairs with adjacent IDs**. The pattern is therefore
present in more than one capture, though these short idle runs do not establish its frequency
under other workloads or on the real HMD.

The deliberate panorama/vsync render pause produced eight consecutive repeated IDs in both
eyes, with one skipped ID when rendering resumed and no stereo mismatch. This is consistent
with a roughly 100 ms producer pause at 75 Hz; captured content age reached approximately
109 ms relative to its producer sample. This validates that real repeated content is detected
even when the native controller trajectory keeps running smoothly.

All five ID-enabled runs captured **900 / 900 valid decoded images**, with no capture drops,
unknown publication IDs, output failures, or backward generations. The focused renderer tests
cover ID bit encoding, fresh tracking anchors, and the original diagnostic's unchanged defaults.
The pure Zig layer tests cover decode rejection and channel order as well as its existing
zero-count-call and render-pass-layout cases.

Additional evidence:

- Projection repeat: `render-panorama-id-projection-repeat.ndjson`, matching analysis,
  `native-capture-v36p7_nf/images/`.
- Stall control: `render-panorama-id-panorama-stall.ndjson`, matching analysis,
  `native-capture-lq0ad4t6/images/`.

Next investigation: use frame-ID delivery and ID-correlated prediction targets under a
representative workload, rather than choosing a delay from centroid noise. To investigate
texture/pose coherence, record the pose used by a particular generation and compare it with
the captured marker geometry for that **same decoded ID**. The analyzer now also reports each
frame's predicted target lead relative to copy submission; this remains an approximate CPU
interval, not a physical presentation time. Synthetic scheduling differs from real async
reprojection, so real-HMD/VRChat validation remains necessary before choosing production policy.

## VRChat home + live PetPlay desktop workload

The user clarified that the worst reported jitter was the normal wrist menu while VRChat's
home world and a desktop overlay were visible, not the isolated renderer test. That condition
must remain the target; short projection eye mismatches need not be perceptible and do not
establish the wrist bug's cause.

A scoped synthetic session successfully ran all of the following concurrently:

- VRChat in VR mode. Its log reported OpenVR initialized on PETPLAY-SYNTHETIC-HMD-001 and
  a completed home-world room load. Public IVRCompositor identified scene PID 168449,
  matching the running VRChat.exe. One timing snapshot reported scene render GPU time
  3.281 ms, compositor render CPU 0.171 ms and compositor render GPU 0.010 ms. These are
  snapshots, not percentiles. VRChat's client eye images were only 512×512 on this profile;
  this is not the physical headset's normal render workload.
- Full PetPlay scene and independent **panorama** render owner, with live scene delivery and
  30 items anchored to the right hand, using the ordinary controller-tip/grip path.
- Real desktop capture at a configured 30 fps (observed roughly 26–27 unique uploads/sec).
  The test explicitly created a temporary `petplay-lab-desktop` virtual display, 1.1 m wide,
  1.5 m ahead of the head, cropping the first half of a 3840×1080 captured desktop. The
  original layout had no virtual display handles; capture running/visible=true alone was
  insufficient evidence that a desktop image was actually shown. The temporary display used
  normalized crop bounds and was process-local, not a saved layout change.
- A **second diagnostic panorama renderer** with the known controller marker and ID strip.
  It ran alongside the normal wrist UI; it did not replace or add IDs to that wrist scene.
  Its scripted driver trajectory also moved the controllers seen by ordinary PetPlay/VRChat.

Static GPU captures were visually inspected: `workload-visible` shows the wrist UI;
`workload-desktop` shows both the wrist and live desktop image. They are static controls,
not timing evidence: the static capture path deliberately waits for readback.

### Layer distinction

With the scene app present, native driver callbacks reported **two layers per frame**.
The 960² images in this capture are the compositor-rendered overlay layer; VRChat's scene
images are a separate layer. The PPM's black background must not be interpreted as VRChat
failing to render, nor this PPM described as the final combined headset output. Native
last-eye inode snapshots matched the captured overlay-image ring. The stub does not yet
combine all submitted layers into a physical-display equivalent final image. Alpha is also
not retained by the PPM controls.

### Delivery result and limits

The diagnostic renderer's 900/900 images decoded with zero drops. After warmup, both eyes
contained generations 144–563 in order: **zero repeats, skips, regressions or stereo ID
mismatches in 420 pairs**. This measures the additional diagnostic presenter under concurrent
VRChat, normal wrist rendering and live desktop capture. It does **not** measure frame
identity or transform coherence of the ordinary wrist menu itself.

Compared with its idle vsync baseline, diagnostic sample-to-copy-submit median increased from
about 2.3 ms to **5.2 ms**; p95 was **6.7–6.8 ms**, maximum about **8.1 ms**. Approximate
predicted-target lead relative to copy submission ranged **7.1–10.8 ms**. Every generation can
arrive while pose age/horizon varies; zero dropped/repeated IDs therefore does not prove smooth
controller motion. These are CPU-correlated timings, not physical presentation times or a
recommended delay, and must not be mapped to the real HMD without measurement.

Next, add identity and controller sample/prediction logging to the **ordinary full-scene wrist
renderer**, preserving its scene delivery, grip offsets, panel/text lowering, desktop overlap,
normal resolution and workload. Correlate that identity with wrist geometry in the overlay
layer. An isolated raw-controller marker cannot stand in for the normal wrist scene. Confirm
any diagnosis under real-HMD async reprojection and the user's home-world/desktop condition.

### Harness recovery and evidence

The first attempted game launch fell back to desktop after OpenVR initialization failed.
PetPlay also reported compositor-connect failure; that attempt is excluded. A bounded
`--hold-open=210` guarded overlay client kept the fresh runtime connected through VRChat startup.
The lab-probe's `--workload-snapshot` records public scene PID/frame timing for future repeats.
Do not accept a room-load log alone as proof of a VR scene workload.

The first failed runtime needed its test-owned server/compositor terminated after graceful
shutdown timed out, followed by the existing recovery command. PetPlay also hit its existing
Linux native-teardown failure during that failed session and again when stopping the accepted
workload after capture. Both exits were 139 after native cleanup messages; this shutdown bug
is separate from the accepted steady-state measurement. The final lab restored settings and
registrations byte-for-byte and left SteamVR/game processes stopped. No physical driver was enabled.

Accepted local ignored evidence under `logs/ovrdriver-lab/`:

- `native-capture-j6crvki0/images/`: both static controls and the 900-image moment/ID stream.
- `workload-visible.png`, `workload-desktop.png`: local views of the corresponding PPMs.
- `vrchat-desktop-marker.ndjson`, `vrchat-desktop-marker-analysis.json`.
- `vrchat-workload-timing.ndjson`, `vrchat-desktop-direct-before.json`.
- `vrchat-desktop-webxr-before.json`, `vrchat-desktop-webxr-after.json`, and corresponding
  `displayOverlayHost` snapshots document ordinary scene/desktop activity around capture.
- `petplay-workload-2.log`, `workload-keepalive.log`; SteamVR/game logs remain local.

No production pacing default, persisted screen layout, controller smoothing, or real-HMD
configuration was changed based on this run.

## Full-scene rate/phase follow-up

[WRIST-SWEEP.md](WRIST-SWEEP.md) now implements a marker inside the normal wrist mount, a
constant-speed controller sweep, correct perspective/panorama geometry, and a same-session
panorama/projection × desktop-hidden/visible comparison under VRChat home. It measures motion
residuals with unique IDs, not just repeated frames. The short synthetic controls are clean in
all four accepted conditions; an independent ±3 ms alternating-pose-time control is detected.
The real-HMD shake remains unreproduced. See that document for exclusions, measurement floors,
reproduction commands and the remaining head-motion/real-tracking/UI-text limitations.
