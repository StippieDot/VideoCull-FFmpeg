#!/usr/bin/env bash
# Fails when a binary in the runtime folder imports a DLL that is neither shipped in that folder
# nor part of Windows. Catches MinGW runtime DLLs (libgcc, libstdc++, libwinpthread, zlib1, ...)
# that would work on the build machine but be missing on a user's PC.
set -euo pipefail
DIR="$1"
command -v objdump > /dev/null || { echo "objdump not found" >&2; exit 1; }
SYSTEM32="$(cygpath -u "${SYSTEMROOT:-C:\Windows}")/System32"
status=0
for bin in "$DIR"/*.exe "$DIR"/*.dll; do
  while read -r dll; do
    lower="${dll,,}"
    if [[ -n "$(find "$DIR" -maxdepth 1 -iname "$dll" -print -quit)" ]]; then continue; fi
    if [[ "$lower" == api-ms-win-* || "$lower" == ext-ms-win-* ]]; then continue; fi
    if [[ "$lower" != lib* && -n "$(find "$SYSTEM32" -maxdepth 1 -iname "$dll" -print -quit)" ]]; then continue; fi
    echo "$(basename "$bin") imports $dll, which is neither bundled nor a Windows DLL" >&2
    status=1
  done < <(objdump -p "$bin" | sed -n 's/^\s*DLL Name: //p')
done
(( status == 0 )) && echo "Runtime imports OK: only bundled and Windows DLLs."
exit $status
