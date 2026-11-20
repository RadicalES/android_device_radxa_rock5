#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Downloads the public reference models into $OUT/models (default: ./out/models).
# The models are not redistributed here; check each one's license before using it in a
# product. InsightFace's buffalo_l (SCRFD, ArcFace) is for non-commercial research only.

set -euo pipefail

OUT=${OUT:-out}
M="$OUT/models"
mkdir -p "$M"

get() {  # get <file> <url>
  [ -s "$M/$1" ] || curl -sfL -o "$M/$1" "$2" || { rm -f "$M/$1"; echo "failed: $1" >&2; exit 1; }
}

HF=https://huggingface.co/PaddlePaddle
get pp_ocrv6_small_det.onnx    "$HF/PP-OCRv6_small_det_onnx/resolve/main/inference.onnx"
get pp_ocrv6_small_rec.onnx    "$HF/PP-OCRv6_small_rec_onnx/resolve/main/inference.onnx"
get pp_ocrv5_arabic_rec.onnx   "$HF/arabic_PP-OCRv5_mobile_rec_onnx/resolve/main/inference.onnx"
get pp_lcnet_doc_ori.onnx      "$HF/PP-LCNet_x1_0_doc_ori_onnx/resolve/main/inference.onnx"

MP=https://storage.googleapis.com/mediapipe-models
get blazeface_short.tflite     "$MP/face_detector/blaze_face_short_range/float16/latest/blaze_face_short_range.tflite"
get selfie_segmenter.tflite    "$MP/image_segmenter/selfie_segmenter/float16/latest/selfie_segmenter.tflite"
if [ ! -s "$M/face_landmarks.tflite" ]; then
  get face_landmarker.task     "$MP/face_landmarker/face_landmarker/float16/latest/face_landmarker.task"
  unzip -p "$M/face_landmarker.task" face_landmarks_detector.tflite > "$M/face_landmarks.tflite"
  rm "$M/face_landmarker.task"
fi

if [ ! -s "$M/scrfd_10g.onnx" ]; then
  get buffalo_l.zip https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
  unzip -p "$M/buffalo_l.zip" det_10g.onnx > "$M/scrfd_10g.onnx"
  unzip -p "$M/buffalo_l.zip" w600k_r50.onnx > "$M/arcface_r50.onnx"
  rm "$M/buffalo_l.zip"
fi

ls -l "$M"
