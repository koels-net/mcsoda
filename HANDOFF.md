# mcsoda — handoff

Build of Wine for macOS on Apple Silicon. This file is the state as of
2026-10-18, written so another agent can pick it up cold.

Repo root: `/Users/kyle/dev/TEWST/mcsoda` (moved from `~/Documents/TEWST`
on 2026-10-18 ~21:30; the `work -> work.nosync` symlink came along).

## Goal

A Wine distribution for macOS arm64 with:

- Valve's Wine fork as the base (Bottles' "Soda" runner recipe)
- msync for NT synchronisation (Mach semaphores), replacing Linux-only
  ntsync/esync/fsync
- Metal-backed Direct3D: DXMT for D3D10/11, D3DMetal (from Apple's Game
  Porting Toolkit) for D3D12

Everything runs as **x86_64 under Rosetta 2**. Not ARM64EC — see "Architecture
decisions" below.

## Current state

**The build works end-to-end.** `wine --version` → `wine-11.0`. Fresh
`mcsoda wineboot -u` finishes in ~20s. msync up. MoltenVK creates a
`VkInstance`. DXMT `d3d11.dll` (~5.3 MB) is what lands in the prefix.

Installed tree: `work/dist/usr/local/opt/mcsoda`.

### Shipped

| Piece | How |
| --- | --- |
| wine-mono 10.4.1 | `1-fetch.sh` + `4-package.sh` → `share/wine/mono/` |
| wine-gecko 2.47.4 | same → `share/wine/gecko/` |
| DXMT v0.80 builtin | prebuilt tarball (not a from-source LLVM build) → `d3d11/dxgi/d3d10core/winemetal` |
| x86_64 freetype, SDL2, gnutls (+gmp/nettle/…), MoltenVK 1.4.2 | `0-bootstrap.sh` → `work/x86deps`, copied next to unix `.so` at package time |
| winevulkan | configured `--with-vulkan` against MoltenVK |

### GPTK / D3D12 — installed on this machine

GPTK 4.0 beta 3 was installed from the nested evaluation DMG into:

`$HOME/Library/Application Support/Game Porting Toolkit/lib/`

(`external/D3DMetal.framework` + `wine/x86_64-windows/d3d12*.dll`). `mcsoda`
picks it up automatically. Re-install after a new GPTK download with
`./install-gptk-hint.sh` (outer DMG open + nested eval DMG mounted).

### gnutls fix (2026-10-18, ~21:45): exit 5 about 5 s after D3DMetal starts

Symptom: D3DMetal came up, the HUD menu was created, GDK 10006 init and a
second Xbox sign-in returned hr=0, and then the game exited with code 5 about
5 s after the Game Host started (21:35:22 to 21:35:27). There was no `.ips` in
DiagnosticReports and the unified log shows no signal, so this was not a native
crash. The game shut itself down.

Root cause: the repo was moved out of `~/Documents/TEWST`. The live
`libgnutls.30.dylib` and `libhogweed.6.9.dylib` (in both `lib/` and
`lib/wine/x86_64-unix/`) linked gmp, nettle, hogweed, tasn1 and unistring by
**absolute path** under `~/Documents/TEWST/mcsoda/work/x86deps`. The runtime
also never shipped files named `libnettle.8.dylib` or `libhogweed.6.dylib`, so
gnutls had only ever worked because the build tree existed. After the move,
`wine rundll32 bcrypt.dll,...` logs
`err:winediag:gnutls_process_attach failed to load libgnutls, no support for encryption`.
That breaks bcrypt and schannel TLS, so Minecraft's post-sign-in HTTPS fails
and it quits.

Fix (live): each absolute dependency was rewritten to `@loader_path/<real file>`
with `install_name_tool -change`, mapping nettle.8 to `libnettle.8.9.dylib` and
hogweed.6 to `libhogweed.6.9.dylib`, then re-signed ad-hoc. Originals are in
`runtime/dylibs-pre-loaderpath-20261018/`. bcrypt now loads gnutls with no
error. `4-package.sh` now does the same relink at package time.

Verified: a CLI `launcher_service.py play --game-dir .../games/release/latest`
reached the same point (D3DMetal, GDK 10006, two sign-ins with hr=0, HUD) and
stayed up 99 s. It ended only because the test harness killed it. Its leaked
Xodus RAM disk was ejected.

