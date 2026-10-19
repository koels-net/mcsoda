#!/usr/bin/env bash
# Single source of truth for the mcsoda build. Sourced by every other script.
set -euo pipefail

# --- Wine base -------------------------------------------------------------
# Valve's Wine fork. Bottles' Soda runner tracks the bleeding-edge 11.0 line
# (see _bleeding_tag in bottlesdevs/build-tools runners/vaniglia/wine-tkg-valve.cfg),
# so we track the matching Valve branch rather than upstream Wine.
WINE_REPO="https://github.com/ValveSoftware/wine.git"
WINE_BRANCH="experimental_11.0"

# --- msync -----------------------------------------------------------------
# Mach-semaphore synchronisation. Taken from CodeWeavers' published CrossOver
# sources, which carry msync already rebased onto Wine 11.0 - the same base as
# the Valve branch above. LGPL-2.1, like the rest of Wine.
#
# The sources are embedded in patches/0002, so nothing is fetched at build
# time. These two values record where they came from.
MSYNC_SOURCE_REPO="https://github.com/marzent/winecx.git"   # mirror of media.codeweavers.com/pub/crossover/source/
MSYNC_SOURCE_BRANCH="ff-wine-11.0"

# --- Build layout ----------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/work"
SRC="$WORK/wine"
BUILD="$WORK/build"
DIST="$WORK/dist"
PREFIX="/usr/local/opt/mcsoda"

# --- Toolchain -------------------------------------------------------------
# Everything on the unix side is x86_64 Mach-O and runs under Rosetta 2.
# Rosetta 2 does not translate 32-bit x86, so there is no i386 arch here and
# 32-bit Windows applications will not run. This is a hard limit, not a TODO.
ARCHS="x86_64"

# Build *tools* (bison, flex, mingw-w64, pkgconf) are architecture-irrelevant:
# they only have to emit correct output, so the native arm64 Homebrew is
# fine. Homebrew no longer installs an Intel prefix on Apple Silicon - its
# installer aborts unless `uname -m` is arm64 - so the old /usr/local approach
# is not available.
BREW="/opt/homebrew/bin/brew"
BREW_PREFIX="/opt/homebrew"

# Libraries linked into the x86_64 unix side must themselves be x86_64. macOS
# system libraries and frameworks are universal (Rosetta needs them to be), so
# only non-system dependencies have to be built. They go here.
DEPS="$WORK/x86deps"
FREETYPE_VERSION="2.13.3"
SDL2_VERSION="2.32.6"
GMP_VERSION="6.3.0"
NETTLE_VERSION="3.10"
LIBTASN1_VERSION="4.19.0"
LIBUNISTRING_VERSION="1.3"
GNUTLS_VERSION="3.8.8"
MOLTENVK_VERSION="1.4.2"

# wine-mono must match WINE_MONO_VERSION in dlls/mscoree/mscoree_private.h.
# Without it, mscoree DllRegisterServer opens appwiz.cpl install_mono and
# WaitForSingleObject's the GUI forever — that was the wineboot "deadlock".
WINE_MONO_VERSION="10.4.1"
WINE_MONO_URL="https://dl.winehq.org/wine/wine-mono/${WINE_MONO_VERSION}/wine-mono-${WINE_MONO_VERSION}-x86.tar.xz"

# wine-gecko must match GECKO_VERSION in dlls/appwiz.cpl/addons.c / mshtml.
WINE_GECKO_VERSION="2.47.4"
WINE_GECKO_URL="https://dl.winehq.org/wine/wine-gecko/${WINE_GECKO_VERSION}/wine-gecko-${WINE_GECKO_VERSION}-x86_64.tar.xz"

# --- Graphics --------------------------------------------------------------
# D3D10/11 -> Metal via DXMT (open source, redistributable).
# We ship the upstream "builtin" release tarball rather than rebuilding LLVM
# 15 from source (multi-hour). Source clone kept for reference.
DXMT_REPO="https://github.com/3Shain/dxmt.git"
DXMT_VERSION="v0.80"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/${DXMT_VERSION}/dxmt-${DXMT_VERSION}-builtin.tar.gz"

# D3D12 -> D3DMetal from the user's own GPTK install. Apple's GPTK licence
# does not permit redistributing D3DMetal, so it is referenced at runtime
# and never copied into the bundle.
GPTK_D3DMETAL="${GPTK_D3DMETAL:-$HOME/Library/Application Support/Game Porting Toolkit/lib/external}"
