# Where SteamVR can send images — 2026-10-16

The desktop window is not the only architectural option. Distinguish who composites the
layers from who owns the final display/texture. Our research needs SteamVR's overlay
composition to remain in the measured path.

| Route | Who owns composition/output? | Relevance and current evidence |
| --- | --- | --- |
| Runtime direct display | SteamVR composites and presents to a DRM-leased display | Normal physical-HMD route. A real headset is unnecessary in principle if an acceptable virtual connector can be supplied, but that compatibility is unproven. |
| Desktop/extended/debug window | SteamVR composites and presents to a desktop surface | Existing fallback test. It has not produced a validated marker image; desktop profile's frequency fell to zero. |
| `IVRVirtualDisplay` / DisplayRedirect | SteamVR composites; plugin receives final backbuffer | Ideal public handoff, but selected Linux Present branch is a stub. Timing works independently. See OUTPUT-CAPTURE.md. |
| `IVRDriverDirectModeComponent` | Driver supplies swap textures and receives submitted layers | Current ALVR upstream implements this on Linux through public shared-image allocation. Our runtime and overlay handoff are still unverified; see the source audit below. |
| Virtual Vulkan display / WSI layer | SteamVR renders into an emulated display swapchain | ALVR's older implementation provides a concrete Linux reference without a kernel virtual monitor. Larger interception surface, including display timing and swapchain ownership. |
| Headless Vulkan surface | Runtime would need to explicitly select and use it | Vulkan function lookup exists, but no usable SteamVR headless backend has been established. Merely advertising the extension does not activate one. |
| Vulkan attachment capture | SteamVR keeps composing; a diagnostic intercepts the actual GPU image | A measurement point rather than an output destination. Can preserve the behavior of interest if the underlying synthetic renderer works. Capture instrumentation currently fails; not implemented as a custom layer. |

## Public driver API distinction

Valve's [device-component documentation](https://github.com/ValveSoftware/openvr/blob/master/docs/Driver_API_Documentation.md#device-components)
separates runtime-owned display output, driver-owned pre-composition layers, and final-backbuffer
redirection. Driver direct mode does **not** mean the same thing as SteamVR presenting directly
to a physical display. Do not conflate `IVRDriverDirectModeComponent::Present(syncTexture)` with
`IVRVirtualDisplay::Present(PresentInfo_t*, size)`.

