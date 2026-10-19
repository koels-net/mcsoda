#!/usr/bin/env bash
# Precondition check. Run this before anything else; it changes nothing.
# Exits non-zero if the machine cannot produce a working build.
source "$(dirname "$0")/config.sh"

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

echo "mcsoda preconditions"

[[ "$(uname -m)" == "arm64" ]] && ok "Apple Silicon host" || warn "not arm64; this build targets Apple Silicon"

if /usr/bin/pgrep -xq oahd; then ok "Rosetta 2 running"; else
  bad "Rosetta 2 not installed: softwareupdate --install-rosetta"
fi

if arch -x86_64 /usr/bin/true 2>/dev/null; then ok "can exec x86_64"; else
  bad "cannot exec x86_64 binaries"
fi

if [[ -x "$BREW" ]]; then ok "Homebrew (arm64) at $BREW"; else
  bad "no Homebrew at $BREW"
fi

missing=()
for t in bison flex pkgconf mingw-w64 autoconf; do
  "$BREW" list --versions "$t" >/dev/null 2>&1 || missing+=("$t")
done
if (( ${#missing[@]} )); then bad "missing build tools: ${missing[*]} (run ./0-bootstrap.sh)"
else ok "build tools installed"; fi

need_dylib() {
  local name="$1" file="$2"
  if [[ -f "$DEPS/lib/$file" ]]; then ok "x86_64 $name in $DEPS"
  else bad "no x86_64 $name ($file) in $DEPS (run ./0-bootstrap.sh)"; fi
}
need_dylib freetype libfreetype.6.dylib
need_dylib SDL2 libSDL2.dylib
need_dylib gnutls libgnutls.dylib
need_dylib MoltenVK libMoltenVK.dylib

for label_url_out in \
  "wine-mono $WINE_MONO_VERSION|$WORK/deps-src/wine-mono-${WINE_MONO_VERSION}-x86.tar.xz" \
  "wine-gecko $WINE_GECKO_VERSION|$WORK/deps-src/wine-gecko-${WINE_GECKO_VERSION}-x86_64.tar.xz" \
  "DXMT $DXMT_VERSION|$WORK/deps-src/dxmt-${DXMT_VERSION}-builtin.tar.gz"
do
  label="${label_url_out%%|*}"
  path="${label_url_out#*|}"
  if [[ -f "$path" ]]; then ok "$label tarball"
  else warn "no $label tarball (run ./1-fetch.sh)"; fi
done

if xcode-select -p >/dev/null 2>&1; then ok "Xcode command line tools"; else
  bad "no Xcode CLT: xcode-select --install"
fi

# D3DMetal is optional at build time and required only for Direct3D 12 titles.
found_d3dmetal=
for cand in "$GPTK_D3DMETAL" \
  "/usr/local/lib/external" \
  "$HOME/Library/Application Support/Game Porting Toolkit/lib/external" \
  "/opt/game-porting-toolkit/lib/external"
do
  if [[ -d "$cand" ]]; then ok "D3DMetal at $cand"; found_d3dmetal=1; break; fi
done
if [[ -z "$found_d3dmetal" ]]; then
  warn "no D3DMetal found - D3D12 titles will not run."
  warn "Install Apple's Game Porting Toolkit from developer.apple.com,"
  warn "then set GPTK_D3DMETAL to the …/lib/external directory."
  warn "D3D10/11 still works via DXMT."
fi

# macOS 26 and later changed enough under winemac.drv that upstream Wine needs
# fixes; flag it rather than pretend the build is clean.
osmajor=$(sw_vers -productVersion | cut -d. -f1)
if (( osmajor >= 26 )); then
  warn "macOS $osmajor: winemac.drv needs post-26 fixes; see patches/README.md"
fi

echo
(( fail )) && { echo "preconditions NOT met"; exit 1; }
echo "preconditions met"
