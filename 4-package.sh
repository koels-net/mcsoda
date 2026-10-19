#!/usr/bin/env bash
# Installs Wine into DIST and wires up runtime deps + graphics layers.
source "$(dirname "$0")/config.sh"

rm -rf "$DIST" && mkdir -p "$DIST"
cd "$BUILD"
make install DESTDIR="$DIST"

PREFIX_ROOT="$DIST$PREFIX"
UNIX_LIB="$PREFIX_ROOT/lib/wine/x86_64-unix"
WIN_LIB="$PREFIX_ROOT/lib/wine/x86_64-windows"
install -d "$PREFIX_ROOT/lib" "$UNIX_LIB" "$WIN_LIB"

# Runtime dylibs that Wine dlopens by SONAME. Drop next to the unix .so
# (win32u/ntdll already carry LC_RPATH @loader_path) and under lib/ for the
# mcsoda wrapper's DYLD_FALLBACK_LIBRARY_PATH.
echo ">> installing runtime dylibs"
for lib in \
  libfreetype.6.dylib \
  libSDL2-2.0.0.dylib \
  libgnutls.30.dylib \
  libgmp.10.dylib \
  libnettle.8.9.dylib \
  libhogweed.6.9.dylib \
  libtasn1.6.dylib \
  libunistring.5.dylib \
  libMoltenVK.dylib
do
  [[ -f "$DEPS/lib/$lib" ]] || { echo "   missing $DEPS/lib/$lib" >&2; continue; }
  cp "$DEPS/lib/$lib" "$UNIX_LIB/"
  cp "$DEPS/lib/$lib" "$PREFIX_ROOT/lib/"
done
# Stable SONAME symlinks in both places
(
  cd "$UNIX_LIB"
  ln -sf libfreetype.6.dylib libfreetype.dylib
  ln -sf libSDL2-2.0.0.dylib libSDL2.dylib
  ln -sf libgnutls.30.dylib libgnutls.dylib
  ln -sf libgmp.10.dylib libgmp.dylib
  ln -sf libnettle.8.9.dylib libnettle.dylib
  ln -sf libhogweed.6.9.dylib libhogweed.dylib
  ln -sf libtasn1.6.dylib libtasn1.dylib
  ln -sf libunistring.5.dylib libunistring.dylib
)
(
  cd "$PREFIX_ROOT/lib"
  ln -sf libfreetype.6.dylib libfreetype.dylib
  ln -sf libSDL2-2.0.0.dylib libSDL2.dylib
  ln -sf libgnutls.30.dylib libgnutls.dylib
  ln -sf libgmp.10.dylib libgmp.dylib
  ln -sf libnettle.8.9.dylib libnettle.dylib
  ln -sf libhogweed.6.9.dylib libhogweed.dylib
  ln -sf libtasn1.6.dylib libtasn1.dylib
  ln -sf libunistring.5.dylib libunistring.dylib
)
# Inter-dylib refs are absolute build-tree paths; without this gnutls only
# loads while the build tree exists at the path it was built in.
for dir in "$UNIX_LIB" "$PREFIX_ROOT/lib"; do
  for f in "$dir"/lib{gnutls.30,hogweed.6.9}.dylib; do
    [[ -f "$f" ]] || continue
    otool -L "$f" | tail -n +3 | awk '{print $1}' | { grep -vE '^(/usr/lib|/System|@)' || true; } | while read -r dep; do
      b=$(basename "$dep")
      case "$b" in libnettle.8.dylib) b=libnettle.8.9.dylib;; libhogweed.6.dylib) b=libhogweed.6.9.dylib;; esac
      install_name_tool -change "$dep" "@loader_path/$b" "$f" 2>/dev/null
    done
    codesign -f -s - "$f"
  done
done
[[ -f "$DEPS/lib/MoltenVK_icd.json" ]] && cp "$DEPS/lib/MoltenVK_icd.json" "$PREFIX_ROOT/lib/"

# wine-mono: without this, wineboot hangs in mscoree → appwiz install_mono.
MONO_TAR="$WORK/deps-src/wine-mono-${WINE_MONO_VERSION}-x86.tar.xz"
if [[ -f "$MONO_TAR" ]]; then
  echo ">> installing wine-mono $WINE_MONO_VERSION"
  install -d "$PREFIX_ROOT/share/wine/mono"
  tar -C "$PREFIX_ROOT/share/wine/mono" -xf "$MONO_TAR"
else
  echo ">> WARNING: no $MONO_TAR — wineboot will hang on mono install dialog" >&2
fi

