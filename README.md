# Zigium

An original Zig Nintendo Switch emulator focused on homebrew, with a Vulkan-only graphics design. Zig 0.17.0 is required.

```powershell
zig build
zig build test
zig build demo
zig build run -- app.nro
zig build run -- --emit-demo hello.nro
```

The core library contains an AArch64 interpreter, permission-checked guest virtual memory, NRO loading, the homebrew entry environment, and essential Horizon SVC handling. The CLI is a thin frontend.

Phase 1 runs the supplied hello-world NRO end to end. Service and graphics support are under development. The compatibility target is **Space Game NX 1.1** (`spacenx.nro`); a playable boot is pending. General libnx, NSO/NCA, VI, audio, and commercial-game compatibility are not established.

Protocol sources and graphics design boundaries are in [docs/references.md](docs/references.md). Detailed guides will live in `docs/` as their implementations land.
