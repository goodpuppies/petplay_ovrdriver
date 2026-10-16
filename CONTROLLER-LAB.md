# Programmable controller lab — 2026-10-16

Two opt-in controllers now register alongside the synthetic HMD. Their public OpenVR poses
can be measured against known analytic motion without moving or powering a physical controller.
This tests the tracking/prediction part of the pipeline. The subsequent
[MOTION-IMAGES.md](MOTION-IMAGES.md) adds final-image controls and a bounded capture ring.
Neither baseline explains the panorama-only controller jitter yet.

## Device and actor controls

Both `driver_petplay.syntheticHmd` and `syntheticControllers` must be true. The latter defaults
to false in the installed driver settings. The enclosing PetPlay scoped lab enables both.

Serials are `PETPLAY-SYNTHETIC-LEFT-001` and `PETPLAY-SYNTHETIC-RIGHT-001`; role hints are
left/right, with controller type `petplay_synthetic`. The custom profile exposes trigger
click/value and haptics. Triggers initialize released; button scripting, haptic event handling,
render models, skeletal hands and app-specific bindings are not implemented.

Attach to the existing actor through `attachOpenVrDriverProxy(postal, socketPath)`. No
INIT/LOADED, spawning or remote shutdown is involved. Ordinary Stageforge requests:

```ts
const queued = await postal.PostMessage({
  target: id,
  type: "SETCONTROLLERMOTION",
  payload: {
    mode: "sine",             // or "stationary"
    frequencyHz: 0.7,
    positionAmplitudeM: 0.12,
    yawAmplitudeRad: 0.4,
  },
}, true);
const state = await postal.PostMessage({ target: id, type: "GETCONTROLLERSTATE", payload: null }, true);
```

Acceptance means **queued**, not yet applied. Poll state until `appliedId` equals the returned
`commandId` when that distinction matters. Fire-and-forget also applies valid commands but
cannot report validation/queue errors. Motion changes reset the trajectory epoch at the native
sample boundary. Multiple commands arriving before the same sample are processed in order;
the final one determines the next sampled state. Unknown fields, invalid modes, non-finite
numbers, frequencies outside (0,5] Hz, amplitudes outside [0,1] m, or yaw outside [0,π] rad are
rejected. The queue holds eight commands; a full queue returns a structured actor error.

Base positions are (-0.25,1.2,-0.5) and (+0.25,1.2,-0.5) m. Sine motion changes X and yaw
about Y. Right-hand phase is π/2 ahead of left. Position, orientation, linear/angular velocity
and acceleration come from the same analytic definition at CLOCK_MONOTONIC sample time.
`poseTimeOffset` accounts for evaluation-to-submission time. This never reuses an IR timestamp.

A separate native worker samples on an absolute 250 Hz grid, skipping missed slots. No JSON,
allocation or per-frame PetPlay message is needed there. State snapshots expose the applied
configuration/epoch, active device indices, sample and submission timestamps, published poses,
update counts and largest observed sample gap. These are soft real-time diagnostics; OS
scheduling, the shared state mutex and runtime callbacks can still delay publication.
Deactivate synchronizes with publication; Cleanup joins the worker before releasing context.

## Reproduce

From PetPlay, with SteamVR off:

```sh
deno run -A utils/petplay-ovrdriver-test.ts --build
python3 utils/petplay-ovrdriver-lab.py run --seconds 60 --x11-compositor
```

In another terminal during that session:

```sh
deno run -A utils/petplay-ovrdriver-lab-probe.ts --controllers
python3 utils/petplay-ovrdriver-controller-analyze.py logs/ovrdriver-lab/controller-samples-<timestamp>.ndjson
```

The guarded probe first measures frame-sync cadence and verifies the synthetic HMD serial.
It then verifies controller roles/indices, uploads stationary and sine definitions, waits for
native application, and measures 150 queries per definition/prediction setting. Each query
reads both controllers, producing 1,200 records total. Requested predictions are 0 and 20 ms.
The raw/uncalibrated tracking origin avoids room calibration as a comparison confound.

