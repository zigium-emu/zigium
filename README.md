# Zigium

An original Nintendo Switch homebrew emulator in Zig, with a Vulkan-only desktop frontend. Requires Zig 0.17.0; the Windows GUI also requires the Vulkan SDK (`VULKAN_SDK`).

```powershell
zig build
zig build test
zig build demo
zig build services-demo
zig build make-demo
zig build gui -- app.nro
zig build gui -- zig-out/hello-services.nro
zig build run -- app.nro
zig build run -- --emit-demo hello.nro
zig build -Dvulkan=false
```

The core separates AArch64 execution, permission-checked memory, Horizon SVCs and services, NRO/NSO loading, HID, and guest framebuffer decoding. The desktop and CLI frontends pass context explicitly. Horizon services use HLE; software framebuffers pass through VI/Binder and Tegra layout conversion before Vulkan presentation.

The original hello and SM/APM service NROs execute successfully. **Space Game NX 1.1** (`spacenx.nro`) reaches its rendered title screen; gameplay verification is ongoing. GPU upload/readback, the desktop GUI, and CPU/service tests are verified on Windows.

GUI controls: Ctrl+O opens homebrew, F1 selects the demo, and F5 pauses/resumes. WASD/arrows move; Space/X is A, Z is B, Enter is Plus, and Escape is Minus.

Support remains limited: FP/SIMD coverage is incomplete, clocks are based on interpreted execution, general filesystem operations and NCA loading are pending, audio is unimplemented, and Maxwell shader/draw execution is unsupported. A working software framebuffer path does not establish broad libnx or game compatibility.

Website: [zigium-emu.org](https://zigium-emu.org/). Design and contributor notes remain local in `docs/`; only this README is tracked as Markdown.
