#!/usr/bin/env bash
# Applies patches/series to the Wine tree, then regenerates the server protocol.
source "$(dirname "$0")/config.sh"
cd "$SRC"

git rev-parse --verify mcsoda-base >/dev/null 2>&1 || git branch mcsoda-base

while read -r p; do
  [[ -z "$p" || "$p" == \#* ]] && continue
  printf '>> %-44s' "$p"
  if git apply "$ROOT/patches/$p" 2>/dev/null; then
    echo "ok"
  elif git apply --check --reverse "$ROOT/patches/$p" 2>/dev/null; then
    echo "already applied"
  else
    echo "FAILED"
    git apply "$ROOT/patches/$p"
    exit 1
  fi
done < "$ROOT/patches/series"

# Valve's checked-in server_protocol.h lags their own protocol.def, so this is
# required whether or not we patched anything. It also writes request_trace.h
# and request_handlers.h.
# Valve's tree omits the generated files upstream Wine checks in, and expects
# the build to produce them. Three generators cover all of them.
echo ">> regenerating server protocol"
perl tools/make_requests

echo ">> regenerating syscall headers"
perl tools/make_specfiles

# Valve's tree ships dlls/winevulkan/make_vulkan and the registry XML but not
# the generated outputs that upstream Wine checks in (include/wine/vulkan.h,
# the thunks, the spec files). Their build generates them; so do we.
if [[ ! -f include/wine/vulkan.h ]]; then
  echo ">> generating vulkan headers"
  ( cd dlls/winevulkan && python3 make_vulkan -x vk.xml -X video.xml )
fi

echo ">> patched"
