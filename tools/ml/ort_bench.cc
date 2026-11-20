// SPDX-License-Identifier: Apache-2.0
//
// ort_bench: latency benchmark for one ONNX model with ONNX Runtime on Android.
// Runs on the device (adb-pushed, never part of the image). Inputs are random; dynamic
// dimensions are 1 unless set with --shape. Pin cores from outside with taskset.
//
//   ort_bench model.onnx [--ep cpu|xnnpack] [--threads N] [--warmup N] [--iters N]
//             [--seconds S] [--shape name=1x3x640x640]...
//
// Prints one line: model ep threads iters median p95 mean min max (ms).

#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <numeric>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace {

[[noreturn]] void usage() {
  std::fprintf(stderr,
               "usage: ort_bench model.onnx [--ep cpu|xnnpack] [--threads N] [--warmup N]\n"
               "                 [--iters N] [--seconds S] [--shape name=1x3x640x640]...\n");
  std::exit(2);
}

std::vector<int64_t> parse_dims(const std::string& s) {
  std::vector<int64_t> dims;
  std::stringstream ss(s);
  std::string tok;
  while (std::getline(ss, tok, 'x')) dims.push_back(std::stoll(tok));
  return dims;
}

size_t element_size(ONNXTensorElementDataType t) {
  switch (t) {
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: return 4;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8: return 1;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8: return 1;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL: return 1;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT16: return 2;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT16: return 2;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16: return 2;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32: return 4;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: return 8;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE: return 8;
    default: return 0;
  }
}

double percentile(std::vector<double> v, double p) {
  std::sort(v.begin(), v.end());
  size_t i = static_cast<size_t>(p * (v.size() - 1) + 0.5);
  return v[i];
}

}  // namespace

static int bench(int argc, char** argv) {
  if (argc < 2) usage();
  std::string model = argv[1];
  std::string ep = "cpu";
  int threads = 4, warmup = 10, iters = 100;
  double seconds = 0;
  std::map<std::string, std::vector<int64_t>> shapes;

  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) usage();
      return argv[++i];
    };
    if (a == "--ep") ep = next();
    else if (a == "--threads") threads = std::stoi(next());
    else if (a == "--warmup") warmup = std::stoi(next());
    else if (a == "--iters") iters = std::stoi(next());
    else if (a == "--seconds") seconds = std::stod(next());
    else if (a == "--shape") {
      std::string s = next();
      auto eq = s.find('=');
      if (eq == std::string::npos) usage();
      shapes[s.substr(0, eq)] = parse_dims(s.substr(eq + 1));
    } else usage();
  }
  if (ep != "cpu" && ep != "xnnpack") usage();

  Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "ort_bench");
  Ort::SessionOptions so;
  so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
  if (ep == "xnnpack") {
    // XNNPACK runs its own thread pool; ORT's pool then only serves the CPU fallback nodes.
    so.SetIntraOpNumThreads(1);
    so.AddConfigEntry("session.intra_op.allow_spinning", "0");
    so.AppendExecutionProvider("XNNPACK", {{"intra_op_num_threads", std::to_string(threads)}});
  } else {
    so.SetIntraOpNumThreads(threads);
  }

  Ort::Session session(env, model.c_str(), so);
  Ort::AllocatorWithDefaultOptions alloc;
  Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

  std::mt19937 rng(42);
  std::vector<std::string> in_names, out_names;
  std::vector<std::vector<uint8_t>> buffers;
  std::vector<Ort::Value> inputs;

  for (size_t i = 0; i < session.GetInputCount(); ++i) {
    std::string name = session.GetInputNameAllocated(i, alloc).get();
    auto info = session.GetInputTypeInfo(i).GetTensorTypeAndShapeInfo();
    auto type = info.GetElementType();
    std::vector<int64_t> dims = info.GetShape();
    if (shapes.count(name)) {
      dims = shapes[name];
    } else {
      for (auto& d : dims)
        if (d < 0) d = 1;
    }
    size_t esize = element_size(type);
    if (esize == 0) {
      std::fprintf(stderr, "input %s: unsupported element type %d\n", name.c_str(), type);
      return 1;
    }
    size_t count = std::accumulate(dims.begin(), dims.end(), int64_t{1}, std::multiplies<int64_t>());
    std::vector<uint8_t> buf(count * esize);
    if (type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
      std::uniform_real_distribution<float> dist(0.f, 1.f);
      float* f = reinterpret_cast<float*>(buf.data());
      for (size_t k = 0; k < count; ++k) f[k] = dist(rng);
    } else if (type == ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8 || type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8) {
      for (auto& b : buf) b = static_cast<uint8_t>(rng());
    }  // other types stay zero (indices, masks)
    std::fprintf(stderr, "input %s:", name.c_str());
    for (auto d : dims) std::fprintf(stderr, " %lld", static_cast<long long>(d));
    std::fprintf(stderr, " (type %d)\n", type);
    inputs.push_back(Ort::Value::CreateTensor(mem, buf.data(), buf.size(), dims.data(), dims.size(), type));
    buffers.push_back(std::move(buf));
    in_names.push_back(name);
  }
  for (size_t i = 0; i < session.GetOutputCount(); ++i)
    out_names.push_back(session.GetOutputNameAllocated(i, alloc).get());

  std::vector<const char*> in_c, out_c;
  for (auto& n : in_names) in_c.push_back(n.c_str());
  for (auto& n : out_names) out_c.push_back(n.c_str());

  auto run = [&]() {
    session.Run(Ort::RunOptions{nullptr}, in_c.data(), inputs.data(), inputs.size(), out_c.data(),
                out_c.size());
  };

  for (int i = 0; i < warmup; ++i) run();

  using clock = std::chrono::steady_clock;
  std::vector<double> ms;
  auto start = clock::now();
  for (int i = 0;; ++i) {
    if (seconds > 0) {
      if (std::chrono::duration<double>(clock::now() - start).count() >= seconds) break;
    } else if (i >= iters) {
      break;
    }
    auto t0 = clock::now();
    run();
    ms.push_back(std::chrono::duration<double, std::milli>(clock::now() - t0).count());
  }

  const char* base = std::strrchr(model.c_str(), '/');
  base = base ? base + 1 : model.c_str();
  double mean = std::accumulate(ms.begin(), ms.end(), 0.0) / ms.size();
  std::printf("%s %s %d %zu %.2f %.2f %.2f %.2f %.2f\n", base, ep.c_str(), threads, ms.size(),
              percentile(ms, 0.5), percentile(ms, 0.95), mean, *std::min_element(ms.begin(), ms.end()),
              *std::max_element(ms.begin(), ms.end()));
  return 0;
}

int main(int argc, char** argv) {
  try {
    return bench(argc, argv);
  } catch (const Ort::Exception& e) {
    std::fprintf(stderr, "onnxruntime: %s\n", e.what());
    return 1;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "error: %s\n", e.what());
    return 1;
  }
}
