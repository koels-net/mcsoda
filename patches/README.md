# Patch triage: Soda recipe against macOS arm64

Bottles' "Soda" runner is not a patch repository. It is a [wine-tkg][tkg]
configuration, held in [`bottlesdevs/build-tools`][bt] at
`runners/vaniglia/wine-tkg-valve.cfg` and `runners/vaniglia/proton-tkg.cfg`.
Each line of those files is a toggle that makes wine-tkg apply some patch set
to a Valve Wine checkout.

Porting "Soda patches" to macOS therefore means going through those toggles one
at a time and deciding which can follow. This file is that decision list.
Nothing here is applied automatically; `patches/series` starts empty.

[tkg]: https://github.com/Frogging-Family/wine-tkg-git
[bt]: https://github.com/bottlesdevs/build-tools

## Synchronisation

`_use_fsync="true"` is the one toggle that cannot simply be dropped, because
something has to replace it.

| Mechanism | Backing primitive | Works on macOS |
|---|---|---|
| `ntsync` | Linux kernel driver (`drivers/misc/ntsync.c`) | No. Kernel driver. |
| `fsync`  | `futex2` / `futex_waitv` | No. Linux syscalls. |
| `esync`  | `eventfd` | Emulated on macOS via pipe fds. Slow, fd-limited. |
| `msync`  | Mach semaphores + `__ulock_wait2` | **Yes. This is the one.** |

### Where msync comes from

Not from [`marzent/wine-msync`][msync]. That standalone patch targets Wine 9.x
and does not survive the trip: against Valve's Wine 11.0 it leaves 120 rejected
hunks across 33 files, and worse, the model it patches no longer exists. Wine
11 moved synchronisation behind a `get_sync` member on `struct object_ops`,
with the accelerated backend living in `server/inproc_sync.c`. The 2024 patch's
approach - a `msync_idx` field on every object, a `get_msync_idx` vtable entry,
and `do_msync()` tests sprinkled through every set/reset/signal function - is
fighting a tree that has since centralised exactly that.

We use CodeWeavers' msync instead, from their published CrossOver sources
(mirrored at [`marzent/winecx`][winecx], branch `ff-wine-11.0`). It is LGPL-2.1
like the rest of Wine, and it is already rebased onto **Wine 11.0 - the same
base as our Valve branch**. On that base it touches 11 files, not 52, because
it plugs into the new architecture: an `#elif defined(__APPLE__)` branch inside
`server/inproc_sync.c` that implements the same `create_inproc_*_sync()` API
against Mach semaphores, plus a matching branch in `dlls/ntdll/unix/sync.c`
that maps the `linux_*_obj()` interface onto msync.

Extracting it needed 16 hunks filtered out of CrossOver's full delta, of which
6 needed hand-fixing for Proton-vs-CrossOver drift. All of that is baked into
`0002-msync-from-crossover-11.0.patch`, including the four msync source files
in full, so the build fetches nothing extra.

Two things that were expected to be hard and were not:

- **No `protocol.def` change.** CrossOver's msync wants an index field in the
  `get_inproc_sync_fd` reply. Valve's tree already has one, named
  `fsync_shm_idx`, because Proton's fsync does the same trick. We reuse it.
- **No hand-editing of `server_protocol.h`.** `tools/make_requests` regenerates
  it, and `2-patch.sh` runs it. Valve's checked-in copy lags their own
  `protocol.def` anyway, so this is required with or without msync.

[msync]: https://github.com/marzent/wine-msync
[winecx]: https://github.com/marzent/winecx

## Build portability

`0001-macos-build-portability.patch` is what it took to make Valve's tree
compile and link on macOS. Twelve files. None of it is msync-related; these are
Proton additions and Wine build-system gaps that assume Linux. Found by
building until it stopped, fixing, repeating.

**Linux-only headers and syscalls**

- `server/inproc_sync.c`, `dlls/ntdll/unix/sync.c` include `ntsync_tmp.h`
  unconditionally; it includes `<linux/types.h>`. Everything it declares is
  used only inside `#ifdef NTSYNC_IOC_EVENT_READ`, so the include is guarded.
- `dlls/ntdll/unix/loader.c` includes `<malloc.h>` and calls
  `mallopt( M_PERTURB, ... )`, both glibc-only and absent upstream. Guarded
  with `#ifdef __GLIBC__`.
- `dlls/ntdll/unix/fsync.c`, `server/fsync.c` call `syscall( __NR_futex, ... )`.
  fsync is futex-based and cannot work here; the server's
  `fsync_check_support()` already returns 0 on non-Linux, so these only have to
  compile. msync is the macOS path.
- `dlls/amd_ags_x64/unixlib.c` includes `<xf86drm.h>` unconditionally even
  though configure tests for it. Stubbed out when `HAVE_XF86DRM_H` is unset:
  no libdrm means no AMD GPU to query.
- `dlls/win32u/vulkan.c` calls `gettid()`. Added a macOS version using
  `pthread_threadid_np`; the value is used for debug output only.
