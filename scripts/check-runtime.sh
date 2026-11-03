#!/usr/bin/env bash
# Fails when a binary in the runtime folder loads a library that is neither shipped in that folder
# nor part of every system VideoCull runs on. Catches libraries that would work on the build machine
# but be missing on a user's computer.
#   win64      only bundled DLLs and Windows DLLs (no MinGW runtime DLLs)
#   linux-x64  only bundled libraries, glibc and libdrm; nothing newer than glibc 2.31; RUNPATH $ORIGIN
#   macos-*    only bundled libraries (@rpath) and system ones; minimum macOS 12.0; valid signature
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
DIR="$1"
PLATFORM="$(build_platform)"
status=0
fail() { echo "$*" >&2; status=1; }

case "$PLATFORM" in
  win64)
    command -v objdump > /dev/null || { echo "objdump not found" >&2; exit 1; }
    SYSTEM32="$(cygpath -u "${SYSTEMROOT:-C:\Windows}")/System32"
    for bin in "$DIR"/*.exe "$DIR"/*.dll; do
      while read -r dll; do
        lower="${dll,,}"
        if [[ -n "$(find "$DIR" -maxdepth 1 -iname "$dll" -print -quit)" ]]; then continue; fi
        if [[ "$lower" == api-ms-win-* || "$lower" == ext-ms-win-* ]]; then continue; fi
        if [[ "$lower" != lib* && -n "$(find "$SYSTEM32" -maxdepth 1 -iname "$dll" -print -quit)" ]]; then continue; fi
        fail "$(basename "$bin") imports $dll, which is neither bundled nor a Windows DLL"
      done < <(objdump -p "$bin" | sed -n 's/^\s*DLL Name: //p')
    done
    ;;

  linux-x64)
    GLIBC_MAX=2.31
    # glibc, the gcc runtime and libdrm (which Electron needs through libgbm) are on every such system.
    SYSTEM_LIBS=' libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-x86-64.so.2 libgcc_s.so.1 libdrm.so.2 '
    for bin in "$DIR"/*; do
      readelf -h "$bin" > /dev/null 2>&1 || continue
      name="$(basename "$bin")"
      while read -r lib; do
        [[ -f "$DIR/$lib" || "$SYSTEM_LIBS" == *" $lib "* ]] || fail "$name needs $lib, which is neither bundled nor a system library"
      done < <(readelf -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
      newest="$(objdump -T "$bin" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)"
      if [[ -n "$newest" && "$(printf '%s\n%s\n' "$newest" "$GLIBC_MAX" | sort -V | tail -n 1)" != "$GLIBC_MAX" ]]; then
        fail "$name needs glibc $newest, newer than $GLIBC_MAX"
      fi
      runpath="$(readelf -d "$bin" | sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]/\2/p')"
      [[ -z "$runpath" || "$runpath" == '$ORIGIN' ]] || fail "$name has search path '$runpath' instead of \$ORIGIN"
    done
    ;;

  macos-*)
    MIN_MACOS=12.0
    for bin in "$DIR"/*; do
      file -b "$bin" | grep -q Mach-O || continue
      name="$(basename "$bin")"
      while read -r lib; do
        case "$lib" in
          @rpath/*) [[ -f "$DIR/${lib#@rpath/}" ]] || fail "$name needs $lib, which is not bundled" ;;
          /usr/lib/*|/System/Library/*) ;;
          *) fail "$name needs $lib, which is neither bundled nor a system library" ;;
        esac
      done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
      minos="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
      [[ "$minos" == "$MIN_MACOS" ]] || fail "$name targets macOS '$minos' instead of $MIN_MACOS"
      codesign --verify "$bin" 2> /dev/null || fail "$name has no valid signature"
    done
    ;;
esac

(( status == 0 )) && echo "Runtime libraries OK: only bundled and system libraries ($PLATFORM)."
exit $status
