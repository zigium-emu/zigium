# Zigium

An original Nintendo Switch homebrew emulator in Zig, with a Vulkan-only desktop frontend. Requires Zig 0.17.0; the Windows GUI also requires the Vulkan SDK (`VULKAN_SDK`).

```powershell
zig build
zig build test
zig build demo
zig build services-demo
zig build make-demo
zig build run
zig build run -- --gui app.nro
zig build run -- app.nro
zig build run -- --emit-demo hello.nro
zig build -Dvulkan=false
```

The core separates AArch64 execution, permission-checked memory, Horizon SVCs and services, NRO/NSO loading, HID, and guest framebuffer decoding. The desktop and CLI frontends pass context explicitly. Horizon services use HLE; software framebuffers pass through VI/Binder and Tegra layout conversion before Vulkan presentation.

Launching without arguments opens the Windows GUI. Use `--gui app.nro` to load homebrew into the GUI, or pass a path directly for CLI execution.

The original hello and SM/APM service NROs execute successfully; the service demo completes 76 instructions, 6 SVCs, and 3 IPC requests, including a verified Vulkan GUI run. **Space Game NX 1.1** (`spacenx.nro`) reaches gameplay: starting, movement, stick shots, and sustained mouse aiming/fire were verified using real Windows input and GPU readback images. A short ReleaseSafe sample measured 8.6 guest FPS on an RTX 5070 Ti. This remains slow, limited compatibility. All 75 core tests pass.

GUI controls: Ctrl+O opens homebrew, F1 selects the demo, and F5 pauses/resumes. WASD/arrows move, IJKL controls the right stick, Space/X is A, Z is B, Enter is Plus, and Escape is Minus. Hold the left mouse button inside the game image to aim/fire through guest touch input. SpaceNX's old SDL build reads movement change events, so movement can require repeated taps; its first stick deflection calibrates the axis.

Support remains limited: FP/SIMD coverage is incomplete, clocks are based on interpreted execution, general filesystem operations and NCA loading are pending, audio is unimplemented, and Maxwell shader/draw execution and JIT compilation are unsupported. A working software framebuffer path does not establish broad libnx or game compatibility.

Website: [zigium-emu.org](https://zigium-emu.org/). Design and contributor notes remain local in `docs/`; only this README is tracked as Markdown.