Check after any repackage:
`otool -L runtime/wine/lib/wine/x86_64-unix/libgnutls.30.dylib | rg /Users`
should list only the dylib's own ID line.

### Launch performance (2026-10-18, ~21:20)

I traced every step of a GUI Play: `launcher_service.py play` →
`xbox.prepare_launch` → `launch-experiment.py` → `xodus-cli run` →
`wine-handoff.py` → `MinecraftGameHost`. Most of the suspected waste was
already gated:

- `wineboot -u` runs only when the `ntdll.so` SHA in
  `<prefix>/.blockintosh-engine.json` changes (`launcher_engine.prepare`).
  It costs ~20 s once per mcsoda ntdll rebuild, then never again. Wine's
  own `.update-timestamp` matches `share/wine/wine.inf`, so Wine never
  auto-wineboots either.
- `--install-gameinput` returns early when `GameInputRedist.dll` and the
  service exe are present. regsvr32 and serviceconfig run only on Repair.
- Every registry helper (OEM, user paths, RetinaMode, GameInput) is skipped
  with "Registry setup already present".
- wineserver is already stopped per prefix (`wineserver -k`/`-w`) before
  every Play by `xbox.prepare_launch` → `stop_prefix`, and after the game by
  `clear_registry`. No double servers or winedevice processes survive.
- The whole Python pre-launch takes **0.28 s** (`--setup-only` with Play's
  flags). The `ntdll` hashes and Game Host `codesign --verify` cost ~0.15 s
  each, which is not worth caching.
- DXMT is not loaded alongside GPTK. `WINEDLLPATH` puts `gptk-4.0-3/wine`
  first (0004), so DXMT's `winemetal` never loads. The single MoltenVK
  `VkInstance` comes from win32u's Vulkan GPU enumeration. I left it alone,
  because disabling Vulkan changes the adapter info that D3DMetal sees.
- Auto-start services in the prefix are only Wine's minimum (Eventlog,
  MountMgr, NDIS, nsiproxy, PlugPlay).

Real waste found and fixed:

1. **Leaked Xodus RAM disks.** When a game is killed, Xodus does not
   detach its `ram://` disk. Two were mounted from the 20:46/20:48 test
   launches, each holding a 312 MiB decrypted exe, so ~624 MiB of wired
   RAM was sitting idle. I ejected them, and added `eject_stale_xodus_ramdisks()` to
   `Blockintosh-Beta.app/.../scripts/launch-experiment.py`, called right
   before `xodus-cli run`. It ejects only `/Volumes/Xodus-*` ram disks
   older than 120 s that have no open files (`lsof +D`). It was self-tested
   with a throwaway RAM disk in three states: young (kept), busy (kept), and
   idle (ejected). Backup: `scripts/launch-experiment.py.pre-perf-20261018`.
2. **iCloud was uploading the build tree.** `~/Documents` is iCloud
   Desktop & Documents. `cloudd` was at ~47% CPU and `bird` at ~13% while
   syncing the 6.4 GB `work/`, which also explains the `fileproviderd`
   load seen earlier. `work/` was renamed to `work.nosync`, which iCloud
   skips, and `work` is now a symlink to it, so every script path is
   unchanged. Revert: `rm work && mv work.nosync work`.

Not changed: Blockintosh's `status` poll spawns a short Python process
about every 10 s. That's negligible and lives in the native app.

Retest: quit and relaunch Blockintosh (Python scripts are not codesigned,
so no re-signing is needed), press Play, quit the game, then run
`mount | rg Xodus`. If a game is killed, the next Play logs "Ejected stale
Xodus RAM disk". `ps -axo %cpu,command | rg cloudd` should settle once
iCloud processes the rename.

### 0007 live (2026-10-18, ~21:05): mouse teleport fix

The mouse kept snapping back to one spot in Minecraft. winemac sends absolute
moves, and Valve's Wine 11 wineserver passes those to WM_INPUT as
`MOUSE_MOVE_ABSOLUTE` with pixel coordinates. Native GameInput reads that as
an absolute position. GameHub's wineserver (and Wine 10) send relative deltas
instead. Patch 0007 (`server/queue.c`) restores the delta behaviour.

- Only `bin/wineserver` changed, so there is no ntdll or Game Host hash change.
  The old binary is in `runtime/wineserver-pre-0007-20261018`.
- The winemac clip/warp code matches GameHub. No warp loop was found; the
  earlier 100% CPU was the 0006 libunwind fault loop.
