# Fenced compositor image readback — 2026-10-16

**SteamVR's driver-direct images include quad, stereo-panorama and projection overlays on
this Linux runtime.** A pure Zig diagnostic Vulkan layer captured those real buffers and a
pixel analyzer verified all five static controls. This establishes image-content measurement
without a physical HMD. It does not yet reproduce controller jitter or establish production
pacing, atomic pose/texture publication, or a public cross-process GPU-completion contract.

## Why the driver could not simply wait on its image FD

`Present` receives syncTexture zero. Static inspection of this compositor build confirms it is
intentional: `0x190bc9` calls the driver-present helper `0x17cd30`, which clears its sync argument
at `0x17cd5b` before calling the internal direct-mode adapter at `0x17cd63`. See
[OUTPUT-CAPTURE.md](OUTPUT-CAPTURE.md) for the exact runtime BuildID/address conventions.

The opt-in `PROBEDIRECTFENCES` actor request samples the next 64 Present callbacks. It exports
writer sync_files with `DMA_BUF_IOCTL_EXPORT_SYNC_FILE`, then inspects `SYNC_IOC_FILE_INFO`.
It does not wait or introduce a GPU consumer. Across 600 eye samples in the five-stage test,
all exports succeeded, none was active, and every snapshot contained the same already-signaled
`signaled-timeline` / `detached-driver` fence with timestamp `475555733` ns. It did not advance
while SteamVR rendered the markers. This fence cannot establish completion of current writes.
The native declarations are layout-checked against this machine's Linux UAPI headers in the
existing offline C++ fixture.

The kernel's [dma-buf documentation](https://docs.kernel.org/driver-api/dma-buf.html)
describes reservation-fence interoperation; explicit Vulkan use does not make an unrelated
already-signaled reservation fence into a completion event. ALVR's current Linux implementation
also contains synchronization workarounds. Those were a useful warning, not a contract to copy.

## The measurement point that works

The optional `src/capture_layer.zig` runs **inside vrcompositor's Vulkan call chain**:

1. Track candidate 960×960, single-sample, one-mip RGBA/BGRA images and their memory bindings.
   At `vkGetMemoryFdKHR`, record the exported dma-buf inode. Native GETDIRECTSTATE also exposes
   the inodes of the last submitted eye handles. This ties captures to driver-owned images;
   a matching resolution alone would be insufficient.
2. Track command-buffer image barriers (including synchronization2) and render-pass final
   attachment layouts through render passes, framebuffers and image views. The working buffers
   finish in COLOR_ATTACHMENT_OPTIMAL (layout 2). The initial implementation, which did not
   track implicit render-pass transitions, conservatively skipped them rather than guessing.
3. After a successful producer QueueSubmit/QueueSubmit2, capture only exported images touched
   in that submission. Queue a transfer on **the same producer queue**, with image access/layout
   barriers, copy to host-coherent memory, then restore the original layout. Wait on the
   transfer's own Vulkan fence before mapping and writing pixels.
4. Write PPMs and a `.complete` record with image indices, inodes, real formats and layouts.
   The record is written after image output succeeds. Existing output files are never replaced.

