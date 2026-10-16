# Output-capture audit — 2026-10-16

**Follow-up:** fenced producer-side readback now verifies quad, panorama and projection pixels
in the actual driver buffers. See [GPU-READBACK.md](GPU-READBACK.md). The original cross-process
completion and teardown ownership limitations still apply.

Initial fallback status: **no validated final-image capture through that backend**.
The later driver-direct producer capture works; see GPU-READBACK.md. The controller
and 75 Hz frame-sync results remain measurements of tracking/public API behavior. They must
not be presented as proof that the synthetic fallback rendered correct overlay images.

## Virtual-display delivery is a stub in the selected Linux binary

Runtime: SteamVR 2.17.10, vrcompositor ELF BuildID
`f5c560dcaa16d7b2625ece684b02396505e0768f`. Addresses below are ELF virtual addresses, not
file offsets; .text file offsets are these addresses minus 0x1000 for this binary.

The render path at `0x190d90` tests compositor `+0x50` and enters the branch labelled
`DoVirtualDisplayPresent` at `0x190d9b`. Its complete relevant body is:

- `0x190d9b`: call `0x2be380`, obtain current debug-scope state.
- `0x190da0..0x190dae`: select string at `0x11f070`, call scope setter `0x2be340`.
- `0x190db3..0x190dba`: restore previous scope through `0x2be340`.
- `0x190dbf`: clear byte at compositor `+0x255c2`.
- `0x190dc7`: jump back to `0x190bd5`.

There is no texture acquisition, indirect plugin call, Present, or WaitForPresent call in
this branch. This explains why implementing those public plugin callbacks did not deliver
an image on this selected path. The timing path is separate: it calls WaitForPresent and
GetTimeSinceLastVsync at `0x2853cc/0x2853f5` only when it enters that timing branch; observed
virtual timing queries do not establish the image-delivery branch is implemented.

Read-only objdump confirmed this. No compositor binary was patched. This finding is scoped
to the selected build/path, not every Linux runtime or driver backend.

## Capture experiments

### Mesa screenshot layer

The machine already has `VK_LAYER_MESA_screenshot`. A per-launch X11 compositor environment
enabled it and requested twenty spaced captures. The layer produced `150.png` and `225.png`,
both 1280×720 black images, then logged `VK_ERROR_DEVICE_LOST`; the driver log reported a
GPU hard recovery. The session was stopped and its original configuration restored.

These images are **failed controls**, not proof of a black overlay or of what the compositor
consumed. They were captured from a presentation swapchain, which has not been identified as
the correct resolved eye target. The first marker invocation also had the wrong diagnostic
HMD-pose option; later attempts used `PP_GPU_POSE_CURRENT=1`. The screenshots therefore cannot
serve as the required visible-marker positive control on either ground.

The screenshot option was removed from the reusable launcher. Source/config reference:
[Mesa screenshot layer README](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/vulkan/screenshot-layer/README.rst).

### RenderDoc

RenderDoc 1.46 was downloaded from renderdoc.org's versioned official Linux tarball and
unpacked under ignored `logs/ovrdriver-lab/renderdoc/`. It reports commit
`e4bd23b671d3d5a747ff5221dbe08a63eb6ca200`. Matching replay headers came from the upstream
v1.46 source tag. No system installation or global layer registration was performed.

The earlier repository helpers compiled against it. A private manifest with an absolute
library path was enabled only for the X11 compositor launch, retaining the existing implicit
layers. Target control connected to the intended executable and initially reported supported
presenting Vulkan. The compositor then reported timeline/submission failure and device loss;
API status changed to not presenting. No fresh acknowledged `.rdc` capture was obtained.
The log also contains an unrecognized pNext sType `1000109099`; its role in the failure is
unproven, so it is not identified as the cause.

Controls tried:

- Separate synthetic desktop-output profile instead of the fictional display/redirect clock.
- Direct vrserver startup under vrenv, followed by X11 compositor, avoiding the initial
  Wayland assertion and the startup overlay/dashboard graph.
- Linux asynchronous reprojection disabled for the session.
- Existing SteamVR fixes layer disabled for that compositor launch only.

None yielded a valid capture. A desktop-output **uninstrumented** control started without
the observed device-loss loop, but compositor frequency became 0 Hz. Its public-mirror probe
did not finish before session shutdown, so it establishes no public mirror success/failure.
The exploratory native desktop profile was removed instead of becoming another default.
Async/fixes overrides remain explicit diagnostic launcher options, never global changes.

## Launcher improvements

`utils/petplay-ovrdriver-lab.py` still backs up and restores exact settings/registration bytes.
It now also:

- Can launch vrserver directly (`--direct-server --x11-compositor`) without first running a
  Wayland compositor or auto-starting dashboard/overlay apps through the usual launch flags.
  Steam and other clients may still attach; this is not total process/workload isolation.
- Supports a private `--renderdoc-layer <directory>` on that X11 launch only.
- Detects newly logged device-loss/timeline failures and stops the lab instead of continuing
  to report timing from an invalid render session. Historical errors are ignored.
- Explicitly terminates the compositor during cleanup, including diagnostic sessions with
  its watchdog disabled; defunct children are not mistaken for live device owners.
- Ignores additional SIGINT/SIGTERM during cleanup so a second interrupt does not cut off
  settings restoration. Forced process death still requires explicit recovery.

These capture switches are experimental reproduction aids, not a working output-capture recipe.
Private library files, logs and failed images remain in ignored local storage. The existing
working driver/controller implementation is unchanged by the removed desktop experiment.

For the wider set of alternatives, see [output destinations](OUTPUT-DESTINATIONS.md).

## Next useful investigation

The subsequent [output-destination audit](OUTPUT-DESTINATIONS.md#alvr-source-audit-two-concrete-linux-implementations)
found a current upstream ALVR implementation of Linux driver-direct mode using the same
public OpenVR SDK revision we vendor. A bounded real-buffer/overlay-marker test of that
backend is now the first candidate before building a custom Vulkan interception layer.
Its ability to preserve the panorama composition under investigation remains unverified.

Do not use virtual Present as the capture hook on this binary. Follow the compositor's actual
Vulkan eye-target draw/resolve and submission path, and establish a visible marker there.
The earlier [real-runtime GPU captures](../../../markdown/projection-overlay-re/clean-gpu-capture.md)
proved this kind of measurement on a physical-display session, but that does not prove the
synthetic fallback selects the same path.

Before attempting continuous capture, require a single fresh GPU capture that shows the marker
in the resolved eye attachment, with a successful replay/readback completion and no device loss.
If that cannot be made to work through the fallback backend, investigate a tightly scoped Vulkan
layer that observes the actual eye attachment/submission rather than desktop swapchain pixels,
or a runtime backend that supports synthetic output correctly. Neither route is implemented yet.
Only after that positive control should we compare panorama/projection controller placement and
frame-generation markers. Instrumented timings cannot establish production present phases.