- Live wineserver SHA `d9ba3797…` equals `work/build/server/wineserver`.
- Blockintosh's `build-mcsoda-mouse.py` (Build 22) is **not** needed and will
  not run here. It patched winemac in the author's McSoda 11.0-4 archive.
  Its prepared source is not on disk, `backend/patches/mcsoda/` is empty, and
  the installed `sources.lock.json` has no `mouse_driver` key. It also checks
  ntdll/win32u against McSoda's hashes, but ours are different (0006 ntdll is
  `bc911b00…`). Blockintosh dropped McSoda in build 29 and went back to
  GameHub. GameHub/wine-gamesir fix this in the wineserver, not in the driver:
  its `send_mouse_input` matches ours, its winemac.so has no raw-input logic,
  and `queue.c` hardcodes `MOUSE_MOVE_RELATIVE` with cursor deltas. 0007 does
  the same thing.
- Known limit (GameHub has it too): raw deltas come from the change in cursor
  position. If the game neither clips nor recentres the cursor, the camera
  stops turning at the screen edge. If that shows up, add a winemac patch that
  sends NSEvent `deltaX/Y` as raw-only input (`SEND_HWMSG_NO_MSG`). Only
  winemac.so would change; ntdll would not.

### 0006 live (2026-10-18, ~20:50): Minecraft runs under D3DMetal

Exit 5 after Xbox sign-in was **not** caused by syswow64. It was GPTK's
`libd3dshared` faulting in `pthread_setname_np` / `pthread_setspecific` on a
Windows thread. The cause was that upstream Wine 11 sets macOS GSBASE to the
TEB in PE code. A second thread then looped on faults inside `libunwind`
during exception dispatch, which is the 100% CPU the user saw. Patch 0006
switches ntdll to the CrossOver/GameHub GSBASE model; see `patches/README.md`.

- Only ntdll changed (`ntdll.so` + `ntdll.dll`). The new ntdll.so SHA is
  `bc911b00ec8eea8f887c9d333d42aa295b258c6834797c0a68d1bf49d7cf27a2`.
  Both Game Host plists and binaries were switched from `5aa1654c…` and
  re-signed ad-hoc, and `launcher_game_host.executable()` accepts both.
- The pre-0006 ntdll pair is in `runtime/ntdll-pre-0006-20261018/`. To roll
  back, copy it in, swap the host hash back to `5aa1654c…`, and re-sign.
- Verified with a CLI `launcher_service.py play`. You must export
  `BOM_CREDENTIAL_HELPER=/Applications/Blockintosh-Beta.app/Contents/MacOS/BedrockCredentials`,
  otherwise launch_check reports "sign-in required". GDK init succeeded,
  D3DMetal executed D3D12 command lists, the GPTK HUD menu appeared in
  MinecraftGameHost, there were no access violations, and the game stayed up
  for 2+ minutes until it was killed.
- `wine: failed to load ...syswow64\ntdll.dll c0000135` is harmless. It comes
  from `wineboot -u` (which runs on every ntdll hash change) trying a 32-bit
  helper because the GameHub-made prefix has a `syswow64` dir. wineboot still
  exits 0.
- The `MoltenVK ... VkInstance` log line is also harmless. Something enumerates
  Vulkan (winevulkan); rendering is D3DMetal.
- `mds_stores` and `fileproviderd` were at 100–190% CPU from Spotlight /
  File Provider indexing (probably the `work/` trees), not wine. Consider
  adding `work/` to Spotlight Privacy.

### Blockintosh swap (2026-10-18, evening) — mcsoda + 0005 is LIVE

`runtime/wine` is now mcsoda with patches 0001–0005 and SDL 2.32.6.

- `winemac.so` exports `D _macdrv_functions` (checked with `nm -gU`).
- ntdll SHA is `5aa1654c8b4e0baa7b9f5b69e5174640104403533aa8016f25e78cbf47be41ab`.
  0005 doesn't touch ntdll, so this is the same hash as 0004.
- Both Game Host plists and embedded hashes have been switched from `cb47175c…`
  to `5aa1654c…`. Both bundles are ad-hoc re-signed, and
  `launcher_game_host.executable()` accepts them.
