#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Fetches the benchmark tools and builds ort_bench for arm64 Android, into $OUT
# (default: ./out). Nothing here goes into the image; run.sh adb-pushes $OUT.
#
#   NDK=/path/to/android-ndk-r27d [ORT_VERSION=1.30.0] [OUT=out] tools/ml/build.sh
#
# ONNX Runtime comes from its published Android AAR on Maven Central (the library apps
# ship); LiteRT's benchmark_model is Google's prebuilt nightly for android_aarch64.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
: "${NDK:?set NDK to an Android NDK (r27 or later)}"
ORT_VERSION=${ORT_VERSION:-1.30.0}
OUT=${OUT:-out}
API=29

mkdir -p "$OUT/dl"
OUT=$(cd "$OUT" && pwd)

AAR="$OUT/dl/onnxruntime-android-$ORT_VERSION.aar"
ORT="$OUT/dl/ort-$ORT_VERSION"
if [ ! -d "$ORT" ]; then
  curl -sfL -o "$AAR" \
    "https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/$ORT_VERSION/onnxruntime-android-$ORT_VERSION.aar"
  unzip -q -o "$AAR" "headers/*" "jni/arm64-v8a/libonnxruntime.so" -d "$ORT"
fi

if [ ! -f "$OUT/benchmark_model" ]; then
  curl -sfL -o "$OUT/benchmark_model" \
    https://storage.googleapis.com/tensorflow-nightly-public/prod/tensorflow/release/lite/tools/nightly/latest/android_aarch64_benchmark_model
fi

CXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android$API-clang++"
"$CXX" -std=c++17 -O2 -Wall -Wextra -Werror -I"$ORT/headers" "$HERE/ort_bench.cc" \
  -static-libstdc++ -L"$ORT/jni/arm64-v8a" -lonnxruntime -Wl,-rpath,'$ORIGIN' -o "$OUT/ort_bench"
cp "$ORT/jni/arm64-v8a/libonnxruntime.so" "$OUT/"

echo "$OUT: $(cd "$OUT" && ls ort_bench libonnxruntime.so benchmark_model | tr '\n' ' ')"
