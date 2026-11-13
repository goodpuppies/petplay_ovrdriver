# Userspace headless display — 2026-11-13

**Desktop SteamVR 2.18.4 can present genuine composed stereo output to a userspace virtual
Vulkan display backed by Mesa's headless swapchain.** No physical headset, forced connector,
DRM lease, root operation, custom Mesa build or compositor binary patch was added by this
prototype. The machine's existing SteamVRLinuxFixes refresh-only configuration remained loaded.

Tested on Linux x86-64, RX 7900 XTX / RADV NAVI31. This is a bounded experimental backend,
not a portable or complete implementation of Vulkan display WSI.

## Mechanism

The opt-in `PP_HEADLESS_DISPLAY=1` mode in `src/capture_layer.zig`:

1. Adds `VK_EXT_headless_surface` to the compositor's instance request. Failure to enable it
   fails instance creation normally; there is no CPU renderer fallback.
2. Exposes one layer-owned display, plane and 1920×1080@75 mode through the Vulkan display
   queries. The properties2 variants preserve the same identity and caller-owned headers.
   Physical displays are hidden from these queries in this scoped compositor process.
3. Accepts acquisition of that virtual display and maps its `vkCreateDisplayPlaneSurfaceKHR`
   to a real `vkCreateHeadlessSurfaceEXT`. The artificial display/mode handles are never
   handed to Mesa's native display-acquisition or mode functions.
4. Reports a fixed surface extent while retaining Mesa's real format/usage capabilities.
   Mesa creates and owns the actual swapchain, GPU images, acquire and present synchronization.
5. Supplies a synthetic vblank counter and clock events. The current event function waits on
   the CPU until the next 75 Hz tick and then creates a real signalled fence. That is **display
   pacing only**, not a claim that rendering has completed. It needs an asynchronous design
   before being used for latency-sensitive streaming.

The synthetic HMD reports a real, non-desktop panel with debug mode disabled. Neither the
DisplayRedirect device nor the legacy compositor sink is enabled. The lab creates a scoped
`redirectsDisplay=false` manifest and restores the original settings/registrations afterward.
The existing driver-direct backend remains a separate choice.

The bounded readback proof consumes `VkPresentInfoKHR::pWaitSemaphores`, copies the actual
presented image and substitutes its own completion semaphore into the real Mesa present.
That is the GPU-completion contract, separate from the synthetic display clock. Its host wait
and raw file output are diagnostic overhead; this is not a zero-copy encoder implementation.

## Results

First, an independent Vulkan client created a native RADV headless surface and verified six
changing color frames, with zero byte mismatches. A second client went through the virtual
display API and verified six full 1920×1080 frames (8,294,400 bytes each), also without mismatches.
It checked properties2 identity/header preservation, zero-capacity enumeration and rejection of
an unsupported display mode. With the headless flag unset, the native 128×64 headless probe
still passed: the optional virtual-display behavior was not enabled.

SteamVR then selected the virtual display:

```
Vulkan output 0: 1920x1080 resolution, 190x100 dimensions - PetPlay headless display
Acquired xlib display!
Direct mode: enabled
Headset is using direct mode
surface=... kind=headless
created swapchain=... /headless 1920x1080 format=44 usage=1b mode=1 minImages=5
present swapchain=... kind=headless 1920x1080 n=2250 ... waits=1
```

Here “direct mode” means the runtime-owned display path, **not** the OpenVR driver-direct
component. Acquisition is handled in userspace; there is no actual Xlib display/DRM lease.

The longer lab window was 35 seconds, including startup and shutdown initiation. Its one
headless swapchain reached 2,250 logged presents, with each 450-present interval taking about
six seconds. A separate platform mirror existed but was not the captured source.

The moving-content control captured twelve frames at presents 450–780, spaced by 30 presents.
An OpenVR overlay moved a red square horizontally for eight seconds and then destroyed it.
The first six captures contained the marker in **both** eyes; its horizontal position changed
by roughly 390 pixels per eye. The next six contained no red marker after overlay removal.
This establishes fresh content across image reuse and a successful removal control. It does
not measure input-to-photon latency, encode cost, frame loss under load or long-run stability.

Artifacts:

- First SteamVR captures: `logs/ovrdriver-lab/present-audit-7wbnmvm9/frames`.
- Moving control: `logs/ovrdriver-lab/present-audit-qb34q76o/frames`.
- Session logs: `logs/ovrdriver-lab/20261113-132022` (check the timestamped directory generated
  by the local run; logs are ignored artifacts).
- Numerical marker analysis: parent `_scratch/headless-motion-results.json`.

## Reproduce

From the driver directory:

```sh
zig build -Doptimize=ReleaseSafe
zig build capture-layer -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

With SteamVR off, from the parent PetPlay repository:

```sh
python3 utils/petplay-ovrdriver-lab.py run --headless-display \
  --present-proof 12 --present-proof-start 450 --present-proof-interval 30 \
  --direct-server --x11-compositor --guard-monitor --seconds 35
```

In a second terminal, once the compositor starts (about four seconds after launching the lab):

```sh
deno run -A utils/petplay-ovrdriver-headless-marker.ts
```

The marker refuses non-synthetic panel settings, owns only its uniquely named overlay, and
destroys it before shutting down its OpenVR client. The output is raw `B8G8R8A8_UNORM`,
1920×1080, side-by-side stereo. `--headless-display` implies the presentation audit and the
`virtual1080` profile. It rejects physical-HMD, driver-direct and incompatible profile options.

## Limits and next work

- Fixed 1080p75, scoped single-instance/device diagnostic layer. Only the exercised subset of
  Vulkan display operations is implemented; it is not a general replacement ICD or display server.
- A desktop/X11 environment is still used by this lab. “No headset” is established;
  “no desktop session or display server” is not.
- The source must next feed a native GPU encoder and a bounded frame ownership/release queue,
  replacing raw CPU readback. Shared-image export is not implemented by this prototype.
- Remote tracking, stereo pose/timestamps, browser decoding and moq transport remain separate work.
- The driver uses symmetric identity distortion. Physical-headset optics are not being simulated.
- SteamVR still logs `Failed WaitEvent(CompositorPresent): bad event=1` during startup, despite
  continuing to present. This needs diagnosis before relying on timing/performance measurements.
- The compositor writes a minidump during bounded lab teardown. In the 35-second run, vrserver
  logged the master monitor disconnect and session quit **before** the compositor dump. The run
  continued past 30 seconds beforehand, so this is not evidence of a 17–18 second rendering limit.
  Shutdown remains unresolved; do not call the lab clean or production-ready.

## References

The implementation was written against the existing layer's dispatch/ledger helpers after
reading the older ALVR display adapter at tag `v20.14.1` (`a9f6542fa507a841f40ab4f3fcb531427cd02550`),
especially `alvr/vulkan_layer/layer/device_api.cpp`, and DroidFrame's headless presentation
adapter. No ALVR source was copied into this implementation. The read-only reference checkout
is under the parent repository's ignored `research/ALVR-headless-reference`.

DroidFrame's headless Vulkan probe was copied to parent `_scratch/` for the independent GPU
checks; those scratch programs are not shipped. Unlike the older ALVR layer, this prototype
delegates actual swapchain allocation/presentation to the installed Mesa driver.
