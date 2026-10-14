# Protocol references

Zigium is original Zig code. These public specifications and homebrew client
sources are used to establish guest-visible data layouts and behavior. They are
not emulator implementation sources. The links below are pinned where possible.

## Homebrew and system calls

- [Homebrew ABI](https://switchbrew.org/wiki/Homebrew_ABI): entry registers and
  loader configuration entries, including main-thread handle, heap override,
  arguments, service overrides, and supported system calls.
- [Horizon SVC reference](https://switchbrew.org/wiki/SVC): system-call numbers,
  input/output registers, memory queries, handles, synchronization, and IPC.
- [libnx runtime initialization](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/runtime/init.c): a normal
  libnx application initializes SM, applet, HID, time, and filesystem services.
  Running a small custom NRO does not establish general libnx compatibility.

## IPC and service discovery

- [HIPC layout](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/include/switch/sf/hipc.h): two header words,
  optional PID and handle section, static and map-alias descriptors, raw data,
  and receive list. Descriptor pointers are guest virtual addresses.
- [CMIF layout](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/include/switch/sf/cmif.h): payloads begin at a
  16-byte-aligned offset relative to the message buffer. Request magic is SFCI;
  response magic is SFCO. Transport errors and service Result values are separate.
- [SM client](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/services/sm.c): `sm:` is a named port.
  CMIF command 0 registers the client; command 1 resolves an eight-byte service
  name to a moved session handle. Current libnx uses CMIF for both commands even
  where SM supports TIPC.
- [APM client](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/services/apm.c): parent command 0 returns
  an ISession object; parent command 1 reads performance mode. Session commands 0
  and 1 set and read a performance configuration.
- [HID client](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/services/hid.c): parent command 0 returns
  an applet-resource session; its command 0 returns a copied shared-memory handle.
  The shared region is 0x40000 bytes. Npad state is sampled from shared-memory
  rings; a successful activation command alone does not supply controller input.

## GPU submission and display

- [nvdrv client](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/services/nv.c): commands 0, 1, 2, and 3
  open a device, perform an ioctl, close a descriptor, and initialize transfer
  memory. Ioctl results include a separate NVIDIA status value.
- [NvMap ioctls](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/nvidia/ioctl/nvmap.c) and
  [GPU address-space ioctls](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/nvidia/ioctl/nvhost-as-gpu.c):
  allocations refer to guest CPU memory; GPU mappings require a distinct address
  space and range checks. Treating a GPU address as an arbitrary CPU pointer is
  not a general MMU implementation.
- [Channel submission](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/nvidia/ioctl/nvchannel.c) and
  [GPFIFO entry construction](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/nvidia/gpu_channel.c):
  ioctl family 0x48 command 0x08 submits inline GPFIFO entries. A 24-byte
  submission header precedes those entries. A GPFIFO entry stores the GPU
  address in its low bits and command-word count starting at bit 42.
- [NVIDIA Maxwell B class header](https://github.com/NVIDIA/open-gpu-doc/blob/9fdf5c4062007929d9f4e6cbad9c9771fe61b880/classes/3d/clb197.h): class 0xB197,
  render-target address/extent/format/memory registers, clear values, masks, and
  clear operation. Header addresses are byte offsets; pushbuffer method indices
  are those offsets divided by four. RGBA8 format A8B8G8R8 is 0xD5.
- [deko3d packet format](https://github.com/devkitPro/deko3d/blob/350f2b00a3e76ecd4f00191f8c5d6544ffbcb9db/source/maxwell/command.h): method bits 0-12,
  subchannel 13-15, argument 16-28, submission mode 29-31. Modes 1, 3, 4, and 5
  increase methods, repeat a method, carry an immediate, and increase once.
- [VI client](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/services/vi.c),
  [Binder relay](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/display/binder.c), and
  [buffer producer](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/source/display/buffer_producer.c):
  standard homebrew display uses a VI layer and Android-style buffer queue.
  Binder transactions 3, 7, 10, and 14 dequeue, queue, connect, and register a
  preallocated buffer. A host debug viewer does not establish this compatibility.
- [libnx framebuffer API](https://github.com/switchbrew/libnx/blob/feebd026ca0f5dcc2119f46ad8e0d16ad3dd4973/nx/include/switch/display/framebuffer.h): software rendering still reaches
  the normal display buffer queue. Its framebuffer storage uses Tegra block
  linear layout; the linear helper converts a shadow buffer before presentation.

## Host renderer

- [Vulkan specification](https://docs.vulkan.org/spec/latest/index.html) and
  [Khronos Vulkan tutorial](https://docs.vulkan.org/tutorial/latest/00_Introduction.html):
  explicit image ownership, memory barriers, swapchain acquisition/presentation,
  and host-visible readback. A presented frame and readback verification are
  separate checks.

For initial development, a bounded Maxwell clear subset can use an offscreen
RGBA8 Vulkan image, copy to host-visible memory for verification, and blit to a
Win32 Vulkan swapchain. Unknown methods, unsupported layouts, partial channel
masks, and unsupported formats should fail with diagnostics until their guest
semantics are implemented. This is a proposed minimum slice, not a claim of
complete Maxwell, deko3d, VI, or commercial-game support.