- `dlls/ntdll/unix/system.c` uses `fill_performance_core_info()` and
  `sysfs_parse_bitmap()` outside the `#ifdef linux` block that defines them.
  They read `/sys/devices/system/cpu` for Proton's CPU-topology override.
  Stubbed for non-Linux, so the override reports no performance cores.
- `dlls/winegstreamer/media-converter/media-converter.h` uses
  `pthread_mutex_t` without including `<pthread.h>`; glibc pulls it in
  transitively and macOS does not.

**Dropped non-Linux branches**

- `dlls/ntdll/unix/signal_x86_64.c`: Valve refactored TEB setup into a new
  `set_thread_teb()` that only does the Linux `arch_prctl( ARCH_SET_GS )`.
  Restored upstream's per-OS branches; on macOS it is a no-op, because
  `leave_handler()` sets GSBASE.
- `dlls/win32u/opengl.c`: the framebuffer-surface helpers are defined inside
  `#ifdef SONAME_LIBEGL` but used outside it, so no-EGL builds do not link.
  Added stubs in the `#else` branch; `framebuffer_surface_funcs` never matches
  a real drawable, so those branches are dead.

**Build system**

- `loader64/Makefile.in` omitted `wine_info.plist.in` from SOURCES while
  `WINELOADER_DEPENDS` requires the generated plist, and hardcoded
  `wine64-preloader` into PROGRAMS. configure sets `WINELOADER_PROGRAMS` to
  just `wine` on macOS, and `preloader_mac.c` calls `__dyld_func_lookup`,
  which modern macOS no longer provides. `loader/Makefile.in` honours the
  variable; this one did not.

Generated files are not patched. Valve's tree omits the ones upstream Wine
checks in and expects the build to produce them, so `2-patch.sh` runs
`tools/make_requests`, `tools/make_specfiles` and
`dlls/winevulkan/make_vulkan`.

## Toggle-by-toggle

### Drop — depends on Linux or X11

| Toggle | Why it cannot follow |
|---|---|
| `_use_fsync` | `futex_waitv`. Replaced by msync, above. |
| `_proton_fs_hack` | Fullscreen hack implemented in `winex11.drv`. macOS uses `winemac.drv`. A macOS equivalent would have to be written against `winemac.drv` from scratch; it is not a port. |
| `_FS_bypass_compositor` | X11 compositor bypass. No analogue. |
| `_childwindow_fix` | Child-window Vulkan support on X11. On macOS the stack is Metal, via MoltenVK or DXMT. |
| `_proton_eac_support` | Proton's EAC bridge loads a Linux-native `.so`. No macOS EAC runtime exists. Anti-cheat generally will not work on this stack; do not expect otherwise. |
| `_staging_pulse_disable` | Disables a PulseAudio patch set. There is no PulseAudio here; audio is `winecoreaudio.drv`. |
| `_nvidia_hate` | Suppresses building nvapi/nvcuda. No NVIDIA GPUs on Apple Silicon. |

### Take — portable, no display-server dependency

| Toggle | Notes |
|---|---|
| `_use_josh_flat_theme` | `uxtheme`/`comctl32` only. Cosmetic, zero risk, cheapest thing to port first. |
| `_win10_default` | Default Windows version. Trivial. |
| `_large_address_aware` | Sets `IMAGE_FILE_LARGE_ADDRESS_AWARE`. Note: Soda applies this to 32-bit games, and this build has no 32-bit support, so the practical value here is low. |
| `_msvcrt_nativebuiltin` | DLL override defaults. |
| `_proton_bcrypt` | Adds DH constants to `bcrypt`. Self-contained. |
| `_clock_monotonic` | Uses `CLOCK_MONOTONIC` for timing. macOS has `clock_gettime` since 10.12. Verify `CLOCK_MONOTONIC_RAW` behaviour before trusting it. |
| `_protonify` | A grab bag, not one patch. Must be split and triaged individually; some parts are Linux-specific. Do not take wholesale. |

### Take with work

| Toggle | Notes |
|---|---|
| `_proton_rawinput` | The `ntdll`/`win32u` side is portable. The driver side needs `winemac.drv` plumbing that does not exist. Partial port. |
| `_use_GE_patches` | GE's set is large and substantially X11/Linux-flavoured. Cherry-pick individual patches; never apply in bulk. |

### Game-specific — portable, low priority

`_warframelauncher_fix`, `_mk11_fix`, `_ffxivlauncher_fix`,
`_assettocorsa_hudperf_fix`. These sit at `ntdll`/`user32` level and should
carry over. Port them if you play those games.

## Graphics

Soda sets `_use_dxvk="false"` and `_use_vkd3dlib="false"` and lets Bottles
manage the translation layer. We do the same, with different layers:

