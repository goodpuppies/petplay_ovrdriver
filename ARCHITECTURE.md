# Native driver and Stageforge actor boundary

## Ownership and identity

SteamVR loads the driver inside vrserver. PetPlay attaches a **proxy to an existing actor**;
it does not spawn, initialize or own that actor or process. The driver generates its actor
identity once per successful provider Init. Its Unix socket announces that identity before
accepting addressed Stageforge messages. Attaching sends no INIT and expects no LOADED.
An INIT received through the live endpoint is rejected. A driver reinitialization produces a
new actor incarnation; reconnecting during the same initialization preserves identity/state.

Stageforge's attachProxy registers a Worker-shaped connection under the existing actor ID.
Normal PostMan addressing and TYPE:callback-id replies work through it. detachProxy, proxy
murder and graph reboot close only the local connection; none sends SHUTDOWN to the driver.
Generic reload refuses external actors and asks the caller to detach/reattach explicitly.
Process lifetime, driver cleanup and explicit device-control commands are separate concerns.

The old standalone actor host remains a creation-protocol control: it does use INIT/LOADED
and owns its own process. It is not the live connection model. Health distinguishes it from
the vrserver-owned driver instance.

## Implemented native path

- Pure Zig C factory and explicit Linux x86-64 C++ ABI provider/device interface objects.
- Runtime context/host lookup, driver handle, lifecycle, standby and RunFrame counters.
- No devices by default. Explicit synthetic mode registers an HMD and display redirect;
  the separate ABI-probe device still deliberately fails activation.
- Versioned native Stageforge JSON envelopes, callbacks, dispatch errors, bounded 16 KiB packets,
  per-request allocator arenas, and Unicode/BigInt-tag roundtrips. No JS evaluator in the driver.
- A private Unix-domain stream socket at `/run/user/<uid>/petplay_ovrdriver/control.sock`.
  Directory must be owned by the current effective user with mode 0700; socket mode is 0600;
  accepted peer credentials must match the effective UID. There is no TCP listener.
- An exclusive owner.lock prevents another provider from replacing an active socket. Stale
  socket recovery happens only under that lock, after checking the entry's type and owner.
  Insecure directories/lock files and unexpected existing socket-path entries are refused.
- Listener/connection work runs on a dedicated pthread-backed Zig thread. Nonblocking I/O,
  bounded packets and write deadlines keep clients away from RunFrame. Cleanup stops and joins
  the thread before releasing the runtime context, then removes the socket and releases locks.
- Failed IPC startup is reported in driver health state and does not fail provider Init or
  require PetPlay to be online. Device work will need its own bounded command queue later.
- NativeUnixProxy connects to the advertised identity, carries ordinary Stageforge messages,
  enforces packet/backpressure limits, and rejects pending requests when the connection ends.
  terminate closes its connection only; it sends no remote termination/lifecycle command.
- `attachOpenVrDriverProxy(postal, path?)` performs identity discovery and imports the existing
  actor into the router. It does not start SteamVR or register a driver.

Disconnect leaves the driver actor alive. A later explicit connection gets the same identity;
there is no automatic reconnect behind an intentional detach. One control connection is served
at a time. Multi-client control, topic discovery/advertising and automatic PetPlay attachment
are not implemented. The live transport is newline-delimited JSON, not WebSocket framing;
it reuses the existing Stageforge WebSocketWorker codec's logical packet format.

## Verified without physical hardware

The official-header C++ consumer tests C++ → Zig provider/device calls, Zig → C++ context/host
calls, scalar/pointer arguments, DriverPose_t size/alignment/selected offsets and struct return,
and lifecycle behavior. C++ exists only in this offline test host, never in the driver library.

The same test host can keep the actual shared library initialized while the real Stageforge
router attaches via Unix IPC. Tests cover no-INIT proxy attach, health from the loaded instance,
codec roundtrip, stable identity/state after detach/reattach, pending callback rejection,
prompt Cleanup while connected, owner-lock contention, endpoint removal and insecure-directory
refusal. Separate tests cover the creation protocol and malformed/oversized stream recovery.
The live driver has also been loaded in a temporary synthetic-only SteamVR session;
see [live results and limits](LIVE-LAB.md).

The driver links libc for pthreads, not libc++. Zig's no-libc thread implementation depends on
Zig-owned process/TLS startup and is unsuitable for a DSO embedded in a foreign host. The
standalone Zig actor still needs neither runtime. RTTI/dynamic_cast and other target ABIs remain
outside the verified contract.

## Next: programmable hardware-free lab

Synthetic HMD registration, Linux compositor startup and a controlled 75 Hz clock are now
verified with physical drivers excluded. The server publishes a fixed head pose on a 250 Hz
absolute monotonic grid, skipping missed slots. It blocks standby only while the synthetic HMD
is active; provider RunFrame is not a display/pose clock. The compositor provider is a separate
process-local instance, has no actor socket, and supplies its own monotonic virtual-vsync count.
Clock count advances even when callbacks are missed; neither Present counts nor JS timers
determine it. Server actor health counters describe the server instance, not compositor callbacks.

The enclosing repo's scoped launcher backs up exact settings/registration bytes before
mutation and restores them after stopping SteamVR. A pending restore file refuses another
session. Linux needs an internal mirror-window fallback setting and an X11 compositor launch;
this is a desktop-dependent lab, not yet a surfaceless runtime. See LIVE-LAB.md for recovery.

Left/right controllers, their input profile and queued analytic trajectory controls are now
implemented and measured through public OpenVR poses; see [controller details](CONTROLLER-LAB.md).
Next is compositor final-image capture. The current clocked discard sink does not read GPU textures or prove
final-image delivery. In the verified run Linux queried its timing but never called its
Present/WaitForPresent methods. Investigate that output path before using it as evidence of
compositor-consumed overlay coherence.

Motion definitions are uploaded once and evaluated in Zig at monotonic sample timestamps,
with analytic velocity and real sample-time offset. A bounded eight-command queue applies
validated motion changes at a native sampling boundary. Sampling uses its own thread and
absolute 250 Hz grid; missed slots are skipped, not replayed. Snapshot reads and control
changes use the shared state mutex; this is soft real-time, not a bounded-latency guarantee.
Do not put per-sample JS/IPC or blocking network work in RunFrame. Compare commanded samples, client-predicted poses,
publication and compositor-consumed images under explicit optical/timing/workload profiles.
A driver does not itself solve atomic overlay publication or prove displayed cadence.

## Experimental Linux driver-direct output

The opt-in driverDirect backend replaces DisplayRedirect with a distinct
IVRDriverDirectModeComponent_009 object. Its vtable and IVRIPCResourceManagerClient_003 prefix
are explicit Zig ABI declarations, validated against the existing official SDK header. Image
handles/FDs stay native in a bounded ledger; GETDIRECTSTATE exposes diagnostic counters.
A separate native display clock announces vsync through the host and PostPresent paces the
consumer. The compositor-side virtual-display plugin is disabled for this backend.

Live SteamVR allocates and submits real per-eye images. External GPU readback, public producer completion
and runtime teardown references still need work. The optional producer-side capture layer
now verifies actual driver buffer pixels; see GPU-READBACK.md. A synthetic output backend also changes
SteamVR's Linux async/reprojection selection, so it must not silently stand in for physical-HMD
behavior. See [DIRECT-MODE.md](DIRECT-MODE.md) for exact evidence and next acceptance criteria.