Query time is bracketed using libc CLOCK_MONOTONIC in the Deno client, matching the driver's
clock domain. Ground truth uses the midpoint plus the explicitly requested prediction horizon.
The probe writes NDJSON including query bounds/duration, config, epoch/phase, returned position,
yaw and velocities, and analytic error. It resets motion to stationary before detaching.
The launcher stops SteamVR and restores exact original settings/registration bytes afterward;
see [recovery](LIVE-LAB.md#run-from-the-enclosing-petplay-checkout).

## Initial live results

SteamVR 2.17.10, Linux x86-64, fixed synthetic head, lightweight scene, no VRChat. Auto-start
SteamVR clients may be present; this is not a workload-isolated performance benchmark.
The controller profile loaded and both roles were correctly assigned. Frame-sync check:
225 wakes/225 frame advances in 2999.933 ms (75.002 Hz), no errors or repeated counters.

| Motion | Requested prediction | Position error p95 | Yaw error p95 |
| --- | --- | --- | --- |
| Stationary | 0 ms | 0.000048 mm | 0° |
| Stationary | 20 ms | 0.000048 mm | 0° |
| Sine | 0 ms | 0.0111 mm | 0.00212° |
| Sine | 20 ms | 0.6127 mm | 0.1170° |

There were no invalid poses or frame-sync errors in any controller group. Zero-prediction
sine max position error was 0.209 mm, coinciding with a client query lasting up to 0.835 ms;
query-time uncertainty alone can contribute roughly 0.22 mm at this trajectory's maximum speed.
This does not establish the cause of that outlier. Native maximum sample gaps during the run
were about 5.3 ms; sampling does not claim zero scheduling jitter.

The 20 ms error is mostly systematic amplitude overshoot: per-hand sine fits found gains of
1.00462–1.00469, phase offsets about -0.060 to -0.068 ms, and residual p95 0.073–0.081 mm.
This is consistent with approximate extrapolation of curved motion, rather than a large
random phase jump; the runtime's exact predictor has not been proven here. The analyzer
reports fitted gain/phase separately from residual variation and does not apply corrections.

A second fresh runtime session reproduced the result: sine error p95 0.0107 mm at zero
prediction and 0.5941 mm at 20 ms; zero-prediction max 0.0345 mm. All 1,200 controller records
were valid and all sync waits succeeded. The fitted 20 ms gains were 1.00453–1.00454 with
residual p95 0.069–0.071 mm. These are two short local runs, not broad hardware/load coverage.

## What is established and what comes next

The native driver, actor control queue, handed devices, timestamps, and client-predicted poses
now form a repeatable tracking lab. Pure Zig motion tests independently check analytic
velocity/acceleration against finite differences. Official-header C++ tests check the driver
input ABI, initial released values, pose calls, deactivation and cleanup. Queue tests check
capacity, validation and application boundaries. Debug, ReleaseSafe and Stageforge proxy tests
pass. C++ remains only in the offline fixture.

The public-pose data does not show a large irregularity on this trajectory at zero prediction.
It does not test PetPlay's renderer or any compositor-consumed images. Next, make final-image
capture work, run the known motion through panorama and projection paths, and compare pose
samples, rendered controller placement and consumed frame generations. Then repeat with
VRChat's home world and explicit load profiles. A 250 Hz synthetic source and a virtual display
clock do not reproduce every physical controller, headset or runtime timing behavior.

`mode: "sweep"` now supplies constant-speed legs with smooth reversals and analytic derivatives.
See [WRIST-SWEEP.md](WRIST-SWEEP.md) for the full-scene controller/wrist phase experiment.

## Real headset with synthetic controllers

Controllers now opt in independently of `syntheticHmd`. A controller-only provider
registers no HMD or display, emits no display clock, and does not block standby.
This lets the physical headset retain its own optics, refresh timing and Linux
async reprojection while the hands follow the same analytic test trajectory.

From the parent checkout, with SteamVR stopped:

```sh
python3 utils/petplay-ovrdriver-lab.py run --real-hmd --seconds 3600
# In another terminal, with the headset tracking and physical controllers off:
deno run -A --no-check utils/petplay-ovrdriver-hybrid-probe.ts --sweep
```

The scoped launcher preserves existing external drivers, physical driver settings,
power settings and display settings. It adds a controller-only manifest with
`alwaysActivate: true` and `redirectsDisplay: false`, enables multiple drivers,
and restores the original configuration bytes when the session ends. Interrupted
sessions use the same `recover` command as the synthetic lab.

`--sweep` places the test rig once relative to the current raw headset pose:
hands roughly 40 cm below and 50 cm forward, with a horizontal 24 cm sweep.
It checks that both hand roles belong to the synthetic controllers. The rig then
stays in world space; it does not follow subsequent head movement. Re-run to
reposition. `--place` performs the same placement with stationary hands.
The motion command's `worldTranslationM` and `worldYawRad` specify this fixed
raw-space transform; the driver retains analytic local velocities and accelerations.

Start with a still-head panorama/projection comparison, then repeat with head
movement, and finally with VRChat home and a visible desktop overlay. Record
headset feedback separately from image measurements. The existing synthetic
960×960 GPU capture and fixed-head analyzer do **not** automatically apply to the
real headset's compositor targets or moving camera.

For in-person comparisons, `--hold` stops motion without changing the rig's
placement, and `--resume` resumes a sweep at that placement. Add `--fast` to
`--resume` for a 1 Hz, ±20 cm sweep (about 0.89 m/s in each constant-speed leg,
versus 0.19 m/s for the original sweep). These affect controller motion only;
PetPlay's presentation and full layout visibility are controlled separately.
