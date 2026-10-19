#!/usr/bin/env bash
# Install D3DMetal from a mounted Game Porting Toolkit DMG into a stable
# user-local path that mcsoda already searches.
#
# GPTK 4 ships D3DMetal inside the nested
# "Evaluation environment for Windows games … .dmg", not the outer DMG.
set -euo pipefail

DEST="${GPTK_INSTALL_DIR:-$HOME/Library/Application Support/Game Porting Toolkit/lib}"

find_redist() {
  local vol
  for vol in "/Volumes/Evaluation environment for Windows games"* \
             "/Volumes/Game Porting Toolkit"*; do
    [[ -d "$vol" ]] || continue
    if [[ -d "$vol/redist/lib/external/D3DMetal.framework" ]]; then
      echo "$vol/redist/lib"
      return 0
    fi
    # Outer GPTK DMG: nested eval dmg may already be mounted, or need mounting
    local nested
    nested="$(find "$vol" -maxdepth 1 -name 'Evaluation environment*.dmg' 2>/dev/null | head -1)"
    if [[ -n "$nested" ]]; then
      echo "Found nested eval DMG: $nested" >&2
      echo "Mount it (double-click), then re-run this script." >&2
      return 1
    fi
  done
  return 1
}

echo "Searching for GPTK redist (D3DMetal)..."
if SRC="$(find_redist)"; then
  echo "  source: $SRC"
  mkdir -p "$DEST"
  rm -rf "$DEST/external" "$DEST/wine"
  ditto "$SRC/" "$DEST/"
  [[ -f "$DEST/wine/x86_64-windows/nvngx-on-metalfx.dll" ]] && \
    ln -sf nvngx-on-metalfx.dll "$DEST/wine/x86_64-windows/nvngx.dll"
  [[ -f "$DEST/wine/x86_64-unix/nvngx-on-metalfx.so" ]] && \
    ln -sf nvngx-on-metalfx.so "$DEST/wine/x86_64-unix/nvngx.so"
  echo
  echo "Installed to: $DEST"
  echo "export GPTK_D3DMETAL=\"$DEST/external\""
  echo
  echo "Then:  ./work/dist/usr/local/opt/mcsoda/bin/mcsoda your-d3d12-game.exe"
  exit 0
fi

echo "  not found on a mounted volume."
echo
echo "1. Open Game_Porting_Toolkit_*.dmg"
echo "2. Open 'Evaluation environment for Windows games … .dmg' inside it"
echo "3. Re-run:  ./install-gptk-hint.sh"
echo
echo "Already installed copies:"
found=0
for cand in \
  "$DEST/external" \
  "${GPTK_D3DMETAL:-}" \
  "/usr/local/lib/external"
do
  [[ -z "$cand" || ! -d "$cand" ]] && continue
  echo "  FOUND: $cand"
  ls "$cand" | head -10
  found=1
done
(( found )) || exit 1
