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
- No devices registered yet; device activation fails explicitly.
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
The live driver hasn't been registered or loaded by SteamVR yet.

The driver links libc for pthreads, not libc++. Zig's no-libc thread implementation depends on
Zig-owned process/TLS startup and is unsuitable for a DSO embedded in a foreign host. The
standalone Zig actor still needs neither runtime. RTTI/dynamic_cast and other target ABIs remain
outside the verified contract.

## Next: programmable hardware-free lab

Implement a synthetic HMD/display, then left/right controllers and input profiles. A
controller-only driver would still need a physical HMD. Prove Linux compositor startup/output
with physical display drivers unselected; surfaceless output and final-image capture are
separate feasibility checks. Runtime registration and test-mode activation need exact settings
backup/restore and recovery for interruption, rather than unconditional startup changes.

Upload time-based trajectories once; evaluate them in Zig at scheduled monotonic timestamps,
with analytic velocity and real sample-time offset. Apply future control mutations on the
appropriate driver/device owner thread via a bounded queue. Do not put per-sample JS/IPC or
blocking network work in RunFrame. Compare commanded samples, client-predicted poses,
publication and compositor-consumed images under explicit optical/timing/workload profiles.
A driver does not itself solve atomic overlay publication or prove displayed cadence.
