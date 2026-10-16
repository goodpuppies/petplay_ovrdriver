# petplay_ovrdriver

Pure Zig OpenVR driver foundation for PetPlay's programmable VR test devices and future
runtime integrations. Linux x86-64, Zig 0.16.0. Early milestone: no devices registered yet.

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
  and lifecycle only. It deliberately registers no tracked devices yet.
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
an offline device DebugRequest. It does not prove runtime loading, HMD output or full C++ ABI
support. RTTI/dynamic_cast, inheritance beyond the declared interface objects, non-x86-64 Linux,
and Windows are outside the verified contract. Unsupported driver targets fail at compile time.

The C++ test executable uses LLVM's linker because the installed native GCC 16 CRT's .sframe
relocations are unsupported by Zig 0.16's default linker. Neither the driver nor native actor
links libc/libc++; only the test consumer does.

## Repository integration

Intended PetPlay submodule path: `submodules/petplay_ovrdriver`.
All building and tests are local. Publishing a remote repository is a separate step.

## SDK

Vendored OpenVR header: Valve's BSD-style license in
`vendor/openvr/LICENSE`; exact upstream revision is recorded in `vendor/openvr/UPSTREAM.md`.
