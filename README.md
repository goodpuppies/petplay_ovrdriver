# petplay_ovrdriver

Programmable OpenVR devices for **VR debugging, automated testing, and future agent embodiment**.

The driver gives SteamVR a synthetic headset and controllers that PetPlay can inspect and
control through its actor graph. Today it is a hardware-free measurement rig: reproduce a
controller movement, run a real VR application, and compare the submitted poses with the
images SteamVR produces. The same foundation could give an agent a body in applications
such as VRChat: a head to look around with, hands to interact with, and a view of the world.

This follows PetPlay's [agents-as-actors direction](../../markdown/what-petplay-is.md#a-modular-metaverse-client-where-agents-are-first-class).
An agent uses ordinary actors and messages; motion, observation and application-specific
behavior can be implemented as actors alongside the rest of PetPlay.

## What works today

| Capability | Current implementation |
| --- | --- |
| Synthetic headset | Fixed head pose, configurable opt-in activation, 75 Hz display profile and native timing. |
| Synthetic controllers | Left/right devices sampled at 250 Hz; stationary, sine and constant-speed sweep trajectories with analytic derivatives. |
| Actor control | Attach to the driver already running inside SteamVR; inspect health/device state and queue trajectory changes. |
| Real applications | SteamVR and VRChat have run with the synthetic devices; VRChat initialized in VR and loaded its home world. |
| GPU diagnostics | Optional Vulkan layer captures overlay-layer images, decodes test frame IDs and measures moving markers after GPU completion. |
| Regression experiments | Pose/prediction controls, panorama/projection comparisons, and full-scene wrist sweeps with VRChat and a live desktop overlay. |

The current controls are designed for repeatable experiments. Arbitrary head/hand poses,
scripted buttons/axes, and a continuous combined scene view remain to be implemented before
an agent can use this as a general VRChat player. Controller triggers currently stay released;
there are no scripted thumbsticks, skeletal hands or haptic feedback handling.

## Debugging and testing

Use a known input trajectory as ground truth, then follow it through tracking, prediction,
rendering and compositor output. This makes questions such as “is the wrist shaking because
its pose time varies, or because frames repeat?” measurable without someone moving a controller
by hand or keeping a physical headset active for a long experiment.

The driver is a general test substrate. Overlay pacing was its first substantial use case;
other uses include input/pose replay, interaction regression tests, tracking-loss controls and
repeatable workload comparisons as the corresponding device controls are added.

The synthetic profile is a distinct test environment. Linux driver-direct mode changes
SteamVR's async reprojection behavior, and its timing/resolution need not match a physical
headset. Results must carry their device profile and workload; a synthetic pass alone does
not establish that a real-headset bug is fixed.

## Agent embodiment

The intended loop is **observe → decide → command devices → observe the application's response**.
SteamVR supplies the application-facing device boundary, while PetPlay supplies the actor
runtime in which an agent's behavior can live. A behavior actor could navigate or reach for an
object by coordinating a motion actor and an observation actor. VRChat is a concrete target
for that architecture; successful autonomous interaction has not yet been demonstrated.

Keep planning and native sampling at separate rates. An agent can choose an action or upload
a motion segment, while the driver evaluates motion between decisions. The existing analytic
trajectory worker already follows this pattern: one command starts motion, with no per-sample
JavaScript or IPC required.

The next pieces for a useful embodied agent are:

- **A programmable body:** timestamped head and independent hand motion, reference-space
  control, and explicit reset/replay behavior.
- **Interaction:** button, trigger, grip and stick states with application-compatible bindings.
- **Observation:** continuous, synchronized scene/overlay images with frame and pose metadata.
  SteamVR currently supplies separate layers; the stub does not yet combine them into a final
  headset-equivalent view. Diagnostic overlay readback is the working starting point.
- **Behavior actors:** translate goals into sustained motion/input and interpret the resulting
  observations. These belong in the ordinary PetPlay actor graph.

Image transport should preserve native GPU resources or use a dedicated observation stream;
large image frames do not belong in the bounded JSON control messages. The transport and
ownership boundaries are described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Single-eye desktop observation

