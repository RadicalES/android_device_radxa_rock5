# Machine learning on the ROCK 5

How fast on-device inference runs on the RK3588, measured the same way each time, so every
accelerator path (GPU, NPU) is judged against the same CPU baseline. Tracking issue: #10.

## Running the benchmark

The tools run from `/data/local/tmp` over adb and are never part of the image.

```
NDK=/path/to/android-ndk-r27d tools/ml/build.sh   # ort_bench + libonnxruntime.so + LiteRT benchmark_model
tools/ml/models.sh                                # public reference models
ADB_SERIAL=<ip>:5555 tools/ml/run.sh > table.md
```

- **ONNX Runtime**: `ort_bench` (`tools/ml/ort_bench.cc`), built against the published Android AAR from
  Maven Central (`ORT_VERSION`, default 1.30.0), the same library apps ship. Inputs are random;
  `--ep cpu` is ORT's default CPU provider, `--ep xnnpack` the XNNPACK provider.
- **LiteRT**: Google's prebuilt `benchmark_model` for android_aarch64, with and without the XNNPACK delegate.
- Cores are pinned with `taskset`: CPUs 4-7 are the Cortex-A76s (mask `f0`), CPUs 0-3 the Cortex-A55s (`0f`).

### Models

All public; downloaded, not redistributed. Check each license before product use.

| Model | Source | Input | License |
|---|---|---|---|
| scrfd_10g | InsightFace `buffalo_l` (`det_10g`) | 1x3x640x640 | non-commercial research |
| arcface_r50 | InsightFace `buffalo_l` (`w600k_r50`), fp32 | 1x3x112x112 | non-commercial research |
| pp_ocrv6_small_det | PaddlePaddle `PP-OCRv6_small_det_onnx` | 1x3x640x960 | Apache-2.0 |
| pp_ocrv6_small_rec | PaddlePaddle `PP-OCRv6_small_rec_onnx` | 1x3x48x320 | Apache-2.0 |
| pp_ocrv5_arabic_rec | PaddlePaddle `arabic_PP-OCRv5_mobile_rec_onnx` | 1x3x48x320 | Apache-2.0 |
| pp_lcnet_doc_ori | PaddlePaddle `PP-LCNet_x1_0_doc_ori_onnx` | 1x3x224x224 | Apache-2.0 |
| blazeface_short | MediaPipe face detector, short range (fp16) | 1x128x128x3 | Apache-2.0 |
| face_landmarks | MediaPipe face landmarker, landmarks model (fp16) | 1x256x256x3 | Apache-2.0 |
| selfie_segmenter | MediaPipe selfie segmenter (fp16) | 1x256x256x3 | Apache-2.0 |

## CPU baseline

ROCK 5B (RK3588, 4 GB), Android 15 userdebug, kernel 6.18, A76 at 2.4 GHz and A55 at 1.8 GHz
(`schedutil`), ONNX Runtime 1.30.0, LiteRT nightly 2026-11-20. Median / p95 in ms, 50 runs after warm-up.

| Model | Runtime | A76 x1 | A76 x2 | A76 x4 | A55 x4 |
|---|---|---|---|---|---|
| scrfd_10g | ORT cpu | 998.34 / 998.73 | 510.74 / 511.15 | 270.26 / 270.58 | 1048.17 / 1050.48 |
| scrfd_10g | ORT xnnpack | fails | fails | fails | fails |
| arcface_r50 | ORT cpu | 466.35 / 466.70 | 289.84 / 291.39 | 187.64 / 189.15 | 601.31 / 603.46 |
| arcface_r50 | ORT xnnpack | 380.30 / 380.44 | 209.14 / 210.88 | 125.84 / 126.87 | 467.91 / 469.22 |
| pp_ocrv6_small_det | ORT cpu | 854.65 / 856.42 | 459.41 / 460.09 | 258.34 / 258.81 | 858.56 / 859.48 |
| pp_ocrv6_small_det | ORT xnnpack | 850.34 / 850.84 | 855.27 / 855.82 | 854.30 / 855.05 | 3053.08 / 3075.67 |
| pp_ocrv6_small_rec | ORT cpu | 89.95 / 90.06 | 48.06 / 48.22 | 27.77 / 27.84 | 103.07 / 104.81 |
| pp_ocrv6_small_rec | ORT xnnpack | fails | fails | fails | fails |
| pp_ocrv5_arabic_rec | ORT cpu | 70.74 / 70.84 | 40.96 / 41.11 | 26.37 / 26.44 | 89.90 / 92.31 |
| pp_ocrv5_arabic_rec | ORT xnnpack | fails | fails | fails | fails |
| pp_lcnet_doc_ori | ORT cpu | 23.76 / 23.84 | 13.72 / 13.77 | 8.86 / 8.90 | 30.77 / 31.89 |
| pp_lcnet_doc_ori | ORT xnnpack | 23.71 / 23.80 | 23.55 / 23.62 | 23.51 / 23.59 | 90.42 / 91.49 |
| blazeface_short | LiteRT XNNPACK | 3.14 / 3.17 | 1.75 / 1.79 | 1.06 / 1.07 | 3.36 / 3.42 |
| blazeface_short | LiteRT CPU | 4.09 / 4.12 | 7.96 / 8.21 | 5.76 / 6.70 | 17.14 / 18.07 |
| face_landmarks | LiteRT XNNPACK | 13.08 / 13.12 | 7.69 / 7.75 | 4.70 / 4.75 | 13.25 / 14.01 |
| face_landmarks | LiteRT CPU | 18.21 / 18.26 | 38.57 / 39.50 | 25.07 / 28.70 | 68.68 / 77.67 |
| selfie_segmenter | LiteRT XNNPACK | 7.54 / 7.61 | 4.55 / 4.63 | 2.93 / 2.97 | 10.92 / 11.30 |
| selfie_segmenter | LiteRT CPU | fails | fails | fails | fails |

