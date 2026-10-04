#!/usr/bin/env bash
# Packs the build into the release files:
#   videocull-ffmpeg-<version>-r<revision>-win64.zip     runtime folder VideoCull bundles
#   videocull-ffmpeg-<version>-r<revision>-source.tar    corresponding source (see README inside)
#   videocull-ffmpeg-<version>-r<revision>-manifest.json versions, configure line, input and file hashes
#   SHA256SUMS
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
SRC="${SOURCES_DIR:-$ROOT/sources}"
OUT="${OUT_DIR:-$ROOT/out}"
DIST="${DIST_DIR:-$ROOT/dist}"
CACHE="${TOOLCHAIN_CACHE:-$ROOT/toolchain-cache}"
VERSION="$(lock_field ffmpeg 2)"
REVISION="$(tr -d '[:space:]' < "$ROOT/REVISION")"
NAME="videocull-ffmpeg-$VERSION-r$REVISION"
# CI checkouts belong to another Windows user, which git otherwise refuses to read.
git config --global --add safe.directory "$ROOT"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"

# Runtime ----------------------------------------------------------------------------------------
cat > "$OUT/README.txt" <<TXT
FFmpeg $VERSION built for VideoCull (revision $REVISION), licensed under the GNU GPL version 3 or
later (LICENSE.txt). Built from commit $COMMIT of https://github.com/StippieDot/VideoCull-FFmpeg.
The complete corresponding source is published next to this file as $NAME-source.tar at
https://github.com/StippieDot/VideoCull-FFmpeg/releases/tag/ffmpeg-$VERSION-r$REVISION
TXT
(cd "$OUT" && zip -q -X -r "$DIST/$NAME-win64.zip" .)

# Corresponding source ---------------------------------------------------------------------------
SRCROOT="$STAGE/$NAME-source"
mkdir -p "$SRCROOT/recipe" "$SRCROOT/sources" "$SRCROOT/toolchain-runtime"
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$SRCROOT/recipe"
cp "$ROOT/msys2.lock" "$SRCROOT/recipe/msys2.lock"
echo "$COMMIT" > "$SRCROOT/recipe/COMMIT"
while read -r name version file sha url; do cp "$SRC/$file" "$SRCROOT/sources/"; done < <(lock_entries "$ROOT/sources.lock")
# The gcc runtime, winpthreads and the MinGW-w64 startup code are linked statically into the
# binaries, so their sources (MSYS2 source packages at the locked toolchain versions) ship too.
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
Corresponding source for $NAME-win64.zip.

recipe/             build scripts, lock files and CI workflow at commit $COMMIT
sources/            every source archive listed in recipe/sources.lock, as downloaded
toolchain-runtime/  MSYS2 source packages of the gcc runtime, winpthreads and MinGW-w64 CRT/headers,
                    which are linked statically into the binaries

To rebuild on Windows in an MSYS2 UCRT64 shell:
  cd recipe
  bash scripts/install-toolchain.sh           # compiler packages from msys2.lock
  SOURCES_DIR=../sources bash scripts/build.sh  # no downloads; output in recipe/out
TXT
tar -cf "$DIST/$NAME-source.tar" -C "$STAGE" "$NAME-source"

# Manifest ---------------------------------------------------------------------------------------
env PATH="$(cygpath -u "$SYSTEMROOT")/System32" "$OUT/ffmpeg.exe" -hide_banner -buildconf > "$STAGE/buildconf.txt"
python3 - "$ROOT" "$OUT" "$STAGE/buildconf.txt" "$VERSION" "$REVISION" "$COMMIT" > "$DIST/$NAME-manifest.json" <<'PY'
import hashlib, json, os, sys
root, out, buildconf, version, revision, commit = sys.argv[1:]
def lock(path):
    rows = [l.split() for l in open(path) if l.strip() and not l.lstrip().startswith('#')]
    return [dict(zip(('name', 'version', 'file', 'sha256', 'url'), r)) for r in rows]
def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()
print(json.dumps({
    'ffmpeg': version, 'revision': int(revision), 'commit': commit,
    'configure': [l.strip() for l in open(buildconf) if l.strip().startswith('--')],
    'files': {f: {'sha256': sha(os.path.join(out, f)), 'size': os.path.getsize(os.path.join(out, f))}
              for f in sorted(os.listdir(out))},
    'sources': lock(os.path.join(root, 'sources.lock')),
    'toolchain': lock(os.path.join(root, 'msys2.lock')),
}, indent=2))
PY

(cd "$DIST" && sha256sum "$NAME-win64.zip" "$NAME-source.tar" "$NAME-manifest.json" > SHA256SUMS)
ls -l "$DIST"
