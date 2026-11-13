# Present-boundary completion contract — 2026-11-13

**A cross-process GPU-completion contract exists at the compositor's `vkQueuePresentKHR`, and
not at the driver-direct handoff.** On this desktop runtime with a physical headset, the
present call carries SteamVR's own render-completion semaphore. A bounded probe copied three
presented frames while waiting on that semaphore, with no guard delay, and substituted its own
completion semaphore into the real present. Driver-direct supplies no equivalent signal; see
[GPU-READBACK.md](GPU-READBACK.md#runtime-allocated-semaphores-are-never-signalled).

Runtime: SteamVR **2.18.4**, Linux x86-64, AMD RX 7900 XTX (RADV NAVI31). This is a newer
compositor than the 2.17.10 build the objdump findings in
[OUTPUT-CAPTURE.md](OUTPUT-CAPTURE.md) and [OUTPUT-DESTINATIONS.md](OUTPUT-DESTINATIONS.md)
were taken against; those addresses are not re-verified here.

## The audit

`src/capture_layer.zig` records presentation structure without touching it. It hooks
`vkCreateDisplayPlaneSurfaceKHR` and `vkCreateHeadlessSurfaceEXT` to classify surfaces,
`vkCreateSwapchainKHR` / `vkGetSwapchainImagesKHR` / `vkDestroySwapchainKHR` for extent,
format, usage, present mode and image handles, and `vkQueuePresentKHR` / `vkAcquireNextImageKHR`
for per-swapchain present counts, wait-semaphore counts and non-success results. Ledgers are
fixed-size, no files are written and present logging is rate-limited after the first three.

### Physical headset

```
surface=...2560 kind=display
created swapchain=...2ca0 surface=...2560/display  5088x2544 format=44 usage=1a mode=2 minImages=3
created swapchain=...80b0 surface=...28c0/platform 5088x2544 format=44 usage=1a mode=0 minImages=4
present swapchain=...2ca0 kind=display n=900 imageIndex=0 waits=1 chains=1 queue=...0580 family=1
```

- The headset output is a real `VK_KHR_display` swapchain: DRM-leased plane, FIFO, three images,
  5088×2544 `B8G8R8A8_UNORM` (format 44), one presenting queue in family 1.
- **Every present carries exactly one wait semaphore.** 450 presents in 6 s, a steady 75 Hz.
- Two swapchains exist; **all presents went to the display one and none to the X11 mirror**. The
  unidentified 1280×720 image in OUTPUT-CAPTURE.md's Mesa screenshot experiment was a mirror
  swapchain, not a resolved eye target.
- `usage=1a` is `TRANSFER_DST | STORAGE | COLOR_ATTACHMENT`. **`TRANSFER_SRC` and `SAMPLED` are
  absent**, so a presented image cannot be copied or sampled as created.

### Synthetic headset, display-debug backend

```
Forcing debug mode for petplay driver because of Prop_DisplayDebugMode_Bool.
created swapchain=...8f20 surface=.../platform 1280x720 ... mode=0 minImages=4 old=...9b80
present  swapchain=...8f20 kind=platform 1280x720 n=1 imageIndex=0 waits=1
present  swapchain=...8f20 kind=platform 1280x720 n=2 imageIndex=1 waits=1
created swapchain=...57a0 surface=.../platform 1280x720 ... old=...8f20
```

With `displayDebug` the compositor creates **no eye-target swapchain at all** — only a 1280×720
mirror, which it destroys and recreates after every two presents, logging `Mirror swapchain
mode:0 format:44 colorspace:0 count:4` each time (637 occurrences in one session).

The recreation is **not** driven by a Vulkan error: the hooks logged no non-success result from
either `vkAcquireNextImageKHR` or `vkQueuePresentKHR`, and `oldSwapchain` is passed correctly
each time. The compositor rebuilds voluntarily. The cause is not established here. This is the
mechanism behind the earlier "desktop profile's frequency fell to zero" symptom.

## The proof

Armed only by `PP_SEMAPHORE_WATCH_PRESENTS`'s sibling `PP_PRESENT_PROOF_FRAMES` and bounded to
16 frames. For a single-swapchain present on a `display` surface it:

1. Adds `VK_IMAGE_USAGE_TRANSFER_SRC_BIT` to `vkCreateSwapchainKHR`, after confirming
   `VkSurfaceCapabilitiesKHR::supportedUsageFlags` allows it. The surface accepted it
   (`usage 1a -> 1b`) and the session continued normally. The plain audit never alters the
   compositor's request.
2. Submits a copy of the presented image on the presenting queue's family, **waiting on
   `VkPresentInfoKHR::pWaitSemaphores`** — the compositor's own render-completion semaphore.
3. Signals its own completion semaphore and rewrites the present's wait list to that semaphore,
   so the real present cannot recycle the source image before the copy finishes.
4. Retires that one diagnostic frame on a fence and writes raw pixels. The CPU wait retires the
   bounded capture; it is not part of the contract.

```
proof adds TRANSFER_SRC: usage 1a -> 1b
present proof wrote present-1-0.rgba 5088x2544 format=44 bytes=51775488 renderWaits=1 guardDelayMs=0
present proof wrote present-2-1.rgba ... renderWaits=1 guardDelayMs=0
present proof wrote present-3-0.rgba ... renderWaits=1 guardDelayMs=0
```

| frame | non-black | left mean | right mean | L/R absdiff | blank rows |
| --- | --- | --- | --- | --- | --- |
| 1 | 0.00% | 0.00 | 0.00 | 0.00 | 2544 |
| 2 | 93.25% | 81.69 | 80.98 | 3.12 | 0 |
| 3 | 93.25% | 81.69 | 80.98 | 3.12 | 0 |

Frames 2 and 3 are the composited stereo output: both eye masks over the compositor's idle
field, zero blank rows, a small left/right difference at the mask edges. Frame 1 is the first
present, before anything had rendered.

`guardDelayMs=0` is the point of comparison. `src/direct_reader.zig` must wait for the next
Present and then sleep 4 ms, and its own documentation says a torn or early image is possible.

### What the proof does not establish

Frames 2 and 3 are **pixel-identical** (`maxdiff=0`). The session was an idle compositor with no
scene application and the dashboard hidden, so the content is genuinely static and cannot
distinguish a correctly fresh copy from a stale buffer. What is established is that the copy is
**complete and correctly ordered**: full mask coverage, no untouched band, correct stereo
structure. Temporal freshness needs a moving source and has not been measured. It also has not
been measured with a scene application running, where additional composited layers could change
the wait-semaphore count.

51,775,488 bytes per frame at 75 Hz is 3.9 GB/s. The host copy is a diagnostic. Any real
consumer belongs on the GPU at this same boundary.

## Consequence: the two routes are alternatives

Driver-direct exists to bypass WSI, so it has no swapchain and no present boundary. Present
interception requires one. A session cannot use both.

| route | present boundary | completion signal |
| --- | --- | --- |
| Driver-direct (`IVRDriverDirectModeComponent`) | none by design | none available; see GPU-READBACK.md |
| `IVRVirtualDisplay` / DisplayRedirect | n/a | `PresentInfo_t` has no sync field at all |
| `displayDebug` mirror window | mirror only, 1280×720, recreated every 2 presents | semaphore present but unusable output |
| **Physical headset display swapchain** | **yes** | **real render semaphore, zero guard** |

Present interception needs no PetPlay driver at all: the layer sits in `vrcompositor` and
intercepts whichever HMD driver is presenting. The capture above ran with `syntheticHmd=false`
and `driverDirect=false`, with the physical headset supplying display and tracking and the
PetPlay driver registered only as a synthetic controller provider.

This makes the two intended uses need different mechanisms. Streaming a real session's composed
view can use the present boundary today. A machine with no headset attached cannot, until
SteamVR is given something to present to — a virtual DRM display is the untested candidate, and
`VK_EXT_headless_surface` is supported by this driver but has no established SteamVR backend.

## Reproduce

Build, with SteamVR off:

```sh
cd submodules/petplay_ovrdriver && zig build capture-layer -Doptimize=ReleaseSafe
```

Audit a physical-headset session, and optionally capture frames:

```sh
python3 utils/petplay-ovrdriver-lab.py run --real-hmd --present-audit \
  --direct-server --x11-compositor --seconds 45
python3 utils/petplay-ovrdriver-lab.py run --real-hmd --present-audit --present-proof 3 \
  --direct-server --x11-compositor --seconds 45
python3 _scratch/present-proof-check.py logs/ovrdriver-lab/present-audit-*/frames
```

`--present-audit` creates the layer manifest with no capture directory, so the request-driven
readback path stays unarmed and the layer only records structure. `--present-proof N` adds the
frames directory and arms the bounded copy. The audit is the one real-HMD mode allowed to use
`--direct-server`, because `steam.sh -applaunch` hands off to a running Steam client and the
layer environment never reaches `vrserver`.

## Harness limitation

`--direct-server --x11-compositor` sessions **intermittently** abort the compositor around 17–18 s,
with a breakpad minidump. A control session with the layer disabled through the loader's
`disable_environment` crashed at the same point, so this is not caused by the layer. One session
ran 300+ presents with no crash, so it is not deterministic either. It did not affect the
measurements above, which complete inside that window, but it needs resolving before this is a
dependable harness on 2.18.4.
