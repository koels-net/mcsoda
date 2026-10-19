#!/usr/bin/env bash
# Configures and builds Wine as x86_64, to run under Rosetta 2.
source "$(dirname "$0")/config.sh"

export PATH="$BREW_PREFIX/opt/bison/bin:$BREW_PREFIX/opt/flex/bin:$BREW_PREFIX/bin:$PATH"
# Only $DEPS is searched for libraries: pointing pkg-config at the arm64
# Homebrew prefix would find arm64 .dylibs that cannot link into this build.
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
# freetype2.pc Requires: zlib — provide a stub pointing at macOS libz.
if [[ ! -f "$DEPS/lib/pkgconfig/zlib.pc" ]]; then
  cat > "$DEPS/lib/pkgconfig/zlib.pc" <<'ZPC'
prefix=/usr
libdir=/usr/lib
includedir=/usr/include
Name: zlib
Description: zlib compression library (macOS system)
Version: 1.2.12
Libs: -lz
Cflags:
ZPC
fi
# The generated Makefile invokes bare `bison`/`flex`, which would pick up
# macOS's bison 2.3 - too old for Wine's grammars. Naming them here makes
# configure bake absolute paths in, so `make` works outside this script too.
export BISON="$BREW_PREFIX/opt/bison/bin/bison"
export FLEX="$BREW_PREFIX/opt/flex/bin/flex"
export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
export CPPFLAGS="-I$DEPS/include"
export LDFLAGS="-L$DEPS/lib"

# Wine ships a generated configure in release tarballs but not in git.
if [[ ! -x "$SRC/configure" ]]; then
  echo ">> generating configure"
  ( cd "$SRC" && autoreconf -i )
fi

mkdir -p "$BUILD" && cd "$BUILD"

# --without-x: macOS uses winemac.drv, not winex11.drv. Building the X11 driver
# against XQuartz would give a second, worse graphics path.
# --enable-archs=x86_64: no i386, because Rosetta 2 cannot translate 32-bit x86.
# configure guesses the target from uname, which says arm64 even when CC is
# building x86_64, so the triplet has to be stated. build == host keeps this a
# native build rather than a cross-compile: Rosetta runs the test binaries.
"$SRC/configure" \
  --build=x86_64-apple-darwin \
  --host=x86_64-apple-darwin \
  --prefix="$PREFIX" \
  --enable-archs="$ARCHS" \
  --disable-tests \
  --without-x \
  --with-coreaudio \
  --with-freetype \
  --with-gnutls \
  --with-sdl \
  --with-vulkan

make -j"$(sysctl -n hw.ncpu)"
echo ">> built in $BUILD"
