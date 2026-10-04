#!/usr/bin/env bash
# Runs the commands VideoCull uses (and the ones its roadmap plans) against the runtime folder.
# The binaries run with only Windows on PATH, so a missing bundled DLL fails here.
# Usage: smoke-test.sh RUNTIME_DIR [FIXTURE_FFMPEG]
#   FIXTURE_FFMPEG: an FFmpeg with HEVC/AV1/VP9 encoders, used only to create test clips.
set -euo pipefail
BIN="$(cd "$1" && pwd)"
FIXTURE_FFMPEG="${2:-}"
TMP="$(mktemp -d)"
SYSTEM_PATH="$(cygpath -u "${SYSTEMROOT:-C:\Windows}")/System32:$(cygpath -u "${SYSTEMROOT:-C:\Windows}")"
cd "$TMP"
pass=0; fail=0
ff() { env PATH="$SYSTEM_PATH" "$BIN/ffmpeg.exe" "$@"; }
fp() { env PATH="$SYSTEM_PATH" "$BIN/ffprobe.exe" "$@"; }
check() {
  local name="$1"; shift
  if "$@" > "$name.log" 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $name"; tail -n 5 "$name.log"; fi
}
expect_in() {
  local name="$1" needle="$2"; shift 2
  if "$@" > "$name.log" 2>&1 && grep -qE -- "$needle" "$name.log"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $name"; tail -n 5 "$name.log"; fi
}

ff -hide_banner -version | head -n 3
expect_in version 'ffmpeg version 9\.0\.2' ff -hide_banner -version
for hw in d3d11va d3d12va dxva2 cuda qsv; do expect_in "hwaccel-$hw" "^$hw\$" ff -hide_banner -hwaccels; done
for enc in libx264 aac mjpeg h264_nvenc hevc_nvenc h264_qsv h264_amf hevc_amf h264_mf; do expect_in "encoder-$enc" " $enc " ff -hide_banner -encoders; done
for dec in libdav1d h264 hevc vp9 vp8 mpeg4 msmpeg4 wmv3 vc1 prores mpeg2video aac mp3 ac3 opus; do expect_in "decoder-$dec" " $dec " ff -hide_banner -decoders; done
for filter in cropdetect scale trim concat setpts aresample; do expect_in "filter-$filter" " $filter " ff -hide_banner -filters; done
expect_in demuxer-concat ' concat ' ff -hide_banner -demuxers

SRC=(-f lavfi -i testsrc2=size=640x360:rate=25 -f lavfi -i sine=frequency=440 -t 4)
clips=(h264.mp4 mpeg4.avi wmv.wmv)
check make-h264 ff -v error -y "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac h264.mp4
check make-mpeg4 ff -v error -y "${SRC[@]}" -c:v mpeg4 -c:a mp2 mpeg4.avi
check make-wmv ff -v error -y "${SRC[@]}" -c:v wmv2 -c:a wmav2 wmv.wmv
if [[ -n "$FIXTURE_FFMPEG" ]]; then
  check make-hevc "$FIXTURE_FFMPEG" -v error -y "${SRC[@]}" -c:v libx265 -pix_fmt yuv420p -c:a aac hevc.mkv
  check make-av1 "$FIXTURE_FFMPEG" -v error -y "${SRC[@]}" -c:v libsvtav1 -pix_fmt yuv420p -c:a libopus av1.mp4
  check make-vp9 "$FIXTURE_FFMPEG" -v error -y "${SRC[@]}" -c:v libvpx-vp9 -c:a libopus vp9.webm
  clips+=(hevc.mkv av1.mp4 vp9.webm)
fi

for clip in "${clips[@]}"; do
  expect_in "probe-$clip" '"codec_type": "video"' fp -v error -print_format json -show_format -show_streams "$clip"
  check "thumb-$clip" ff -ss 1.5 -i "$clip" -y -vframes 1 -filter:v scale=320:-1 -q:v 5 -threads 1 "$clip.jpg"
  check "thumb-hw-$clip" ff -ss 1.5 -hwaccel auto -i "$clip" -y -vframes 1 -filter:v scale=320:-1 -q:v 5 -threads 1 "$clip.hw.jpg"
  check "gray-$clip" ff -v error -ss 0.5 -i "$clip" -ss 1.5 -i "$clip" -ss 2.5 -i "$clip" -filter_complex \
    "[0:v]scale=32:32:flags=bicubic,setsar=1,format=gray,trim=end_frame=1,setpts=PTS-STARTPTS[v0];[1:v]scale=32:32:flags=bicubic,setsar=1,format=gray,trim=end_frame=1,setpts=PTS-STARTPTS[v1];[2:v]scale=32:32:flags=bicubic,setsar=1,format=gray,trim=end_frame=1,setpts=PTS-STARTPTS[v2];[v0][v1][v2]concat=n=3:v=1:a=0[out]" \
    -map "[out]" -frames:v 3 -f rawvideo -pix_fmt gray -threads 1 "$clip.gray"
  check "gray-size-$clip" test "$(stat -c %s "$clip.gray")" -eq 3072
done
expect_in cropdetect 'crop=' ff -i h264.mp4 -vf cropdetect -f null -
printf "file 'h264.mp4'\ninpoint 0.5\noutpoint 1.5\nfile 'h264.mp4'\ninpoint 2\noutpoint 3\n" > list.txt
check concat-copy ff -v error -y -f concat -safe 0 -i list.txt -c copy joined.mp4
check exact-export ff -v error -y -ss 0.5 -i h264.mp4 -t 2 -c:v libx264 -crf 18 -preset veryfast -c:a aac -b:a 192k -movflags +faststart exact.mp4
check audio-pcm ff -v error -y -i h264.mp4 -vn -ac 1 -ar 8000 -f s16le audio.pcm
check network-disabled bash -c "! env PATH='$SYSTEM_PATH' '$BIN/ffmpeg.exe' -hide_banner -protocols | grep -qE '^\s+(http|https|tcp)$'"

echo "smoke test: $pass passed, $fail failed"
(( fail == 0 ))