- Kept trees under `runtime/`:
  - `wine.gamehub-live-20261018`: the GameHub copy that was live until now
  - `wine.bak-pre-mcsoda-gptk-20261018`: the original GameHub backup
  - `wine.mcsoda-gptk-no-macdrv-functions-20261018`: the previous mcsoda build
  - `wine.mcsoda-failed-20261018`: the first failed attempt

  The last two can be deleted.
- Smoke-tested: `wineboot -u` and `notepad` start cleanly under the swapped
  runtime. **Minecraft under D3DMetal has not been run yet.** That is the next
  check.

To go back to GameHub, swap `runtime/wine` with `wine.gamehub-live-20261018`
and put the plist and embedded hash back to `cb47175c…`, then re-sign both
hosts.

Debugging a D3DMetal present failure: add `+macdrv_d3dmtl` to the debug
channels. Every hook in the table traces under that channel.

### Controllers — no difference between mcsoda and GameHub in the HID path

Evidence was gathered on 2026-10-18 by running `wineboot -u` with
`+hid,+plugplay` on both runtimes and diffing binaries:

- Both builds start the SDL and IOHID buses. Both create the virtual HID
  mouse and keyboard and their `Enum\HID\…` keys, so hidclass works.
- `winebus.so` from both builds imports the same SDL symbols and sets the same
  hints. Both carry Valve's policy of ignoring IOHID ("hidraw") gamepads in
  favour of SDL unless a device is whitelisted.
- SDL already sets `GCController.shouldMonitorBackgroundEvents`, so
  `winedevice.exe` running in the background is not the problem.
- The PE side (`winebus.sys`, `hidclass.sys`, `xinput1_4`, `dinput8`,
  `windows.gaming.input`) only differs in debug info.
- The one binary difference on the gamepad path was SDL: GameHub ships
  Homebrew's 2.32.6, mcsoda had 2.30.10. `config.sh` is now on 2.32.6 and the
  live runtime uses it.

No controller was connected, so this has not been confirmed end-to-end. If
pads still don't work, plug one in and run:

    WINEDEBUG=+hid wine wineboot -u 2>&1 | rg -i "sdl|creating|ignoring"

This shows whether SDL sees the device (`creating non-hidraw device vid:pid`).
After that, run the Blockintosh `--gameinput-probe` to test GameInput.

### Controller latency fix (2026-10-18)

The connected Xbox Series controller exposed the real difference. The input
path is macOS HID/GCController -> SDL -> winebus -> winehid/hidclass ->
XInput/Windows.Gaming.Input -> Microsoft's native GameInput runtime. Both Wine
builds use event-driven HID reads, the same GameInput registration, and a
10 ms `SDL_WaitEventTimeout`; there is no 200 ms HID poll on this path.

McSoda's SDL 2.32.6 was built with minimum macOS 27.0 / SDK 27.0. GameHub's
known-good SDL 2.32.6 targets macOS 14.0 / SDK 14.5. The macOS-27 build is the
controller-latency regression; version equality hid the deployment-target
difference. The two GameHub SDL dylib copies were installed into live McSoda
(`lib/` and `lib/wine/x86_64-unix/`). SHA-256:
`8cc23b043bfd9d5ef41c0791e4031dc99c7e80cec58ba8bbcb367197d3c5a1c3`.

`0-bootstrap.sh` now builds SDL with `MACOSX_DEPLOYMENT_TARGET=14.0`. Rebuild
SDL from a clean `work/x86deps/lib/libSDL2*` before the next full package.

### Earlier bugs (fixed, do not relitigate)

1. **wineboot "deadlock"** — missing wine-mono → `mscoree` →
   `appwiz.cpl install_mono` → `WaitForSingleObject` forever. Not msync.
2. **freetype missing at runtime** — SONAME dlopen; dylib now sits next to
   `win32u.so` (`LC_RPATH @loader_path`).
3. **mcsoda without 0003** — DXMT metal-view / missing GPTK ntdll hooks.
4. **mcsoda without 0004** — DXMT builtins beat GPTK (`WINEDLLPATH` order).
5. **mcsoda without 0005** — no `macdrv_functions` for GPTK Metal view.
6. **mcsoda without 0006** — exit 5 after sign-in: libd3dshared pthread fault
   (GSBASE = TEB) plus a fault-loop at 100% CPU.
7. **Exit 5 ~5 s after D3DMetal/HUD** — gnutls deps linked by absolute
   build-tree path; repo move broke TLS. Relinked to `@loader_path`.

## Layout