This is an ordinary GPU readback in the producer context. It does not use WaitFrameSync,
mirror access, an elapsed safe-window delay, or the detached dma-buf fence as GPU completion.
See the Vulkan [synchronization specification](https://docs.vulkan.org/spec/latest/chapters/synchronization.html).
No compositor binary addresses are called or patched by the layer.

The actual exported VkImages in this run have format **37 (R8G8B8A8_UNORM)** and usage `0x9f`,
although OpenVR requested format 43 in CreateSwapTextureSet. Do not assume that the driver's
requested descriptor is an exact description of a separately importable VkImage. This reader
uses the real Vulkan creation parameters and avoids recreating the external image altogether.

## Repeat the controls

Build from the driver submodule with SteamVR off:

```sh
zig build capture-layer test install -Doptimize=ReleaseSafe
```

From PetPlay:

```sh
python3 utils/petplay-ovrdriver-lab.py run --driver-direct --direct-server --x11-compositor --capture-layer --seconds 45
```

The launcher prints a new private capture directory and writes its path into ignored
`logs/ovrdriver-lab/latest-native-capture.json`. Shortly after startup, use that directory:

```sh
deno run -A utils/petplay-ovrdriver-lab-probe.ts --direct-markers --capture-dir=/absolute/printed/path > logs/ovrdriver-lab/my-capture.ndjson
python3 utils/petplay-ovrdriver-capture-analyze.py /absolute/printed/path --probe-log logs/ovrdriver-lab/my-capture.ndjson
```

The guarded probe first verifies the synthetic HMD serial. It creates three opaque colored
textures with public SetOverlayRaw, hides all for baseline, then shows each individually and
all together. Each stage settles for 60 frame-sync wakes before requesting a capture. The
panorama uses the same one-metre-forward HMD-relative transform as PetPlay's existing wrapper;
an initial zero-distance marker produced no green pixels and was a failed geometry control.
Projection deliberately targets only Eye_Left. Marker overlays are destroyed in finally.

The layer manifest is private to the launch; it is not installed in a global Vulkan directory.
Only the compositor receives its enable flag and manifest path. It preserves other existing
layers and excludes simultaneous RenderDoc instrumentation. The launcher retains exact-byte
settings/registration backup and restoration, terminates the runtime afterward, and stops on
new device-loss, timeline, or diagnostic Vulkan failures. The physical HMD is not activated.

## Verified pixels

Both captured eye images are 960×960. In the first complete five-stage run:

| Stage | First captured eye | Second captured eye |
| --- | --- | --- |
| Hidden baseline | No red/green/blue marker pixels | No marker pixels |
| Quad | 41,345 red pixels | 41,344 red pixels |
| Stereo panorama | 921,600 green pixels | 921,600 green pixels |
| Projection, Eye_Left only | 890,110 blue pixels | No blue marker pixels |
| All three | Red, green and blue markers | Red and green markers |

Colors are measured with a dominant-channel threshold (>200, other channels <20). The analyzer
checks both image byte counts and completion records, requires two completed images without
skips/failures, matches recorded inodes against native driver snapshots in the guarded probe
log, and validates the stage-specific marker conditions. It also reports pixel centroids for
subsequent trajectory experiments. These controls demonstrate image inclusion, not atomic
pose/texture state or moving-marker fidelity.

Evidence remains in ignored local storage:

- `logs/ovrdriver-lab/direct-fences-20261016.ndjson`
- `logs/ovrdriver-lab/native-capture-5wyacczq/images/`
- `logs/ovrdriver-lab/direct-native-capture-controls-20261016.ndjson`
- `logs/ovrdriver-lab/direct-native-capture-controls-analysis.json`
- Repeat: `native-capture-ygrr83z6/images/`, `direct-native-capture-final-20261016.ndjson`
  and `direct-native-capture-final-analysis.json` under the same lab directory. All five pixel
  controls passed again, with identical marker counts.

## Limits and next experiment

The static PPM request deliberately stalls queue submission for GPU completion and disk readback.
It is a static diagnostic, not a low-overhead frame recorder. The separate bounded asynchronous
marker path is documented in [MOTION-IMAGES.md](MOTION-IMAGES.md). Do not use these capture timings as
production pacing measurements. Early capture of all six ring images was unnecessarily slow;
the current layer reads only the pair touched in the selected submission. Capture mode uses
a 1 s per-wake diagnostic timeout to tolerate these deliberate stalls.

The layer is deliberately narrow: one Vulkan instance/device, the current fixed eye resolution,
bounded object ledgers and ordinary tracked render passes. Unknown layouts, external ownership,
unsupported render-pass metadata, secondary command buffers and dynamic rendering are not
silently inferred. Unsupported paths skip or disable capture. On a GPU fence timeout, it keeps
the bounded in-flight resources until process teardown instead of freeing resources the GPU
may still be using. The layer has offline null-pointer/zero-count and render-pass layout tests,
plus live loader and image-content checks; it is not a general Vulkan capture tool.

The native driver's shutdown reference issue from DIRECT-MODE.md remains unresolved. This
capture neither supplies a public completion fence to an external live reader nor establishes
balanced resource references after compositor disconnect. Linux driver-direct mode also disables
SteamVR's async reprojection path, so reproducing a physical-HMD mechanism still needs comparison.

The controller-following marker and bounded asynchronous ring are now implemented and measured.
See [MOTION-IMAGES.md](MOTION-IMAGES.md) for smooth and deliberately choppy controls, reproduction
commands, overhead checks, limits, and the remaining PetPlay panorama/projection comparison.
