#!/usr/bin/env bash
# Builds the FFmpeg runtime VideoCull ships, using only the verified files in SOURCES_DIR.
# Runs in an MSYS2 UCRT64 shell with the toolchain from msys2.lock and never downloads anything,
# so the published source archive is enough to repeat it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
SRC="${SOURCES_DIR:-$ROOT/sources}"
WORK="${WORK_DIR:-$ROOT/work}"
OUT="${OUT_DIR:-$ROOT/out}"
PREFIX="$WORK/prefix"
JOBS="$(nproc)"

SOURCES_DIR="$SRC" bash "$ROOT/scripts/fetch-sources.sh" --offline
mkdir -p "$PREFIX/include" "$PREFIX/lib/pkgconfig" "$OUT"

# Dependencies come only from our own prefix, never from packages that happen to be installed in
# MSYS2. FFmpeg's --disable-autodetect below enforces the same for its optional libraries.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""

step() { echo "::group::$1"; SECONDS=0; }
done_step() { echo "$1 took ${SECONDS}s"; echo "::endgroup::"; }

step zlib
d="$(unpack zlib)"
make -C "$d" -f win32/Makefile.gcc -j"$JOBS" libz.a
cp "$d/zlib.h" "$d/zconf.h" "$PREFIX/include/"
cp "$d/libz.a" "$PREFIX/lib/"
done_step zlib

step bzip2
d="$(unpack bzip2)"
make -C "$d" -j"$JOBS" libbz2.a CC=gcc CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"
cp "$d/bzlib.h" "$PREFIX/include/"
cp "$d/libbz2.a" "$PREFIX/lib/"
done_step bzip2

step x264
d="$(unpack x264)"
(cd "$d" && ./configure --prefix="$PREFIX" --enable-static --disable-cli --disable-opencl \
  --disable-lavf --disable-swscale --disable-ffms --disable-gpac --disable-lsmash \
  && make -j"$JOBS" && make install)
done_step x264

step dav1d
d="$(unpack dav1d)"
meson setup "$d/build" "$d" --prefix="$PREFIX" --libdir=lib --buildtype=release \
  --default-library=static --wrap-mode=nodownload -Denable_tools=false -Denable_tests=false
ninja -C "$d/build" install
done_step dav1d

step libvpl
d="$(unpack libvpl)"
cmake -S "$d" -B "$d/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF \
  -DBUILD_TESTS=OFF -DINSTALL_EXAMPLES=OFF
ninja -C "$d/build" install
done_step libvpl

step headers
d="$(unpack nv-codec-headers)"
make -C "$d" PREFIX="$PREFIX" install
d="$(unpack amf-headers)"
mkdir -p "$PREFIX/include/AMF"
cp -r "$d/AMF/." "$PREFIX/include/AMF/"
done_step headers

step ffmpeg
d="$(unpack ffmpeg)"
INSTALL="$WORK/ffmpeg-install"
# Everything optional is listed explicitly; nothing is auto-detected from the build machine.
# gcc runtime libraries are linked statically so the runtime folder needs no MinGW DLLs.
(cd "$d" && ./configure \
  --prefix="$INSTALL" \
  --enable-gpl --enable-version3 \
  --enable-shared --disable-static \
  --disable-autodetect \
  --disable-debug --disable-doc --disable-ffplay --disable-avdevice --disable-network \
  --enable-w32threads \
  --enable-zlib --enable-bzlib \
  --enable-d3d11va --enable-d3d12va --enable-dxva2 --enable-mediafoundation \
  --enable-ffnvcodec --enable-cuvid --enable-nvdec --enable-nvenc \
  --enable-amf --enable-libvpl \
  --enable-libdav1d --enable-libx264 \
  --pkg-config-flags=--static \
  --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib -static-libgcc -static-libstdc++" \
  --extra-libs="-Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic" \
  --extra-version=videocull \
  && make -j"$JOBS" && make install)
done_step ffmpeg

cp "$INSTALL/bin/ffmpeg.exe" "$INSTALL/bin/ffprobe.exe" "$INSTALL"/bin/*.dll "$OUT/"
strip --strip-unneeded "$OUT"/*.exe "$OUT"/*.dll
cp "$d/COPYING.GPLv3" "$OUT/LICENSE.txt"
ls -l "$OUT"
