#!/usr/bin/env bash
# Packs the build of this platform into its release files:
#   videocull-ffmpeg-<version>-r<revision>-<platform>.zip|.tar.xz     runtime folder VideoCull bundles
#                                                                     (zip on win64, tar.xz elsewhere)
#   videocull-ffmpeg-<version>-r<revision>-<platform>-manifest.json   configure line, toolchain, file hashes
# and, on win64 only, the one corresponding source archive for all platforms:
#   videocull-ffmpeg-<version>-r<revision>-source.tar
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
SRC="${SOURCES_DIR:-$ROOT/sources}"
OUT="${OUT_DIR:-$ROOT/out}"
DIST="${DIST_DIR:-$ROOT/dist}"
CACHE="${TOOLCHAIN_CACHE:-$ROOT/toolchain-cache}"
PLATFORM="$(build_platform)"
VERSION="$(lock_field ffmpeg 2)"
REVISION="$(tr -d '[:space:]' < "$ROOT/REVISION")"
NAME="videocull-ffmpeg-$VERSION-r$REVISION"
# CI checkouts can belong to another user (Windows runner, Linux container), which git otherwise refuses.
git config --global --add safe.directory "$ROOT"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"

# Runtime ----------------------------------------------------------------------------------------
cat > "$OUT/README.txt" <<TXT
FFmpeg $VERSION built for VideoCull ($PLATFORM, revision $REVISION), licensed under the GNU GPL
version 3 or later (LICENSE.txt). Built from commit $COMMIT of
https://github.com/StippieDot/VideoCull-FFmpeg.
The complete corresponding source is published next to this file as $NAME-source.tar at
https://github.com/StippieDot/VideoCull-FFmpeg/releases/tag/ffmpeg-$VERSION-r$REVISION
TXT
if [[ "$PLATFORM" == win64 ]]; then
  (cd "$OUT" && zip -q -X -r "$DIST/$NAME-win64.zip" .)
else
  # tar keeps the executable bits that a zip extracted with other tools may lose.
  tar -cJf "$DIST/$NAME-$PLATFORM.tar.xz" -C "$OUT" .
fi

# Corresponding source (built once, on Windows, which also needs the MinGW runtime sources) -------
if [[ "$PLATFORM" == win64 ]]; then
  SRCROOT="$STAGE/$NAME-source"
  mkdir -p "$SRCROOT/recipe" "$SRCROOT/sources" "$SRCROOT/toolchain-runtime"
  git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$SRCROOT/recipe"
  cp "$ROOT/msys2.lock" "$SRCROOT/recipe/msys2.lock"
  echo "$COMMIT" > "$SRCROOT/recipe/COMMIT"
  while read -r name version file sha url; do cp "$SRC/$file" "$SRCROOT/sources/"; done < <(lock_entries "$ROOT/sources.lock")
  # The gcc runtime, winpthreads and the MinGW-w64 startup code are linked statically into the
  # Windows binaries, so their sources (MSYS2 source packages at the locked toolchain versions) ship
  # too. The Linux and macOS binaries link their compiler runtime and C library dynamically, from
  # the system.
  declare -A RUNTIME_SOURCE=(
    [mingw-w64-ucrt-x86_64-gcc]=gcc
    [mingw-w64-ucrt-x86_64-libwinpthread]=winpthreads
    [mingw-w64-ucrt-x86_64-crt]=crt
    [mingw-w64-ucrt-x86_64-headers]=headers
  )
  while read -r name version file sha url; do
    base="${RUNTIME_SOURCE[$name]:-}"
    [[ -n "$base" ]] || continue
    src="mingw-w64-$base-${version//:/~}.src.tar.zst"
    [[ -f "$CACHE/$src" ]] || curl --fail --location --silent --show-error --retry 3 -o "$CACHE/$src" "https://repo.msys2.org/mingw/sources/$src"
    cp "$CACHE/$src" "$SRCROOT/toolchain-runtime/"
  done < <(lock_entries "$ROOT/msys2.lock")
  [[ "$(ls "$SRCROOT/toolchain-runtime" | wc -l)" -eq 4 ]] || { echo "toolchain runtime sources incomplete" >&2; exit 1; }
  cat > "$SRCROOT/README.txt" <<TXT
Corresponding source for every runtime archive of $NAME (win64, linux-x64, macos-arm64, macos-x64).

recipe/             build scripts, lock files and CI workflow at commit $COMMIT
sources/            every source archive listed in recipe/sources.lock, as downloaded
toolchain-runtime/  MSYS2 source packages of the gcc runtime, winpthreads and MinGW-w64 CRT/headers,
                    which are linked statically into the Windows binaries

To rebuild without downloading sources (output in recipe/out):
  cd recipe
  Windows, in an MSYS2 UCRT64 shell:
    bash scripts/install-toolchain.sh             # compiler packages from msys2.lock
    SOURCES_DIR=../sources bash scripts/build.sh
  Linux, as root in a debian:bullseye-slim container (the digest is in .github/workflows/build.yml):
    bash scripts/install-toolchain-linux.sh       # packages from a fixed snapshot.debian.org date
    SOURCES_DIR=../sources bash scripts/build.sh
  macOS, with Xcode and Homebrew:
    bash scripts/install-toolchain-macos.sh
    SOURCES_DIR=../sources bash scripts/build.sh
TXT
  tar -cf "$DIST/$NAME-source.tar" -C "$STAGE" "$NAME-source"
fi

# Manifest ---------------------------------------------------------------------------------------
if [[ "$PLATFORM" == win64 ]]; then
  env PATH="$(cygpath -u "$SYSTEMROOT")/System32" "$OUT/ffmpeg.exe" -hide_banner -buildconf > "$STAGE/buildconf.txt"
else
  "$OUT/ffmpeg" -hide_banner -buildconf > "$STAGE/buildconf.txt"
fi
python3 - "$ROOT" "$OUT" "$STAGE/buildconf.txt" "$VERSION" "$REVISION" "$COMMIT" "$PLATFORM" > "$DIST/$NAME-$PLATFORM-manifest.json" <<'PY'
import hashlib, json, os, sys
root, out, buildconf, version, revision, commit, platform = sys.argv[1:]
def lock(path):
    rows = [l.split() for l in open(path) if l.strip() and not l.lstrip().startswith('#')]
    return [dict(zip(('name', 'version', 'file', 'sha256', 'url'), r)) for r in rows]
def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()
def files(top):
    return sorted(os.path.relpath(os.path.join(d, f), top).replace(os.sep, '/')
                  for d, _, names in os.walk(top) for f in names)
# Windows pins its toolchain in msys2.lock; Linux and macOS record what install-toolchain-*.sh installed.
toolchain = (lock(os.path.join(root, 'msys2.lock')) if platform == 'win64'
             else [l.strip() for l in open(os.path.join(root, 'toolchain-installed.txt')) if l.strip()])
print(json.dumps({
    'ffmpeg': version, 'revision': int(revision), 'commit': commit, 'platform': platform,
    'configure': [l.strip() for l in open(buildconf) if l.strip().startswith('--')],
    'files': {rel: {'sha256': sha(os.path.join(out, rel)), 'size': os.path.getsize(os.path.join(out, rel))}
              for rel in files(out)},
    'sources': lock(os.path.join(root, 'sources.lock')),
    'toolchain': toolchain,
}, indent=2))
PY

ls -l "$DIST"
