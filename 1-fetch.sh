#!/usr/bin/env bash
# Clones the Valve Wine base and DXMT sources, and downloads wine-mono,
# wine-gecko, and the DXMT builtin release tarball.
#
# msync is NOT fetched: patches/0002 carries the full CrossOver msync sources
# inline, so there is nothing to clone for it. See patches/README.md.
source "$(dirname "$0")/config.sh"
mkdir -p "$WORK" "$WORK/deps-src"

if [[ ! -d "$SRC" ]]; then
  echo ">> cloning Valve wine ($WINE_BRANCH)"
  git clone --depth 1 --branch "$WINE_BRANCH" --single-branch "$WINE_REPO" "$SRC"
else
  echo ">> wine already cloned at $SRC"
fi

if [[ ! -d "$WORK/dxmt" ]]; then
  echo ">> cloning DXMT (source reference)"
  git clone --recursive "$DXMT_REPO" "$WORK/dxmt"
fi

fetch() {
  local url="$1" out="$2" label="$3"
  if [[ -f "$out" ]]; then
    echo ">> $label already at $out"
  else
    echo ">> downloading $label"
    curl -fL -o "$out" "$url"
  fi
}

fetch "$WINE_MONO_URL" \
  "$WORK/deps-src/wine-mono-${WINE_MONO_VERSION}-x86.tar.xz" \
  "wine-mono $WINE_MONO_VERSION"

fetch "$WINE_GECKO_URL" \
  "$WORK/deps-src/wine-gecko-${WINE_GECKO_VERSION}-x86_64.tar.xz" \
  "wine-gecko $WINE_GECKO_VERSION"

fetch "$DXMT_URL" \
  "$WORK/deps-src/dxmt-${DXMT_VERSION}-builtin.tar.gz" \
  "DXMT $DXMT_VERSION builtin"

echo ">> fetched into $WORK"
