#!/usr/bin/env bash
# Installs the build toolchain and the x86_64 libraries Wine links against.
#
# Two halves, for two different reasons:
#   - Tools (bison, flex, mingw-w64, pkgconf) only have to emit correct output,
#     so the native arm64 Homebrew serves them.
#   - Libraries get linked into the x86_64 unix side, so they must be x86_64.
#     Homebrew will not install an Intel prefix on Apple Silicon any more (its
#     installer aborts unless `uname -m` is arm64), so these are built from
#     source into $DEPS. macOS system libraries are already universal.
source "$(dirname "$0")/config.sh"
set -euo pipefail

[[ -x "$BREW" ]] || { echo "no Homebrew at $BREW"; exit 1; }

echo ">> installing build tools (arm64)"
"$BREW" install bison flex mingw-w64 pkgconf cmake ninja autoconf automake meson

# Same floor as Wine: without an explicit deployment target clang defaults to
# the build machine's OS, so dependency dylibs record minos 27.0 and can link
# symbols older systems do not export. -Werror=unguarded-availability-new turns
# that into a build failure here instead of a dlopen failure on a user's Mac.
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
export CC="clang -arch x86_64 -Werror=unguarded-availability-new"
export CXX="clang++ -arch x86_64 -Werror=unguarded-availability-new"

# Rebuild when MACOS_MIN changes: the early-return checks below only look for
# the dylib name, so a prior 27.0 build would otherwise be kept forever.
DEPS_STAMP="$DEPS/.macos_min"
if [[ ! -f "$DEPS_STAMP" ]] || [[ "$(cat "$DEPS_STAMP")" != "$MACOS_MIN" ]]; then
  echo ">> clearing $DEPS for MACOS_MIN=$MACOS_MIN"
  rm -rf "$DEPS"
fi

# lib/pkgconfig must exist before the zlib.pc stub below, which is written
# before the first dependency build would have created it.
mkdir -p "$DEPS/lib/pkgconfig" "$DEPS/include" "$WORK/deps-src"
echo "$MACOS_MIN" > "$DEPS_STAMP"
NPROC="$(sysctl -n hw.ncpu)"
export PATH="$BREW_PREFIX/bin:$PATH"
export CPPFLAGS="-I$DEPS/include"
export LDFLAGS="-L$DEPS/lib"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

fetch() {
  local url="$1" out="$2"
  [[ -f "$out" ]] || curl -fL -o "$out" "$url"
}

build_freetype() {
  local v="$FREETYPE_VERSION" d="$WORK/deps-src"
  [[ -f "$DEPS/lib/libfreetype.dylib" ]] && { echo ">> freetype already built"; return; }
  echo ">> building freetype $v (x86_64)"
  fetch "https://download.savannah.gnu.org/releases/freetype/freetype-$v.tar.xz" "$d/freetype-$v.tar.xz"
  rm -rf "$d/freetype-$v"
  tar -C "$d" -xf "$d/freetype-$v.tar.xz"
  cd "$d/freetype-$v"
  # zlib is a system library and universal. brotli, harfbuzz, libpng and
  # bzip2 are not present as x86_64, and Wine needs none of them from
  # freetype: png/bzip2 only add colour-bitmap and compressed-font support.
  ./configure --prefix="$DEPS" --host=x86_64-apple-darwin --build=x86_64-apple-darwin \
    --with-brotli=no --with-harfbuzz=no --with-png=no --with-bzip2=no
  make -j"$NPROC" && make install
}

build_sdl2() {
  local v="$SDL2_VERSION" d="$WORK/deps-src"
  [[ -f "$DEPS/lib/libSDL2.dylib" ]] && { echo ">> SDL2 already built"; return; }
  echo ">> building SDL2 $v (x86_64)"
  fetch "https://github.com/libsdl-org/SDL/releases/download/release-$v/SDL2-$v.tar.gz" "$d/SDL2-$v.tar.gz"
  rm -rf "$d/SDL2-$v"
  tar -C "$d" -xzf "$d/SDL2-$v.tar.gz"
  cd "$d/SDL2-$v"
  ./configure --prefix="$DEPS" --host=x86_64-apple-darwin --build=x86_64-apple-darwin \
    --disable-video-x11 --disable-video-wayland --enable-shared
  make -j"$NPROC" && make install
}

build_gmp() {
  local v="$GMP_VERSION" d="$WORK/deps-src"
  [[ -f "$DEPS/lib/libgmp.dylib" ]] && { echo ">> gmp already built"; return; }
  echo ">> building gmp $v (x86_64)"
  fetch "https://gmplib.org/download/gmp/gmp-$v.tar.xz" "$d/gmp-$v.tar.xz"
  rm -rf "$d/gmp-$v"
  tar -C "$d" -xf "$d/gmp-$v.tar.xz"
  cd "$d/gmp-$v"
  ./configure --prefix="$DEPS" --host=x86_64-apple-darwin --build=x86_64-apple-darwin --enable-shared
  make -j"$NPROC" && make install
}

build_libunistring() {
  local v="$LIBUNISTRING_VERSION" d="$WORK/deps-src"
  [[ -f "$DEPS/lib/libunistring.dylib" ]] && { echo ">> libunistring already built"; return; }
  echo ">> building libunistring $v (x86_64)"
  fetch "https://ftp.gnu.org/gnu/libunistring/libunistring-$v.tar.gz" "$d/libunistring-$v.tar.gz"
  rm -rf "$d/libunistring-$v"
  tar -C "$d" -xzf "$d/libunistring-$v.tar.gz"
  cd "$d/libunistring-$v"
  ./configure --prefix="$DEPS" --host=x86_64-apple-darwin --build=x86_64-apple-darwin --enable-shared
  make -j"$NPROC" && make install
}

