# mcsoda

A Wine build for macOS on Apple Silicon: Valve's Wine base, the portable part
of Bottles' Soda recipe, msync for synchronisation, and Metal-backed Direct3D.

Everything runs as x86_64 under Rosetta 2.

## What this is not

Two things were asked for that cannot be built, for reasons that are not
effort-related:

**ntsync** is a Linux kernel driver. It cannot exist on macOS. msync replaces
it, using Mach semaphores.

**FEX** does not help *as a Linux program*: its syscall and thunk layers are
Linux ABI throughout, and x86 TSO memory ordering is settable per-thread only
for Rosetta processes, so without it every guest load and store needs explicit
barriers.

But FEX's PE module `libarm64ecfex.dll` is a different thing, and it already
exports Wine's exact 20-entry `xtajit64.spec` contract under MIT. Inside Wine
its "OS" is ntdll, and Wine already synthesises Windows' fixed 4 KB pages on a
16 KB host (`dlls/ntdll/unix/virtual.c:163`). So the page-size objection does
not apply there.

**ARM64EC** is therefore feasible, but gated on one thing: Wine's Unix virtual
memory layer has no `MAP_JIT` path, and on macOS 27 RWX via `mmap`/`mprotect`
returns `EACCES`. `MAP_JIT` write-protect is per-thread; Wine's VM layer is
process-global. Estimated 6-12 months to a usable state.

**Rosetta-backed ARM64EC** is ruled out outright, not on effort: Apple
documents that a process cannot mix arm64 and x86_64 code. Rosetta's unit is a
whole process chosen at exec.

So this build is plain x86-64 Wine under Rosetta 2, which is also what Apple's
own Game Porting Toolkit does. That choice has a shelf life: Apple states
Rosetta is general-purpose through macOS 27, and from macOS 28 narrows to a
subset for older unmaintained games.

Full analysis with sources: [`../arm64ec-macos-feasibility.md`](../arm64ec-macos-feasibility.md).
The `MAP_JIT` gate it names is measured in
[`../mapjit-wine-probe.md`](../mapjit-wine-probe.md): confinable to the
emulator, roughly 2-4 weeks, not a rewrite of Wine's VM layer.

## Requirements

- Apple Silicon Mac, macOS 26 or later
- Xcode command line tools
- Rosetta 2 (`softwareupdate --install-rosetta`)
- Apple Game Porting Toolkit, installed by you, **only if you want Direct3D
  12**. Manual download from Apple Developer; licence forbids redistribution.
  Direct3D 10/11 work without it via DXMT.

## Build

```bash
./check.sh        # preconditions; changes nothing
./0-bootstrap.sh  # tools + x86_64 freetype/SDL2/gnutls/MoltenVK
./1-fetch.sh      # Valve wine, mono, gecko, DXMT builtin tarball
./2-patch.sh      # patches + regenerate protocol/spec/vulkan
./3-build.sh      # configure + make (x86_64, Rosetta)
./4-package.sh    # install into work/dist + wire runtime
```

`config.sh` holds every version, path and URL.

## Run

```bash
export WINEPREFIX="$HOME/.mcsoda"
./work/dist/usr/local/opt/mcsoda/bin/mcsoda wineboot -u
./work/dist/usr/local/opt/mcsoda/bin/mcsoda your-game.exe
```

`mcsoda` turns on msync, puts runtime dylibs on the loader path, points
Vulkan at MoltenVK, prefers DXMT builtins for D3D10/11, and looks for
D3DMetal via `GPTK_D3DMETAL` (see `./install-gptk-hint.sh`).

## Status

Working: prefix creation, msync, fonts (freetype), TLS (gnutls), gamepads
(SDL2), winevulkan via MoltenVK, D3D10/11 via DXMT v0.80.

Needs your GPTK install for D3D12.

## Limits

- **No 32-bit Windows applications.** Rosetta 2 does not translate 32-bit x86.
- **No anti-cheat.** Proton's EAC bridge needs a Linux-native library.
- Fullscreen hack, X11 compositor bypass and child-window Vulkan are all
  X11-bound and are not present.

`patches/README.md` has the full toggle-by-toggle triage of Soda's recipe.

## Licences

Wine and msync are LGPL-2.1. DXMT has its own terms. D3DMetal is Apple's and
is referenced, never redistributed.
