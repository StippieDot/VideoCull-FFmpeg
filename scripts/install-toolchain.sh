#!/usr/bin/env bash
# Installs the MSYS2 compiler toolchain at the exact versions in msys2.lock, checking each package
# file's SHA-256. Without a lock file (first run, or after deleting it to update the toolchain) it
# installs the current packages and writes a new msys2.lock to commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
LOCK="$ROOT/msys2.lock"
CACHE="${TOOLCHAIN_CACHE:-$ROOT/toolchain-cache}"
PACKAGES=(
  mingw-w64-ucrt-x86_64-gcc
  mingw-w64-ucrt-x86_64-nasm
  mingw-w64-ucrt-x86_64-pkgconf
  mingw-w64-ucrt-x86_64-meson
  mingw-w64-ucrt-x86_64-ninja
  mingw-w64-ucrt-x86_64-cmake
)
mkdir -p "$CACHE"

repo_url() {
  case "$1" in
    mingw-w64-ucrt-x86_64-*) echo "https://repo.msys2.org/mingw/ucrt64/$2" ;;
    *) echo "https://repo.msys2.org/msys/x86_64/$2" ;;
  esac
}

if [[ ! -f "$LOCK" ]]; then
  pacman -Sy --noconfirm
  {
    echo "# MSYS2 packages of the build toolchain. Columns: name  version  file  sha256  url"
    echo "# Written by install-toolchain.sh; delete this file and rerun it to move to newer packages."
    pacman -Sp --print-format '%n %v %f' "${PACKAGES[@]}" | while read -r name version file; do
      url="$(repo_url "$name" "$file")"
      curl --fail --location --silent --show-error --retry 3 -o "$CACHE/$file" "$url"
      echo "$name $version $file $(sha256sum "$CACHE/$file" | cut -d' ' -f1) $url"
    done
  } > "$LOCK.new"
  mv "$LOCK.new" "$LOCK"
  echo "Wrote $LOCK; commit it."
fi

files=()
while read -r name version file sha url; do
  target="$CACHE/$file"
  [[ -f "$target" ]] || curl --fail --location --silent --show-error --retry 3 -o "$target" "$url"
  actual="$(sha256sum "$target" | cut -d' ' -f1)"
  [[ "$actual" == "$sha" ]] || { echo "hash mismatch for $file" >&2; exit 1; }
  files+=("$target")
done < <(lock_entries "$LOCK")
pacman -U --noconfirm --needed "${files[@]}"
pacman -Q > "$ROOT/toolchain-installed.txt"