```
0-bootstrap.sh   arm64 tools + x86_64 freetype/SDL2/gnutls stack + MoltenVK
1-fetch.sh       Valve wine, DXMT src, mono/gecko/DXMT-builtin tarballs
2-patch.sh       patches/series + make_requests / make_specfiles / make_vulkan
3-build.sh       configure --with-freetype,gnutls,sdl,vulkan + make
4-package.sh     install + runtime dylibs + mono/gecko/DXMT + mcsoda wrapper
install-gptk-hint.sh   find D3DMetal after you install GPTK
check.sh         preconditions
config.sh        versions / URLs / paths
patches/         see patches/README.md
work/            scratch (deletable)
```

## Patches

Six, applied in order by `2-patch.sh`:

- **`0001-macos-build-portability.patch`** — macOS compile/link for Valve tree
- **`0002-msync-from-crossover-11.0.patch`** — msync from CrossOver / winecx
  `ff-wine-11.0`
- **`0003-gptk-non-native-code-regions.patch`** — GPTK `WINE_GPTK_LIBD3DSHARED_PATH`,
  `register_non_native_code_region`, MS-ABI `GPT_ABI_WRAPPER` thunks for selected
  `Nt*` syscalls. On macOS, wrappers use a public `.globl` asm export (not Wine's
  default `.private_extern`) so unix `.so` peers (e.g. `nsiproxy.so`) can link
  `_NtSetEvent` / `_NtClose`.
- **`0004-winedllpath-prepend.patch`** — `WINEDLLPATH_PREPEND` then `WINEDLLPATH`
  before the install tree in `set_dll_path()`. Required so Blockintosh GPTK
  forwarders win over McSoda's built-in DXMT `d3d11`/`dxgi` when overrides use `=b`.
- **`0005-winemac-d3dmetal-macdrv-functions.patch`**: exports `macdrv_functions`
  for GPTK. It is CodeWeavers' `d3dmetal.c` plus PE registry callbacks, and it
  gives each window a driver-owned client surface for D3DMetal's Metal view.
  It also exports win32u's `add_window_client_surface`. See `patches/README.md`.
- **`0006-macos-keep-pthread-gsbase-for-gptk.patch`**: macOS GSBASE stays on
  the pthread TSD (CrossOver model), so native D3DMetal code can run on
  Windows threads. Changes ntdll (hash `bc911b00…`).

Do **not** use `marzent/wine-msync` (Wine 9.x; rejects hard on 11.0).

## Toolchain notes

- Tools from `/opt/homebrew` (arm64). Libraries into `work/x86deps` as x86_64.
- `PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig` so arm64 Homebrew `.pc` files cannot
  leak. A stub `zlib.pc` (system libz) satisfies freetype2's `Requires: zlib`.
- configure triplet: `--build=x86_64-apple-darwin --host=x86_64-apple-darwin`

## Hard limits

- No 32-bit Windows apps (Rosetta).
- No anti-cheat (Proton EAC is Linux `.so`).
- No X11 fullscreen hack / compositor bypass.

## Architecture decisions

Unchanged — see `../arm64ec-macos-feasibility.md` and
`../mapjit-wine-probe.md`. This build is Rosetta x86_64 Wine. Rosetta is
general-purpose through macOS 27; this machine is 27.0.1.

## Suggested next work

1. Play-test Minecraft from the GUI. CPU was ~400% during load; compare with
   GameHub at the same scene before treating it as a regression.
2. Test a real controller (see Controllers section).
3. Remaining gaps vs GameHub: no `winegstreamer`, no ICU 68 DLLs.
4. Optional: rebuild DXMT from source if `winemetal` ABI drifts.

## Environment

- macOS 27.0.1 (build 26A434), Apple Silicon
- Xcode CLT 27, Homebrew `/opt/homebrew`, Rosetta 2
- GPTK 4.0 beta 3 installed under `~/Library/Application Support/Game Porting Toolkit/`
- Wine: `ValveSoftware/wine` `experimental_11.0` @ `7fc704e`
- DXMT v0.80 builtin, wine-mono 10.4.1, wine-gecko 2.47.4, MoltenVK 1.4.2, SDL 2.32.6
- Blockintosh runtime wine = **mcsoda** with patches 0001–0007 (ntdll
  `bc911b00…`, wineserver `d9ba3797…`) and gnutls relinked to
  `@loader_path`. GameHub rollback: `wine.gamehub-live-20261018`
