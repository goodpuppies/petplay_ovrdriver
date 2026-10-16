# Native driver and Stageforge actor boundary

## Ownership

The actual driver is loaded by SteamVR inside vrserver. PetPlay cannot spawn it as an ordinary
owned subprocess, and terminating an actor must never terminate vrserver. Actor identity and
routing can look ordinary to callers while the transport retains external ownership.

The initial standalone executable is a protocol control. Its process is owned by its test
transport. It uses exactly the same Zig actor dispatcher as the driver; it does not claim to
exercise an installed driver or any tracked devices. Health identifies standalone versus
SteamVR ownership and whether the provider was initialized.

## Implemented

- Pure Zig C factory, provider/device interface objects and Linux x86-64 vtable address points.
- Runtime context/host lookup, driver handle, lifecycle, standby and RunFrame counters.
- No devices added during real provider initialization; device activation fails explicitly.
- Transport-independent Zig Stageforge endpoint: WebSocketWorker-style JSON envelopes,
  INIT/LOADED registration and callbackKey, assigned or generated UUID actor IDs,
  addressed request/reply packets, `TYPE:callback-id` correlation, and `__actorError` replies.
- HEALTH, PING, ECHO, SHUTDOWN and SHUTDOWN_AND_CLOSE. No JS execution in the driver.
- JSON ECHO preserves Stageforge BigInt tag objects; Zig doesn't interpret those as numbers.
  Dynamic commands involving u64 handles must use tagged values or an explicit string schema,
  never assume a JSON number survives a roundtrip through JS exactly.
- Bounded 16 KiB packets, per-request allocator arenas, parser rejection of malformed envelopes,
  and no return packets for fire-and-forget requests.
- Standalone newline-delimited JSON transport with ready handshake; handles split/coalesced
  stdin reads and oversized-line recovery. Same logical envelopes as Stageforge's WebSocket
  transport, **not** a claim that stdin is RFC6455 WebSocket framing.
- Worker-compatible Deno transport with the existing codec injected, bounded output queues,
  real PostalService integration and cooperative shutdown.
- Driver-side dispatcher also wired to the offline device DebugRequest for ABI/packet tests;
  that device is not registered, so this is not yet a discoverable live driver-control endpoint.

## Next: externally-owned live connection

Choose an explicit attachment transport for vrserver, not IPCWorker's spawn-and-kill contract.
Prefer reusing the existing Stageforge WebSocketWorker adapter after implementing an actual
bounded WebSocket client in Zig. PetPlay can open a private loopback rendezvous endpoint and
supply a short-lived connection capability through driver settings or a user-only local file.
The driver connects after Init, outside RunFrame; validates/limits packets; and sends ready.
Do not expose an unauthenticated command listener or make driver initialization depend on the
PetPlay service being online. No runtime socket is started in the current milestone.

Registration should produce an ordinary actor ID and participate in normal routing/health.
A connection shutdown cancels synthetic programs/disables their input, acknowledges, detaches
and leaves SteamVR alive. Reconnection needs a fresh session/actor identity and bounded retries;
cooperative disconnect must not accidentally reconnect immediately. PetPlay reload should
reattach control or request an explicit reset, not unload/reload the native library blindly.

Use the transport thread to parse/control and enqueue bounded commands. Apply runtime/device
mutations on the driver owner/timing thread. RunFrame cannot block on JSON, IPC or PetPlay.
Counters currently use atomics; the future device engine needs explicit ownership and teardown
barriers before context release. DebugRequest serializes its own actor access without spinning;
it is diagnostic plumbing, not the proposed tracking transport.

## Next: programmable hardware-free lab

Implement a synthetic HMD/display first, then left/right controllers and input profiles. A
controller-only driver still relies on a physical HMD. Prove Linux compositor startup and
output without any physical display driver selected; surfaceless output and final-image
capture are separate capabilities to validate.

Upload time-based trajectories once; evaluate them in Zig at scheduled monotonic timestamps,
with analytic velocity and real sample-time offset. Do not route every tracking sample through
JS/IPC or advance motion by callback count. Record effective optical/timing properties and
compare commanded samples, client-predicted poses, publication and compositor-consumed images.
The driver itself does not solve atomic overlay publication or establish displayed cadence.
