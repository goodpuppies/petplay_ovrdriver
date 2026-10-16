# Linux driver-direct bring-up — 2026-10-16

**Follow-up:** fenced producer-side readback now verifies quad, panorama and projection pixels
in the actual driver buffers. See [GPU-READBACK.md](GPU-READBACK.md). The original cross-process
completion and teardown ownership limitations still apply.

Status: **real buffer allocation, handoff callbacks and producer-side image-content controls
work on this machine**. An external driver-side GPU reader remains unimplemented. The driver has no C++ adapter and
does not depend on ALVR; its source was used as an architectural reference.

## Select the diagnostic backend

From PetPlay, build first, with SteamVR off:

```sh
cd submodules/petplay_ovrdriver
zig build test install -Doptimize=ReleaseSafe
```

From the PetPlay root:

```sh
python3 utils/petplay-ovrdriver-lab.py run --driver-direct --direct-server --x11-compositor --seconds 30
```

During startup, run in another terminal:

```sh
deno run -A utils/petplay-ovrdriver-lab-probe.ts --direct-state --direct-markers
```

The direct-server profile can shut down early if no OpenVR client remains connected; start
the probe promptly after the compositor starts. The outer lab window is a maximum lifetime,
not a keepalive. The launcher's existing exact-byte settings/registration restoration and
synthetic-only checks apply. It leaves SteamVR off. No physical display is leased in this test.

`driver_petplay.driverDirect` defaults to false and is effective only with `syntheticHmd`.
When true, the HMD exposes `IVRDriverDirectModeComponent_009`, reports not-on-desktop, and
registers no DisplayRedirect device. The compositor plugin refuses initialization so it cannot
supply a second display clock. The original backend remains available with the option off.

## What the Zig backend does

- Uses the already-vendored SDK's `IVRIPCResourceManagerClient_003`. Lookup happens lazily
  during texture allocation because the SDK documents asynchronous resource-manager startup.
  An unavailable lookup is retried on the next allocation callback.
- Allocates real triple-buffered images with `NewSharedVulkanImage`, exports FDs through
  `RefResource` / `ReceiveSharedFd`, and retains the handles and owned close-on-exec FDs.
  Allocations are restricted to single-sample 8-bit RGBA/BGRA, dimensions at most 4096²,
  at most 64 sets and a 512 MiB uncompressed pixel budget (not a physical-memory guarantee).
- Zeroes the output first, rolls back partial allocations, rotates shared eye sets once per
  next-index call, and releases sets by any member handle, owner PID or provider cleanup.
- Counts SubmitLayer, Present, PostPresent, timing and allocation activity. `GETDIRECTSTATE`
  is a callback-based actor request returning a mutex-protected snapshot. It is diagnostic
  metadata, not a handle-import or image-transfer protocol; do not round-trip opaque 64-bit
  handles through JavaScript numbers for GPU operations.
- Announces a native rational 75 Hz vsync grid and paces PostPresent to a nominal grid edge.
  Missed clock slots are skipped. The 2 ms announcement lead is a synthetic display profile,
  not an inferred correct overlay publication delay. It is not a production pacing result.
- Sets `Prop_DriverDirectModeSendsVsyncEvents_Bool` and
  `Prop_Hmd_AllowsClientToControlTextureIndex`. Omitting the first property produced a 150 Hz
  public frame counter while WaitFrameSync woke at 75 Hz; declaring clock ownership corrected
  this. The timing probe now rejects a substantially incorrect counter or wake rate.

**The driver has no external GPU reader.** The optional producer-side layer now verifies
image content; see GPU-READBACK.md. Present counts and exported FDs do not establish which pixels
were composed, whether GPU writes completed, or the displayed cadence of a moving controller.
The backend neither overwrites shared images nor reimplements overlay composition.

## Verified live

SteamVR 2.17.10, Linux x86-64, AMD RX 7900 XTX, same compositor BuildID as
[OUTPUT-CAPTURE.md](OUTPUT-CAPTURE.md). Compositor logs explicitly select driver-direct mode;
Linux async reprojection is disabled by the runtime for this driver route. This difference
must be accounted for before drawing conclusions about a physical-HMD jitter mechanism.

| Measurement | Corrected direct-mode run |
| --- | --- |
| Texture sets | Two 960×960 sets, three images each, VkFormat 43 |
| Uncompressed image budget | 22,118,400 bytes |
| Allocation errors / unknown submitted textures | 0 / 0 |
| WaitFrameSync | 225 calls in 2999.873 ms, no errors |
| Public vsync counter advance | 225, approximately 75.003 Hz |
| Repeated / invalid counter samples | 0 / 0 |
| Wake interval median / p95 / max | 13.334 / 13.361 / 13.528 ms |
| Sync texture passed to Present | 0 |

The separate marker probe creates opaque red quad, green stereo-panorama and blue projection
textures through `SetOverlayRaw`. It shows each individually, then all together, after a hidden
baseline. Each stage waits 60 successful WaitFrameSync calls. All API calls succeed and
`IsOverlayVisible` matches the requested visibility. Every stage advances exactly 60 submits
and presents, with one submitted layer per frame, no additional texture sets, allocation
failures or unknown handles. This is consistent with composition into the existing eye pair,
but cannot distinguish rendered markers from overlays ignored downstream. The later pixel inspection in GPU-READBACK.md supplies the image-content positive control. No scene application was active in this experiment.

Local evidence, intentionally ignored by git:

- `logs/ovrdriver-lab/direct-frame-probe-fixed-20261016.txt`
- `logs/ovrdriver-lab/direct-markers-20261016.ndjson`
- Runtime archives `20261016-134010` and `20261016-134203`.

The sessions did not show the previous device-loss/timeline failure. They restored the
original settings and external registrations and stopped the runtime.

## Offline checks and remaining ownership work

The official-header C++ fixture exercises all eight Zig direct-mode slots and reverse calls
through the resource-manager vtable. It checks structure sizes and offsets, delayed interface
availability, partial-allocation/ref/FD failures, output zeroing, shared-set index rotation,
frame-timing size guards, destroy-by-handle/PID, owned FD closure and clock-thread shutdown.
Both Debug and ReleaseSafe checks pass. This fixture does not emulate GPU allocation or prove
runtime reference ownership.

During live provider cleanup, UnrefResource returned false for all six handles. SteamVR had
already logged failed compositor resource unrefs while disconnecting the compositor. The
local FDs are closed and the ledger clears, but the runtime's teardown/reference lifetime is
not established. This is recorded as `releaseFailures`, not hidden or labelled successful
balanced live release. Audit that ownership before making this a long-running capture backend.

## External reader still pending

First establish the producer completion and resource lifetime contract. Linux currently
passes a zero syncTexture. A Present callback, WaitFrameSync wake, mirror lock or arbitrary
sleep must not be promoted to a producer GPU-completion fence. ALVR's current implementation
has its own writer-fence/guard-delay workarounds; those are useful references, not a proven
contract to copy into this diagnostic.

Then import the real images in a native GPU reader, with explicit bounded reuse, and read one
completed frame with a known marker. Inspect every submitted layer. Repeat with a scene app
active and record the backend's async/reprojection differences. The producer-side pixel controls now provide a baseline for later panorama/projection motion
and generation comparisons. Desktop preview, file readback
and eventual analysis can share that reader; actor messages should carry controls and compact
measurements rather than full frames.

See [the pinned ALVR references and route comparison](OUTPUT-DESTINATIONS.md).
