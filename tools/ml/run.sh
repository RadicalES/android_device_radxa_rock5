#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs the CPU baseline on a device over adb and prints a Markdown table (latency in ms).
# Needs build.sh and models.sh output in $OUT (default: ./out).
#
#   [ADB_SERIAL=host:5555] [OUT=out] [ITERS=50] tools/ml/run.sh > baseline.md
#
# RK3588: CPUs 4-7 are the Cortex-A76 cores (mask f0), CPUs 0-3 the Cortex-A55s (0f).

set -euo pipefail

OUT=${OUT:-out}
ITERS=${ITERS:-50}
ADB=(adb ${ADB_SERIAL:+-s "$ADB_SERIAL"})
DIR=/data/local/tmp/ml

"${ADB[@]}" shell mkdir -p $DIR/models
"${ADB[@]}" push "$OUT/ort_bench" "$OUT/libonnxruntime.so" "$OUT/benchmark_model" $DIR/ >/dev/null
"${ADB[@]}" push "$OUT/models/." $DIR/models/ >/dev/null
"${ADB[@]}" shell chmod 755 $DIR/ort_bench $DIR/benchmark_model

# model : input shape for ort_bench (dynamic dimensions)
ORT_MODELS=(
  "scrfd_10g:input.1=1x3x640x640"
  "arcface_r50:"
  "pp_ocrv6_small_det:x=1x3x640x960"
  "pp_ocrv6_small_rec:x=1x3x48x320"
  "pp_ocrv5_arabic_rec:x=1x3x48x320"
  "pp_lcnet_doc_ori:"
)
TFLITE_MODELS=(blazeface_short face_landmarks selfie_segmenter)

# config: <cpu mask> <threads> <ort ep or tflite xnnpack flag>
CONFIGS=("f0 1" "f0 2" "f0 4" "0f 4")

echo "Device: $("${ADB[@]}" shell getprop ro.product.model) ($("${ADB[@]}" shell getprop ro.build.display.id))," \
     "$(date -u +%Y-%m-%d). Median / p95 in ms, $ITERS runs after warm-up."
echo
echo "| Model | Runtime | A76 x1 | A76 x2 | A76 x4 | A55 x4 |"
echo "|---|---|---|---|---|---|"

ort_row() {  # ort_row <model> <shape> <ep>
  local row="| $1 | ORT $3 |"
  for c in "${CONFIGS[@]}"; do
    set -- "$1" "$2" "$3" $c
    local args=(--ep "$3" --threads "$5" --iters "$ITERS")
    [ -n "$2" ] && args+=(--shape "$2")
    local r
    r=$("${ADB[@]}" shell "cd $DIR && taskset $4 ./ort_bench models/$1.onnx ${args[*]} 2>/dev/null" | tail -1 || true)
    if [[ "$r" == "$1.onnx "* ]]; then
      row+=" $(awk '{printf "%s / %s", $5, $6}' <<<"$r") |"
    else
      row+=" fails |"
    fi
  done
  echo "$row"
}

tflite_row() {  # tflite_row <model> <xnnpack true|false>
  local name="LiteRT CPU"; [ "$2" = true ] && name="LiteRT XNNPACK"
  local row="| $1 | $name |"
  for c in "${CONFIGS[@]}"; do
    set -- "$1" "$2" $c
    local r
    r=$("${ADB[@]}" shell "cd $DIR && taskset $3 ./benchmark_model --graph=models/$1.tflite --num_threads=$4 \
         --use_xnnpack=$2 --num_runs=$ITERS 2>&1" | grep "count=" | tail -1 || true)
    if [ -n "$r" ]; then
      row+=" $(sed -E 's/.*median=([0-9]+).*p95=([0-9]+).*/\1 \2/' <<<"$r" | awk '{printf "%.2f / %.2f", $1/1000, $2/1000}') |"
    else
      row+=" fails |"
    fi
  done
  echo "$row"
}

for m in "${ORT_MODELS[@]}"; do
  ort_row "${m%%:*}" "${m#*:}" cpu
  ort_row "${m%%:*}" "${m#*:}" xnnpack
done
for m in "${TFLITE_MODELS[@]}"; do
  tflite_row "$m" true
  tflite_row "$m" false
done