Driver direct mode requests driver-owned swap texture sets and passes per-eye texture handles,
bounds, projection, render pose and prediction time to SubmitLayer. That could be useful for
a general programmable driver, but we need to determine which overlay work SteamVR has already
performed at the handoff before adopting it for this investigation. See [Valve's direct-mode
notes](https://github.com/ValveSoftware/openvr/wiki/Driver-direct-mode).

## Static anchors in our Linux build

Same vrcompositor BuildID as OUTPUT-CAPTURE.md. ELF virtual addresses:

- `0x191b30` tests compositor `+0x48`; the nonnull path logs “Headset is using driver direct
  mode” at `0x191b37` and continues initialization. This is an alternative branch, not proof
  of an operational public custom-driver integration.
- `0x1b6023` also checks `+0x48`; `0x1b602e` enters the Driver Direct SubmitLayer-labelled
  section. Unlike the virtual Present stub, this section contains texture/pose work and
  downstream calls. `0x1b6534` invokes renderer vtable `+0x78`, immediately before the end
  label at `0x1b6537`. The exact contract and downstream callback target still need tracing;
  the binary also contains an OpenXR direct-mode bridge, so labels alone do not prove these
  are calls to the public OpenVR driver interface.
- `0x2a6ca6` looks up `vkCreateHeadlessSurfaceEXT`; the returned pointer is stored at
  `0x4e19d0` by `0x2a6cc3`. The complete objdump has no other direct reference to that storage.
  This looks like a generic Vulkan dispatch-loader entry, not evidence of a selected headless
  presentation path. Indirect table access has not been ruled out.

No runtime launch or machine setting changes were needed for this audit.

## Virtual DRM/KMS display possibility

Linux has [VKMS](https://docs.kernel.org/gpu/vkms.html), a software virtual modesetting driver
with synthetic vblank and writeback support. This machine has a matching loadable module at
`/usr/lib/modules/7.2.6-1-cachyos/kernel/drivers/gpu/drm/vkms/vkms.ko.zst`. It was **not loaded**.

This is another potential destination, not a ready solution. VKMS is a different DRM device
from the AMD rendering GPU. SteamVR/RADV must support the relevant display acquisition and
buffer-sharing path; supplying a virtual connector alone does not prove that. It is not
established that we can lease that connector through the desktop compositor, drive it with
SteamVR's Vulkan physical device, or obtain a comparable 75 Hz presentation pipeline. A
same-GPU dummy connector/display is a separate hardware/driver configuration possibility,
not something the OpenVR Zig driver can simply declare into existence.

## ALVR source audit: two concrete Linux implementations

Read-only audit on 2026-10-16. No ALVR code was installed or executed, and SteamVR stayed
off. Pin these references: upstream `master` and its architecture have changed recently.

### Current upstream: public driver-direct mode

ALVR [merged its Linux driver-direct implementation on 2026-10-04](https://github.com/alvr-org/ALVR/pull/3398),
removing its Vulkan layer and DRM shim. The PR reports Linux testing with Nvidia/Quest 3;
this is upstream evidence, not a successful test of our AMD machine or synthetic driver.
Audited tree: `ebec107b7e5f81677fb9c631d239daf2110bf573`.

Its [Linux direct-mode implementation](https://github.com/alvr-org/ALVR/blob/ebec107b7e5f81677fb9c631d239daf2110bf573/alvr/server_openvr/cpp/platform/linux/OvrDirectModeComponent.cpp):

- Allocates three images per texture set using `VRIPCResourceManager()->NewSharedVulkanImage`.
- Returns real shared handles to SteamVR, obtains image FDs through `RefResource` and
  `ReceiveSharedFd`, and imports duplicates into its own Vulkan renderer.
- Receives per-eye handles, bounds and render pose in `SubmitLayer`, then processes images
  from the first submitted layer in `Present`. There is an explicit unfinished layer-merging
  comment. This does **not** establish that SteamVR's panorama overlay is absent, included
  in layer zero, or submitted separately: that needs a marker experiment on our runtime.
- Has explicit producer-synchronization concerns: writer-fence export, a bounded poll and
  a guard delay. Those are upstream implementation choices, not proven synchronization
  guarantees or a pacing prescription for PetPlay.

The [HMD component selection](https://github.com/alvr-org/ALVR/blob/ebec107b7e5f81677fb9c631d239daf2110bf573/alvr/server_openvr/cpp/alvr_server/HMD.cpp)
returns `IVRDriverDirectModeComponent` on Linux. The OpenVR submodule is commit
`0924064316de3effbcd1acf1e309182a2deb1c05`, the **same SDK commit we already vendor**.
`IVRIPCResourceManagerClient_003` and its Linux FD methods are therefore available in our
existing header; no private binary address is needed for that allocation contract.

ALVR also owns its vsync announcement and PostPresent pacing; see its
[vsync implementation](https://github.com/alvr-org/ALVR/blob/ebec107b7e5f81677fb9c631d239daf2110bf573/alvr/server_openvr/src/vsync.rs).
A synthetic backend must supply a consistent clock and buffer-reuse policy. Receiving a
callback alone is not a correct display implementation.

### Older implementation: emulate the Vulkan display itself

At tag `v20.14.1`, tree `a9f6542fa507a841f40ab4f3fcb531427cd02550`, ALVR instead had:

- A [DRM/Wayland lease shim](https://github.com/alvr-org/ALVR/blob/a9f6542fa507a841f40ab4f3fcb531427cd02550/alvr/vrcompositor_wrapper/drm-lease-shim.cpp)
  that supplies fake lease-protocol objects and modified connector information, backed by
  an opened real DRM card. This is userspace emulation, not loading VKMS or adding a physical
  connector. It still has desktop/DRM dependencies; it is not proof of display-server-free use.
- A custom Vulkan WSI implementation with synthetic vblank. Its
  [headless swapchain](https://github.com/alvr-org/ALVR/blob/a9f6542fa507a841f40ab4f3fcb531427cd02550/alvr/vulkan_layer/wsi/headless/swapchain.cpp)
  allocates GPU images, exports opaque memory and timeline-semaphore FDs over a Unix socket,
  and sends image index, frame counter, semaphore value and pose per submission.

This demonstrates an architecture in which SteamVR can render to a userspace virtual
destination without copying full images through an actor's JSON messages. It is a much
larger Vulkan compatibility project than implementing the OpenVR component. In particular,
[a later upstream fix](https://github.com/alvr-org/ALVR/commit/d350c7c26e944af5e74b7f1ca65ae940ed3f4869)
was needed when SteamVR 2.17.7 started using `vkWaitForPresentKHR`; the older tag should not
be treated as a drop-in implementation for our 2.17.10 runtime.

## Fit and next discriminating experiment

**Implementation follow-up:** the real-buffer Zig diagnostic and marker-metadata stages now
work on this machine; see [DIRECT-MODE.md](DIRECT-MODE.md). Pixel inclusion remains unverified.

For the general PetPlay driver, direct mode is now the first candidate: it fits the existing
pure-Zig ABI approach and public resource-manager contract. For the panorama jitter research,
the choice depends on preserving SteamVR's relevant composition. Do not choose merely because
one route can produce an image.

Build an opt-in, bounded driver-direct diagnostic in stages:

1. Add ABI fixture coverage for the direct-mode component and resource-manager methods.
   Implement real allocation and balanced cleanup, with callback/set/layer counters. Do not
   return fabricated handles from allocation callbacks. Keep the existing redirect backend
   selectable and mutually exclusive with this one.
2. Start a short synthetic-only session without RenderDoc or screenshot layers. Verify
   nonzero stable display frequency, real texture allocation, SubmitLayer/Present activity,
   layer counts and shutdown cleanup. Establish resource availability after initialization;
   the SDK explicitly notes that the resource manager initializes asynchronously.
3. Read back one completed image with correct producer synchronization and bounded buffer
   ownership. First require a known scene marker; then independently publish a quad marker
   and a panorama marker and inspect **every submitted layer**, including overlay-only and
   scene-app sessions. Record bounds/pose alongside each image. A handle or callback counter
   is not an image-content positive control.
4. If SteamVR supplies the composed panorama image, use it for automated synthetic-controller
   image measurements. If it leaves the relevant overlay work to our driver, do not recreate
   that composition and call it a reproduction of SteamVR's behavior. Evaluate virtual WSI
   next, or capture the compositor's own eye target under a working display backend.

The actor remains the control/metadata plane. GPU images stay in a native backend, shared
with a dedicated reader via FDs and synchronization if necessary; send small measurements or
occasional diagnostic readbacks to PetPlay. Desktop preview, file capture and encoder output
can be consumers of that backend rather than mutually exclusive display destinations.

## Remaining binary audit

First audit driver-direct initialization, buffer import and SubmitLayer/Present adapters;
then a diagnostic interface can log whether actual callbacks occur, without pretending
empty texture handles implement a working display. We must also identify whether the handoff
contains SteamVR-composited overlays or leaves them to the driver. A pre-composition handoff
might be useful infrastructure while being unsuitable evidence for the panorama bug.

In parallel, map the runtime-owned offscreen eye target to the real Vulkan queue submission.
Headless/offscreen rendering does not require a desktop window in principle, but SteamVR must
still implement a complete selection, synchronization and output path for it. The OpenVR
header alone cannot supply that missing backend.