build_libtasn1() {
  local v="$LIBTASN1_VERSION" d="$WORK/deps-src"
  [[ -f "$DEPS/lib/libtasn1.dylib" ]] && { echo ">> libtasn1 already built"; return; }
  echo ">> building libtasn1 $v (x86_64)"
  fetch "https://ftp.gnu.org/gnu/libtasn1/libtasn1-$v.tar.gz" "$d/libtasn1-$v.tar.gz"
  rm -rf "$d/libtasn1-$v"
  tar -C "$d" -xzf "$d/libtasn1-$v.tar.gz"
  cd "$d/libtasn1-$v"
  ./configure --prefix="$DEPS" --host=x86_64-apple-darwin --build=x86_64-apple-darwin --enable-shared
  make -j"$NPROC" && make install
}

build_nettle() {
  local v="$NETTLE_VERSION" d="$WORK/deps-src"
  [[ -f "$DEPS/lib/libnettle.dylib" ]] && { echo ">> nettle already built"; return; }
  echo ">> building nettle $v (x86_64)"
  fetch "https://ftp.gnu.org/gnu/nettle/nettle-$v.tar.gz" "$d/nettle-$v.tar.gz"
  rm -rf "$d/nettle-$v"
  tar -C "$d" -xzf "$d/nettle-$v.tar.gz"
  cd "$d/nettle-$v"
  ./configure --prefix="$DEPS" --host=x86_64-apple-darwin --build=x86_64-apple-darwin \
    --enable-shared --disable-openssl
  make -j"$NPROC" && make install
}

build_gnutls() {
  local v="$GNUTLS_VERSION" d="$WORK/deps-src"
  [[ -f "$DEPS/lib/libgnutls.dylib" ]] && { echo ">> gnutls already built"; return; }
  echo ">> building gnutls $v (x86_64)"
  fetch "https://www.gnupg.org/ftp/gcrypt/gnutls/v${v%.*}/gnutls-$v.tar.xz" "$d/gnutls-$v.tar.xz"
  rm -rf "$d/gnutls-$v"
  tar -C "$d" -xf "$d/gnutls-$v.tar.xz"
  cd "$d/gnutls-$v"
  ./configure --prefix="$DEPS" --host=x86_64-apple-darwin --build=x86_64-apple-darwin \
    --enable-shared --disable-static --disable-doc --disable-tools --disable-tests \
    --without-p11-kit --with-included-unistring=no --disable-libdane --without-tpm --without-tpm2
  make -j"$NPROC" && make install
}

install_moltenvk() {
  local v="$MOLTENVK_VERSION" d="$WORK/deps-src"
  [[ -f "$DEPS/lib/libMoltenVK.dylib" ]] && { echo ">> MoltenVK already installed"; return; }
  echo ">> installing MoltenVK $v (universal dylib)"
  fetch "https://github.com/KhronosGroup/MoltenVK/releases/download/v$v/MoltenVK-macos.tar" \
    "$d/MoltenVK-macos.tar"
  local tmp="$d/MoltenVK-extract"
  rm -rf "$tmp" && mkdir -p "$tmp"
  tar -C "$tmp" -xf "$d/MoltenVK-macos.tar"
  cp "$tmp/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$DEPS/lib/"
  cp "$tmp/MoltenVK/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json" "$DEPS/lib/"
  mkdir -p "$DEPS/include"
  cp -R "$tmp/MoltenVK/MoltenVK/include/vulkan" "$DEPS/include/"
  [[ -d "$tmp/MoltenVK/MoltenVK/include/vk_video" ]] && \
    cp -R "$tmp/MoltenVK/MoltenVK/include/vk_video" "$DEPS/include/"
  cat > "$DEPS/lib/pkgconfig/MoltenVK.pc" <<EOF
prefix=$DEPS
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: MoltenVK
Description: Vulkan driver for Metal
Version: $v
Libs: -L\${libdir} -lMoltenVK
Cflags: -I\${includedir}
EOF
}

# freetype2.pc Requires: zlib. macOS ships libz; stub the .pc so pkg-config
# stays confined to $DEPS (PKG_CONFIG_LIBDIR) without pulling arm64 Homebrew.
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

build_freetype
build_sdl2
build_gmp
build_libunistring
build_libtasn1
build_nettle
build_gnutls
install_moltenvk

# MoltenVK is a prebuilt universal binary (minos 12.0); everything we compile
# must genuinely target MACOS_MIN. Fail here rather than ship a 27.0 dylib.
minos_of() { otool -l "$1" 2>/dev/null | awk '/minos/{print $2; exit}'; }
version_gt() {
  # True if $1 > $2 (dotted numeric).
  printf '%s\n%s\n' "$1" "$2" | sort -V | head -1 | grep -qx "$2" && [[ "$1" != "$2" ]]
}
echo ">> verifying dependency minos <= $MACOS_MIN"
fail_minos=0
for f in "$DEPS"/lib/*.dylib; do
  [[ -f "$f" ]] || continue
  base=$(basename "$f")
  [[ "$base" == libMoltenVK.dylib ]] && continue
  minos=$(minos_of "$f")
  if [[ -z "$minos" ]]; then
    echo "  FAIL  $base: no minos"; fail_minos=1; continue
  fi
  if version_gt "$minos" "$MACOS_MIN"; then
    echo "  FAIL  $base: minos $minos > $MACOS_MIN"; fail_minos=1
  else
    echo "  ok    $base minos $minos"
  fi
done
(( fail_minos )) && { echo "dependency deployment target check failed"; exit 1; }

echo
echo ">> done. x86_64 deps in $DEPS (MACOS_MIN=$MACOS_MIN)"
echo ">> run ./check.sh"