### What it shows

- **Use the A76s.** One A76 does the work of about four A55s; ORT's CPU provider scales close to linearly
  over 1, 2 and 4 A76 threads. Four threads on the A76 cluster is the configuration to beat.
- **ORT's default CPU provider is the right ORT choice.** Its XNNPACK provider only helps ArcFace (fp32 convs,
  -33 %), stays at the 1-thread time on models it only partly covers (PP-OCR det, PP-LCNet: the nodes it
  does not take run on ORT's own pool, which `ort_bench` sets to 1 thread with XNNPACK as ORT's docs
  advise), and aborts the process on SCRFD and both PP-OCR recognisers.
- **LiteRT needs its XNNPACK delegate.** Without it the fp16 MediaPipe models get slower with more threads,
  and the selfie segmenter does not run at all.
- **Big detectors are far from camera rate on the CPU.** SCRFD-10G at 640x640 and PP-OCRv6 det at 640x960
  take ~260-270 ms on all four A76s. These are the first models for the GPU and NPU paths.

### Sustained load

SCRFD-10G on four A76 threads for 10 minutes (`ort_bench --seconds 600`): 2,210 runs,
median **271.5 ms** against 270.2 ms cold (+0.5 %). The A76 cluster stayed at 2.4 GHz throughout and the
big-core sensor levelled off at 54 °C, far below the trip points: the CPU does not throttle under this load.

Measure on a quiet board. An earlier 10-minute run, with the kiosk app on the device active at the same
time, gave a 488 ms median at the same clocks and temperatures: other work on the A76s, not heat.

## NPU (Rocket + Teflon)

The RK3588's three NPU cores run under the mainline Rocket driver (`DRM_ACCEL_ROCKET`), as
`/dev/accel/accel0`. Mesa's Teflon TFLite delegate drives it from inside the app, the same way Mesa
drives the GPU, so the image carries no closed binaries. Tracking: #6 (kernel), #4 (Mesa), #7 (apps).

### In the image

- `/vendor/lib64/libteflon.so`: Teflon built from the same Mesa 26.0 as PanVK (`RadicalES/android_external_mesa`,
  Rocket gallium driver plus `-Dteflon=true`; `tools/mesa/regen-android-bp.sh` and
  `tools/mesa/n2s-rocket-teflon.patch` generate its Soong build).
- `/vendor/etc/public.libraries.txt` lists it, so apps can load it by name. It is labelled `vendor_public_lib_file`,
  the AOSP type apps may map. Its vendor dependencies (`libdrm`, `libcutils`, `libhardware`, `libz`) are already
  `same_process_hal_file` for PanVK.
- `/dev/accel/accel0` is `0666 system graphics`, labelled `gpu_device` like `/dev/dri`, which apps may already open.

An app loads it as a LiteRT external delegate. Teflon exports the standard delegate plugin entry points,
`tflite_plugin_create_delegate` and `tflite_plugin_destroy_delegate`, so native code can `dlopen("libteflon.so")`
and add the returned `TfLiteDelegate` to its interpreter. LiteRT's external-delegate wrapper does the same, and so
does `benchmark_model --external_delegate_path`.

Teflon takes int8-quantized models only. Ops it does not support run on the CPU, and each switch between
the NPU and the CPU costs time, so check the partition count that LiteRT logs (`Replacing N out of M node(s)`).

### First result

MobileNet V1 1.0 224 int8 (`mobilenet_v1_1.0_224_quant.tflite`), `benchmark_model` run as `shell` with SELinux
enforcing, pinned to the A76s, 100 runs:

| Path | Nodes on the NPU | Median / p95 (ms) |
|---|---|---|
| NPU, `--external_delegate_path=/vendor/lib64/libteflon.so` | 28 of 31 (2 delegate kernels) | 12.42 / 12.77 |
| CPU, LiteRT XNNPACK, A76 x4 | none | 16.88 / 16.92 |

No avc denials during the run.

### The NPU clock

The NPU runs at **200 MHz**. The upstream device tree sets `assigned-clock-rates = <200000000>` and has no OPP
table or devfreq for it, as of mainline 7.4. Rockchip's BSP kernel scales it with an OPP table, up to 1 GHz. At 200 MHz, MobileNet takes only
27 % less time on the NPU than on the four A76s. Raising the clock needs an OPP table with the
matching `vdd_npu_s0` voltages (it is at 800 mV now). That is a separate step: see #7.

### Still to do

- SCRFD-10G and ArcFace as int8 TFLite models (the reference models are fp32 ONNX), with op coverage and
  accuracy against the CPU.
- A way for apps to detect the NPU (a vendor property or system feature).
- A check that an app can load `libteflon.so` under enforcing (so far only `shell` can).
