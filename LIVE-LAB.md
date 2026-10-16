# Synthetic HMD bring-up — 2026-10-16

The pure Zig DSO loads in SteamVR 2.17.10 on this Linux x86-64 machine and supplies a
valid synthetic HMD plus a compositor-side 75 Hz virtual clock. Physical and remote drivers
were excluded throughout. This establishes a hardware-free timing lab; it does **not** yet
establish image capture or reproduce/fix panorama controller jitter.

## Run from the enclosing PetPlay checkout

```sh
deno run -A utils/petplay-ovrdriver-test.ts --build
python3 utils/petplay-ovrdriver-lab.py run --seconds 50 --x11-compositor
```

During that session, from another terminal:

```sh
deno run -A utils/petplay-ovrdriver-lab-probe.ts
```

The probe refuses any serial other than `PETPLAY-SYNTHETIC-HMD-001`. It warms up ten
WaitFrameSync calls, then measures 225 wakes with a 100 ms diagnostic timeout. That timeout
is a failure bound, not an inferred present phase. No per-frame guessed safe-window setting
is used. It reports wake intervals, counter advances, invalid vsync queries and errors.

The launcher requires SteamVR to be off. It preserves exact original bytes of both
`steamvr.vrsettings` and `openvrpaths.vrpath` in ignored `logs/ovrdriver-lab/restore.json`.
It temporarily selects only the built PetPlay driver, disables bundled alternatives, sets
synthetic mode, disables Home, and uses a shared-home private socket directory. It does not
edit bundled driver manifests or install/register anything permanently. It stops runtime and
room-setup processes on completion and restores those files. SteamVR remains off afterward.
Captured runtime logs go into timestamped directories under the same ignored lab folder.

If interrupted so cleanup cannot finish, stop SteamVR and recover explicitly:

```sh
python3 utils/petplay-ovrdriver-lab.py recover
```

Keep the restore file until recovery succeeds. Restore refuses while runtime processes remain.
This local launcher assumes the workstation's standard Linux Steam install paths and desktop
Steam session; it is not yet a general installer or a concurrent-session manager.

## What was verified

- Official-header offline consumer: provider/device/display/compositor-plugin dispatch,
  reverse settings/property/host calls, both eyes' viewport/projection/distortion and aggregate
  returns, fixed-pose publication, registration refusal, shutdown and reinitialization.
- Debug and ReleaseSafe native/protocol checks plus the real Stageforge proxy tests pass.
- vrserver loads `driver_petplay.so`, selects the synthetic HMD, and registers DisplayRedirect.
- Native actor health reports initialized/active HMD, advancing pose updates, no IPC/device
  failure and no standby. Host PetPlay attached through its real PostalService, detached and
  reattached, preserving actor identity without INIT/LOADED or owning the runtime.
- vrcompositor loads the independent compositor provider and logs its first virtual timing
  callback. It reaches Startup Complete without leasing the physical headset display.
- Final 225-wake sample: 2999.750 ms, 225 frame-counter advances, 75.006 Hz; no WaitFrameSync
  errors, invalid vsync samples or repeated frame counters. Wake interval median 13.351 ms,
  p95 13.663 ms, min/max 12.434/14.131 ms. These are observations on this machine, not guarantees
  across workloads or evidence that every composited image is correct.

## Findings and constraints

A desktop `IVRDisplayComponent_003` alone did not work. This runtime logged that it had no
adapter for that version. Version 002 has the same first seven methods; we offer that prefix
as well, retaining 003's appended inverse-distortion method. The older contract can be checked
against [Valve's 1.16.8 header](https://github.com/ValveSoftware/openvr/blob/v1.16.8/headers/openvr_driver.h).

Linux still requested a DRM-leased display in debug mode. Read-only binary inspection found
that the failure path queries `steamvr.allowFallbackMirrorWindowLinux`. Temporarily enabling
it gets past the DRM failure, but the Wayland fallback then asserts `!m_bWayland`. Retrying the
normal compositor launcher with WAYLAND_DISPLAY and GAMESCOPE_WAYLAND_DISPLAY unset allows
its X11 fallback to start. This internal setting and X11 requirement are explicitly lab-only
compatibility dependencies; no runtime binary was patched during this work. The machine
already has local SteamVR/Linux modifications, so stock-runtime portability is unproven.

Exposing a virtual display only through a server device did not supply a working clock.
The DSO now also exports the public `IVRCompositorPluginProvider_001` factory interface.
That independent instance supplies `IVRVirtualDisplay_002` in vrcompositor. Its clock is
computed from elapsed CLOCK_MONOTONIC time at a rational 75 Hz, independent of Present or
pose callback counts. WaitForPresent, when called, waits for the next absolute clock edge.
See [Valve's driver documentation](https://github.com/ValveSoftware/openvr/blob/master/docs/Driver_API_Documentation.md#ivrvirtualdisplay)
and [example](https://github.com/ValveSoftware/virtual_display) for the interface context.

**Output remains unverified.** See the later [capture audit](OUTPUT-CAPTURE.md): the selected
virtual Present branch is a stub and capture instrumentation encountered device loss. In the observed Linux fallback, timing queries occur but
Present and WaitForPresent have not been called. The discard sink deliberately does not
interpret or retain shared GPU handles, copy images, or signal GPU completion. Server actor
virtual-display counters stay zero because compositor counters live in another process.
The compositor log records its first callback and counter totals on cleanup. A clocked HMD
is enough for the next pose/controller API tests, but final-frame overlay jitter tests still
need a validated capture path and then representative scene workloads.

Steam's container also has a private `/run/user/<uid>` mount. The original default socket
was present inside vrserver's mount namespace, invisible at the host's normal path. The
optional `driver_petplay.socketDirectory` setting fixes host attachment using an explicit
shared-home directory with the same 0700 directory / 0600 socket security checks.

## Next

Left/right controllers, a small input profile, queued native trajectories, and public-pose
comparisons are now implemented; see [controller results](CONTROLLER-LAB.md). Establish
compositor final-image capture before drawing conclusions about panorama versus projection
consumption. No controller-jitter conclusion follows from
this fixed-head clock test alone.