`CAPTUREDIRECTEYE {directory, layer:0, eye:0, maxEdge:1024}` captures only the selected
presented layer and eye. Layer must be 0–7, eye 0–1 and maxEdge 256–1920; absent selections
default to layer 0 / left eye / 1024. The result is `{present, eye:{file,width,height,format,bounds}}`.
The image keeps its aspect ratio and is downsampled on the GPU before host readback. Only
the selected source FD is duplicated; the other eye and overlay layers are not read back.
The directory must already exist and be absolute; the raw RGBA/BGRA file belongs to the caller,
which must remove it. Control messages contain metadata only. `CAPTUREDIRECTFRAME` remains
available for full diagnostic captures with its previous output contract.

PetPlay's I-mode consumer uses a private directory under `/tmp` (tmpfs here), one request in
flight, and a GPU upload of the returned image. On the beyond75 synthetic session in Partybox,
the previous two-eye/two-layer capture produced 280 MB and took roughly 2.9–3.0 s. Selected
1024² capture produces 4 MB: native probes measured 35–51 ms, and the live desktop path
measured median 50 ms (35–81 ms), about 13 eye updates/s with a 48–56 FPS window loop.
These are diagnostic measurements, not a full-rate or zero-copy delivery claim. Producer
synchronization remains the existing presented-frame/guard approach documented in
`GPU-READBACK.md`; resizing does not add a producer-completion guarantee.

## Build and validate

Supported target: **Linux x86-64, Zig 0.16.0**. Live GPU experiments currently require a desktop
GL/Vulkan environment; hardware-free does not yet mean surfaceless.

```sh
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
# Optional producer-side Vulkan image diagnostic and its tests:
zig build capture-layer -Doptimize=ReleaseSafe
```

Outputs include:

- `zig-out/petplay/`: the SteamVR driver package, including `bin/linux64/driver_petplay.so`.
- `zig-out/bin/petplay_ovrdriver_actor`: standalone protocol-test actor.
- `zig-out/lib/libpetplay_capture.so`: optional Vulkan diagnostic layer.

The driver is pure Zig, with explicit versioned OpenVR ABI tables and no C++ adapter.
It links libc/pthreads for hosting inside SteamVR. C++ is used only by the offline
consumer of the pinned official header to validate ABI calls, layouts and lifecycle.
Windows and other target ABIs are outside the verified contract.

Builds and offline tests do not register the driver, restart SteamVR or activate a physical
display. From the enclosing PetPlay checkout, the integration test also checks the actual
shared library and externally owned Stageforge proxy:

```sh
deno run -A utils/petplay-ovrdriver-test.ts
```

## Run a scoped lab

The enclosing PetPlay checkout provides a launcher that backs up SteamVR settings and driver
registrations, selects only the synthetic driver, and restores the original bytes on exit.
Build first and start with SteamVR stopped:

```sh
python3 utils/petplay-ovrdriver-lab.py run --driver-direct --direct-server --x11-compositor --capture-layer --seconds 300
# In another terminal, keep the guarded overlay client connected during app startup:
deno run -A utils/petplay-ovrdriver-lab-probe.ts --hold-open=270
```

Run those commands from **PetPlay's root**, not this submodule. A long game startup needs the
keepalive client. After an interrupted session, with SteamVR stopped:

```sh
python3 utils/petplay-ovrdriver-lab.py recover
```

See [LIVE-LAB.md](LIVE-LAB.md) for setup/recovery details and
[WRIST-SWEEP.md](WRIST-SWEEP.md) for the full workload and measurement procedure.

## Connect through PetPlay

SteamVR owns the driver's lifecycle. PetPlay attaches a proxy to its existing actor identity;
attachment sends no INIT/LOADED, and detaching leaves the driver running. The standalone test
actor has a separate lifecycle and is not the live driver connection.

For example, from code in the enclosing PetPlay checkout:

```ts
import { PostalService } from "./submodules/stageforge/mod.ts";
import { attachOpenVrDriverProxy } from "./classes/petplayOpenVrDriverProxy.ts";

const postal = new PostalService();
const driver = await attachOpenVrDriverProxy(postal, "/absolute/shared-lab-directory/control.sock");
try {
  const state = await postal.PostMessage({
    target: driver, type: "GETCONTROLLERSTATE", payload: null,
  }, true);
  console.log(state);
} finally {
  postal.detachProxy(driver);
}
```

`SETCONTROLLERMOTION` queues a trajectory and returns a command ID; `GETCONTROLLERSTATE`
reports when it has been applied. `GETDIRECTSTATE` exposes native output diagnostics.
See [CONTROLLER-LAB.md](CONTROLLER-LAB.md) for motion payloads and measurements.