- **D3D10/11** — [DXMT][dxmt], Metal-backed, open source. Bundled.
- **D3D12** — D3DMetal, from Apple's Game Porting Toolkit. **Not bundled.**
  Apple's GPTK licence covers evaluation and development use and does not
  grant redistribution rights, so the build references a copy the user
  installs themselves. Shipping D3DMetal inside a distributed bundle would
  breach that licence.
- **Vulkan** — MoltenVK, if a title needs it directly.

`0005-winemac-d3dmetal-macdrv-functions.patch` exports the `macdrv_functions`
table that GPTK's `libd3dshared.dylib` `dlsym`s from `winemac.so` to reach the
Cocoa window and create its Metal view. It is CodeWeavers' `d3dmetal.c`, adapted
to this tree's window model: the Valve tree has no permanent client view, so
`get_win_data` creates one driver-owned client surface per window (registered
with win32u via a newly exported `add_window_client_surface`) and hands its
view to D3DMetal as `client_cocoa_view`. That matches what GameHub's
`winemac.so` does. The registry entries go through `KeUserDispatchCallback` to
PE-side `RegOpenKeyExA` and the related registry calls in `dllmain.c`.

### 0006-macos-keep-pthread-gsbase-for-gptk.patch

Upstream Wine 11 on macOS swaps GSBASE to the TEB whenever PE code runs, and
swaps back to the pthread TSD inside unix calls. GPTK's `libd3dshared` runs
native code directly on Windows threads (`D3DRMDispatch_Init` is a thread entry
point, and d3d12 calls into it through the MS ABI). That code's
`pthread_setname_np` / `pthread_setspecific` then read the TEB as if it were the
TSD and fault. That fault was the exit 5, and the exception storm that
followed pinned a core.

This patch uses CrossOver's (and GameHub's) model instead:

- GSBASE always stays on the pthread TSD. The dispatchers and signal handlers
  no longer call `_thread_set_tsd_base`, and `check_invalid_gsbase` is a no-op.
- Only the TSD slots macOS reserves for Wine are mirrored: TEB.Self in slot 6
  (`%gs:0x30`) and ThreadLocalStoragePointer in slot 11 (`%gs:0x58`).
  `teb->Instrumentation[0]` points at the TSD so TLS vector updates reach it.
- Every other `%gs:` read goes through `%gs:0x30`. That covers the
  dispatchers' `syscall_frame` and `instrumentation_callback` reads and the
  PE ntdll's PEB reads. Slot 12 (`%gs:0x60`) belongs to libc's localtime key.

[dxmt]: https://github.com/3Shain/dxmt

## Known gaps

- **No 32-bit.** Rosetta 2 does not translate 32-bit x86, so `--enable-archs`
  is `x86_64` alone. Soda ships 32-bit support; it does not survive the port
  by any available route.
- **No anti-cheat.** See `_proton_eac_support` above.
- **macOS 26+ `winemac.drv`.** Later macOS releases broke things upstream Wine
  has not fully caught up with. Other projects in this space carry their own
  `winemac.drv` fixes. Not yet investigated here.
- **Rosetta 2 is sunsetting.** Apple has said Rosetta 2 continues through
  macOS 27 and then narrows to a compatibility subset for older games. This
  whole build sits on top of it. See `../arm64ec-macos-feasibility.md` and
  `../mapjit-wine-probe.md` for what replacing it would take.

## macOS fullscreen and native host fixes (0009–0011)

- `0009-winemac-fullscreen-mask-local-coordinates.patch` converts the black-bar
  mask from desktop coordinates to visible-window-local coordinates, then from
  Wine pixels to Cocoa points. This prevents a monitor with a negative origin
  from having nearly its entire fullscreen image covered by the mask. Monitor
  positions, mouse coordinates and the native window frame are unchanged.
- `0010-winemac-fullscreen-controls-and-menu-bar.patch` coordinates AppKit
  menu/titlebar auto-hide, retains native fullscreen exit controls while Windows
  reports maximized or borderless state, and defers decoration changes until
  native exit or failed entry. Non-captured game fullscreen uses reversible
  menu/Dock auto-hide rather than a window above the menu bar. It also installs
  Wine's Window menu when a native host is already a Regular application.
- `0011-winemac-preserve-native-game-host-icon.patch` lets a native host preserve
  its compiled macOS Dock icon instead of replacing it with a Windows HICON.
  Set `BlockintoshPreserveApplicationIcon` to `true` in the host's Info.plist to
  opt in. Hosts without this key keep the existing Windows icon behavior.

Validation: the x86_64 driver builds with `MACOSX_DEPLOYMENT_TARGET=15.4`.
A source-derived native probe covers 24 fullscreen mask layouts; a controls/
presentation probe passes 75 checks on both arm64 and x86_64. Both have failing
original-code controls. An isolated Wine window verifies native fullscreen entry, the enabled
Window → Exit Full Screen action, and a simulated game fullscreen on/off cycle.
The Blockintosh owner subsequently confirmed the fullscreen and icon fixes in
build 44. These changes do not establish a cause for the separately reported
7 GB memory spike or complete all Wine fullscreen/platform conformance testing.
