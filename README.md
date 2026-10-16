# petplay_ovrdriver

Pure Zig OpenVR driver foundation for PetPlay's programmable VR test devices and future
runtime integrations. Linux x86-64, Zig 0.16.0. Native actor connection, opt-in synthetic HMD/display clock, and programmable controllers implemented.

The shared library contains **no C++ adapter**. Zig exports `HmdDriverFactory` and explicitly
implements the versioned OpenVR provider/device vtables. C++ appears only in the offline test
consumer compiled against the vendored, pinned Valve SDK header. No registration, SteamVR
restart, physical display activation or persistent settings change happens during build/test.

## Build and check

```sh
zig build
zig build test
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

Outputs:

- `zig-out/petplay/bin/linux64/driver_petplay.so`: native driver shell, context initialization
  and lifecycle, plus a private Unix socket for attaching an existing-actor proxy. Device registration requires the explicit `driver_petplay.syntheticHmd` setting.
- `zig-out/petplay/driver.vrdrivermanifest`: inactive-by-default driver manifest.
- `zig-out/bin/petplay_ovrdriver_actor`: standalone native actor for transport/protocol tests.
  This is **not** a replacement vrserver process or a loader for the driver.

From the enclosing PetPlay checkout:

```sh
deno run -A --no-check utils/petplay-ovrdriver-test.ts
```

That test uses Stageforge's real PostalService to register and route to the Zig actor. It
checks generated actor IDs, health, Unicode/BigInt wire tags, concurrent callback correlation,
missing-handler errors/recovery, ordinary shutdown and cooperative connection teardown.
See [architecture](ARCHITECTURE.md) for what is implemented and what still needs building.

The ABI test covers both call directions: C++ consumer → Zig provider/device, and Zig → C++
fake runtime context/host. It checks lifecycle, scalar/pointer arguments, full DriverPose_t
size/alignment, selected offsets, large struct-by-value return, and native JSON dispatch through
an offline device DebugRequest. Synthetic display tests cover property writes, both eyes,
distortion/inverse distortion and the independent compositor-plugin lifecycle/clock. Those offline checks do not prove final-image output or full C++ ABI
support. RTTI/dynamic_cast, inheritance beyond the declared interface objects, non-x86-64 Linux,
and Windows are outside the verified contract. Unsupported driver targets fail at compile time.

The live connection path uses the existing actor identity and does not send INIT/LOADED.
See PetPlay's `classes/petplayOpenVrDriverProxy.ts`. The end-to-end test also attaches via the
actual driver's Unix socket in an offline host, verifies state survives proxy removal, and
checks provider Cleanup while a client is connected. The synthetic driver has also been loaded by SteamVR; see [live lab results](LIVE-LAB.md).

The C++ test executable uses LLVM's linker because the installed native GCC 16 CRT's .sframe
relocations are unsupported by Zig 0.16's default linker. The driver links libc/pthreads for threading inside a foreign host, and never libc++.
The standalone native actor links neither runtime; the C++ test consumer links libc++.

## Repository integration

Intended PetPlay submodule path: `submodules/petplay_ovrdriver`.
All building and tests are local. Publishing a remote repository is a separate step.

## SDK

Vendored OpenVR header: Valve's BSD-style license in
`vendor/openvr/LICENSE`; exact upstream revision is recorded in `vendor/openvr/UPSTREAM.md`.

## Synthetic runtime

`driver_petplay.syntheticHmd` defaults to false. Opting in registers a fixed, valid HMD at
(0, 1.6, 0) and a separate DisplayRedirect device. The profile is 75 Hz, 64 mm IPD,
symmetric ±1 projection tangents and 640×640 recommended eye targets. The driver also exports
`IVRCompositorPluginProvider_001` so its virtual clock can run inside vrcompositor. This is a
clocked discard sink; it does not display or capture images, or wait for GPU completion.

`driver_petplay.socketDirectory` optionally overrides the private Unix socket directory.
An empty string retains `/run/user/<uid>/petplay_ovrdriver`. Steam's runtime may mount a private
`/run/user`, so a shared home-directory path is needed for host-side PetPlay attachment.
The same ownership, mode, peer-credential and owner-lock checks still apply. Pass its
`control.sock` path explicitly to `attachOpenVrDriverProxy`.

The enclosing PetPlay repo provides a scoped lab launcher and read-only timing probe.
See [LIVE-LAB.md](LIVE-LAB.md) for commands, exact recovery behavior, measured results,
and the remaining final-image/controller work.

`driver_petplay.syntheticControllers` separately opts into left/right controllers (also requires
syntheticHmd). They start stationary with released triggers. Actor messages can upload a sine
trajectory once; a native 250 Hz worker evaluates motion and analytic derivatives without
per-sample IPC. See [controller protocol and measurements](CONTROLLER-LAB.md).

The [output-capture audit](OUTPUT-CAPTURE.md) records the Linux virtual-Present stub and
failed fallback capture controls. Driver-direct producer-side output is now verified in
GPU-READBACK.md.

`driver_petplay.driverDirect` separately selects the experimental Linux driver-direct backend
(requires syntheticHmd). It allocates real shared Vulkan images and receives per-eye layer
submissions at 75 Hz without a physical display. External driver-side pixel readback remains unimplemented;
see [direct-mode results, controls and limitations](DIRECT-MODE.md).

The optional `zig build capture-layer` target builds a pure Zig Vulkan diagnostic that reads
SteamVR's composed eye images behind its own GPU fence. Static quad, panorama and projection
controls now pass pixel checks. See [GPU readback](GPU-READBACK.md) for reproduction and limits.

[FRAME-IDENTITY.md](FRAME-IDENTITY.md) documents decoded compositor-output frame IDs,
per-eye delivery checks, and synthetic presenter comparison limits.

[WRIST-SWEEP.md](WRIST-SWEEP.md) describes full-scene wrist rate/phase measurements and the
paired panorama/projection comparison under a VRChat home/desktop workload.