All synthetic-device settings default to false. `driver_petplay.syntheticHmd` opts into the
HMD; `syntheticControllers` independently adds controllers (including alongside a real HMD); `driverDirect` selects the
experimental shared-image backend. The alternative DisplayRedirect backend is a clocked
discard sink. `socketDirectory` overrides the private Unix socket location when Steam's
private runtime mount requires a shared home-directory path. Endpoint ownership and peer-UID
checks still apply. One control connection is served at a time.

### Synthetic display workload profiles

The optional `driver_petplay` settings `renderWidth`, `renderHeight`, `displayEyeWidth`,
`displayEyeHeight`, `refreshHz`, `ipdMeters` and `maxSwapchainMiB` configure the synthetic display.
Defaults preserve the original 640×640 render recommendation, 640×720 eye output, 75 Hz,
64 mm IPD and 512 MiB total direct-mode swapchain budget. Settings are loaded before activation,
not changed while device/clock threads run. Invalid values reject HMD activation; absent settings
use defaults. Both direct and redirect clocks follow the configured rate on a rational timeline.
`GETDISPLAYPROFILE` reports the loaded profile without GPU readback.

The parent checkout's `--display-profile=beyond75` lab option sets a BSB-like workload from saved
physical-session logs: 3562² recommended eyes (SteamVR rounds to 3560²), 2544² output viewports,
75 Hz, 68 mm IPD and a 4096 MiB bounded swapchain budget. This is a rendering-load profile with
symmetric synthetic optics, not an optical/scanout emulator. Direct swapchain dimensions can
reach 8192; allocations remain constrained by the profile's aggregate budget.

From the parent checkout, with SteamVR stopped:

```sh
python3 utils/petplay-ovrdriver-lab.py run --driver-direct --direct-server --x11-compositor --touch-controllers --display-profile=beyond75 --seconds=300
deno run -A --no-check utils/petplay-ovrdriver-lab-probe.ts --hold-open=270
```

`--refresh-hz=90` can override the synthetic clock for an explicit load experiment. The launcher
refuses display options in real-HMD mode. Keep the 960²-only Vulkan capture layer disabled for
these larger profiles; normal driver-direct rendering does no GPU readback. The launcher records
its selected profile and restores original SteamVR settings after a clean shutdown. If SteamVR
hangs during teardown, the recovery backup remains intact; stop the owned runtime before using
`recover`. Such a run is a failed lifecycle check even when its rendering checks passed.

## Implementation and evidence

| Document | Contents |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | ABI, actor identity, IPC, process ownership and sampling boundaries. |
| [LIVE-LAB.md](LIVE-LAB.md) | Synthetic HMD startup, display clock, scoped settings and recovery. |
| [CONTROLLER-LAB.md](CONTROLLER-LAB.md) | Native controller commands and public pose/prediction controls. |
| [DIRECT-MODE.md](DIRECT-MODE.md) | Shared Vulkan images, native layer submission and output limitations. |
| [GPU-READBACK.md](GPU-READBACK.md) | Working producer-side readback and GPU completion controls. |
| [PRESENT-BOUNDARY.md](PRESENT-BOUNDARY.md) | Presentation-path audit and the working completion contract at the compositor's present call. |
| [FRAME-IDENTITY.md](FRAME-IDENTITY.md) | Decoded frame delivery and VRChat/desktop workload observations. |
| [WRIST-SWEEP.md](WRIST-SWEEP.md) | Full-scene wrist rate/phase measurements and paired presentation paths. |
| [MOTION-IMAGES.md](MOTION-IMAGES.md) | Capture ring, marker baseline and deliberately choppy controls. |
| [OUTPUT-DESTINATIONS.md](OUTPUT-DESTINATIONS.md), [OUTPUT-CAPTURE.md](OUTPUT-CAPTURE.md) | Output-route research, rejected approaches and remaining observation work. |

Runtime teardown resource references and some PetPlay/native shutdown paths still need work;
see the linked evidence before extending the lab into a long-lived observation service.
Raw captures and runtime logs remain local and ignored.

Vendored SDK declarations retain their upstream licenses and pinned revisions:
[OpenVR](vendor/openvr/UPSTREAM.md), [Vulkan-Headers](vendor/vulkan/UPSTREAM.md).