# wine-gecko: same class of hang for mshtml if missing.
GECKO_TAR="$WORK/deps-src/wine-gecko-${WINE_GECKO_VERSION}-x86_64.tar.xz"
if [[ -f "$GECKO_TAR" ]]; then
  echo ">> installing wine-gecko $WINE_GECKO_VERSION"
  install -d "$PREFIX_ROOT/share/wine/gecko"
  tar -C "$PREFIX_ROOT/share/wine/gecko" -xf "$GECKO_TAR"
else
  echo ">> WARNING: no $GECKO_TAR — HTML apps will prompt for gecko" >&2
fi

# DXMT builtin release: d3d11/dxgi/d3d10core + winemetal unixlib.
DXMT_TGZ="$WORK/deps-src/dxmt-${DXMT_VERSION}-builtin.tar.gz"
if [[ -f "$DXMT_TGZ" ]]; then
  echo ">> installing DXMT $DXMT_VERSION"
  tmp="$WORK/deps-src/dxmt-extract"
  rm -rf "$tmp" && mkdir -p "$tmp"
  tar -C "$tmp" -xzf "$DXMT_TGZ"
  # tarball root is v0.80/ (or similar tag)
  root="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
  cp "$root"/x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll "$WIN_LIB/"
  cp "$root"/x86_64-unix/winemetal.so "$UNIX_LIB/"
  # optional NVAPI stubs from the same release
  [[ -f "$root/x86_64-windows/nvapi64.dll" ]] && cp "$root"/x86_64-windows/nvapi64.dll "$WIN_LIB/"
  [[ -f "$root/x86_64-windows/nvngx.dll" ]] && cp "$root"/x86_64-windows/nvngx.dll "$WIN_LIB/"
else
  echo ">> WARNING: no $DXMT_TGZ — D3D10/11 falls back to wined3d" >&2
  echo "   run ./1-fetch.sh first" >&2
fi

# D3DMetal is NOT copied. Apple's Game Porting Toolkit licence covers
# evaluation and development use and does not grant redistribution rights.
# The wrapper points Wine at a user-installed copy (see install-gptk-hint.sh).
cat > "$PREFIX_ROOT/bin/mcsoda" <<'WRAP'
#!/usr/bin/env bash
# mcsoda launcher
export WINEMSYNC=${WINEMSYNC:-1}
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
UNIX="$HERE/../lib/wine/x86_64-unix"
export DYLD_FALLBACK_LIBRARY_PATH="$LIB:${DYLD_FALLBACK_LIBRARY_PATH:-}"
# MoltenVK ICD for winevulkan
if [[ -f "$LIB/MoltenVK_icd.json" ]]; then
  export VK_ICD_FILENAMES="$LIB/MoltenVK_icd.json${VK_ICD_FILENAMES:+:$VK_ICD_FILENAMES}"
fi
# Prefer DXMT builtins for D3D10/11; D3D12 comes from GPTK when present
OVERRIDES="d3d11,dxgi,d3d10core,winemetal=b"

D3DMETAL="${GPTK_D3DMETAL:-}"
if [[ ! -d "$D3DMETAL" ]]; then
  for cand in \
    "$HOME/Library/Application Support/Game Porting Toolkit/lib/external" \
    "/usr/local/lib/external" \
    "/opt/game-porting-toolkit/lib/external"
  do
    [[ -d "$cand" ]] && D3DMETAL="$cand" && break
  done
fi
if [[ -d "$D3DMETAL" ]]; then
  GPTK_LIB="$(cd "$D3DMETAL/.." && pwd)"
  GPTK_WIN="$GPTK_LIB/wine/x86_64-windows"
  export DYLD_FALLBACK_LIBRARY_PATH="$D3DMETAL:$DYLD_FALLBACK_LIBRARY_PATH"
  export DYLD_FRAMEWORK_PATH="$D3DMETAL${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
  export WINEDLLPATH="$GPTK_WIN:$D3DMETAL${WINEDLLPATH:+:$WINEDLLPATH}"
  # Wine loads d3d12.so from the unix lib dir; point at Apple's shared dylib
  if [[ -f "$D3DMETAL/libd3dshared.dylib" && -d "$UNIX" ]]; then
    ln -sf "$D3DMETAL/libd3dshared.dylib" "$UNIX/d3d12.so"
    ln -sf "$D3DMETAL/libd3dshared.dylib" "$UNIX/d3d12core.so"
  fi
  OVERRIDES="d3d12,d3d12core=n;$OVERRIDES"
else
  echo "mcsoda: no D3DMetal found; Direct3D 12 titles will not run." >&2
  echo "mcsoda: run ./install-gptk-hint.sh after installing GPTK." >&2
fi
export WINEDLLOVERRIDES="$OVERRIDES${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
exec "$HERE/wine" "$@"
WRAP
chmod +x "$PREFIX_ROOT/bin/mcsoda"

echo ">> packaged into $DIST"
