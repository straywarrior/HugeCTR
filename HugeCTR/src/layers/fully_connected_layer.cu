/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


#include "HugeCTR/include/layers/fully_connected_layer.hpp"

#include <math.h>
#include <vector>
#include "HugeCTR/include/data_parser.hpp"
#define FINAL_MASK 0xffffffff
namespace HugeCTR {

FullyConnectedLayer::FullyConnectedLayer(GeneralBuffer<float>& weight_buff,
                                         GeneralBuffer<float>& wgrad_buff, Tensor<float>& in_tensor,
                                         Tensor<float>& out_tensor, TensorFormat_t weight_format,
                                         cublasHandle_t const& cublas_handle, int device_id)
    : cublas_handle_(cublas_handle), Layer(device_id) {
  try {
    // check the in_tensor and out_tensor
    std::vector<int> in_tensor_dim = in_tensor.get_dims();
    std::vector<int> out_tensor_dim = out_tensor.get_dims();
    // 1. two dim?
    if (in_tensor_dim.size() != 2 || out_tensor_dim.size() != 2) {
      CK_THROW_(Error_t::WrongInput, "input or output tensor doesn't has two dimensions");
    }
    // 2. dim match?
    assert(in_tensor.get_format() == TensorFormat_t::WH ||
           in_tensor.get_format() == TensorFormat_t::HW);
    assert(out_tensor.get_format() == TensorFormat_t::WH ||
           out_tensor.get_format() == TensorFormat_t::HW);
    int m = in_tensor.get_format() == TensorFormat_t::WH ? in_tensor_dim[1] : in_tensor_dim[0];
    int n = out_tensor.get_format() == TensorFormat_t::WH ? out_tensor_dim[0] : out_tensor_dim[1];
    int k = in_tensor.get_format() == TensorFormat_t::WH ? in_tensor_dim[0] : in_tensor_dim[1];
    int m_ck =
        out_tensor.get_format() == TensorFormat_t::WH ? out_tensor_dim[1] : out_tensor_dim[0];
    if (m != m_ck) {
      CK_THROW_(Error_t::WrongInput, "size of input / output tensor doesn't match");
    }

    std::vector<int> weight_dim;
    std::vector<int> bias_dim;
    if (weight_format == TensorFormat_t::WH) {
      weight_dim = {n, k};
      bias_dim = {n, 1};
    } else if (weight_format == TensorFormat_t::HW) {
      weight_dim = {k, n};
      bias_dim = {1, n};
    } else {
      CK_THROW_(Error_t::WrongInput, "weight_format doesn't match Mlp Layer");
    }

    weights_.push_back(new Tensor<float>(weight_dim, weight_buff, weight_format));
    weights_.push_back(new Tensor<float>(bias_dim, weight_buff, weight_format));
    wgrad_.push_back(new Tensor<float>(weight_dim, wgrad_buff, weight_format));
    wgrad_.push_back(new Tensor<float>(bias_dim, wgrad_buff, weight_format));
    in_tensors_.push_back(std::ref(in_tensor));
    out_tensors_.push_back(std::ref(out_tensor));
    // Where should we create this cuBLAS handle?
  } catch (const std::runtime_error& rt_err) {
    std::cerr << rt_err.what() << std::endl;
    throw;
  }
}
void __global__ add_bias_kernel_row(float* data, const float* bias, const int m, const int n) {
  int offset = blockIdx.x * n;
  for (int tid = threadIdx.x; tid < n; tid += blockDim.x) {
    data[offset + tid] += bias[tid];
  }
}
void __global__ add_bias_kernel_col(float* data, const float* bias, const int m, const int n) {
  int offset = blockIdx.x * m;
  float b = bias[blockIdx.x];
  for (int tid = threadIdx.x; tid < m; tid += blockDim.x) {
    data[offset + tid] += b;
  }
}
void add_bias(float* data, const float* bias, const int m, const int n, bool row_major,
              cudaStream_t stream) {
  if (row_major) {
    dim3 grid(m);
    dim3 block(min(n, 1024));
    add_bias_kernel_row<<<grid, block, 0, stream>>>(data, bias, m, n);
  } else {
    dim3 grid(n);
    dim3 block(min(m, 1024));
    add_bias_kernel_col<<<grid, block, 0, stream>>>(data, bias, m, n);
  }
#ifndef NDEBUG
  cudaDeviceSynchronize();
  CK_CUDA_THROW_(cudaGetLastError());
#endif
}

void FullyConnectedLayer::fprop(cudaStream_t stream) {
  CK_CUBLAS_THROW_(cublasSetStream(cublas_handle_, stream));
  int o_device = -1;
  CK_CUDA_THROW_(get_set_device(get_device_id(), &o_device));

  Tensor<float> in_tensor = in_tensors_[0];
  Tensor<float> out_tensor = out_tensors_[0];

  float* weight = (weights_[0])->get_ptr();
  float* bias = (weights_[1])->get_ptr();
  float* in = in_tensor.get_ptr();
  float* out = out_tensor.get_ptr();

  std::vector<int> in_tensor_dim = in_tensor.get_dims();
  std::vector<int> out_tensor_dim = out_tensor.get_dims();

  int m, n, k;

  m = in_tensor.get_format() == TensorFormat_t::WH ? in_tensor_dim[1] : in_tensor_dim[0];
  n = out_tensor.get_format() == TensorFormat_t::WH ? out_tensor_dim[0] : out_tensor_dim[1];
  k = in_tensor.get_format() == TensorFormat_t::WH ? in_tensor_dim[0] : in_tensor_dim[1];

  float alpha = 1.0f, beta = 0.0f;

  cublasGemmAlgo_t algo;
#ifdef WMMA
  algo = CUBLAS_GEMM_DEFAULT_TENSOR_OP;
#else
  algo = CUBLAS_GEMM_DEFAULT;
#endif

  if ((weights_[0])->get_format() == TensorFormat_t::HW &&
      in_tensor.get_format() == TensorFormat_t::HW &&
      out_tensor.get_format() == TensorFormat_t::HW) {
    CK_CUBLAS_THROW_(cublasGemmEx(cublas_handle_, CUBLAS_OP_N, CUBLAS_OP_N, n, m, k, &alpha, weight,
                                  CUDA_R_32F, n, in, CUDA_R_32F, k, &beta, out, CUDA_R_32F, n,
                                  CUDA_R_32F, algo));
    add_bias(out, bias, m, n, true, stream);
  } else if ((weights_[0])->get_format() == TensorFormat_t::WH &&
             in_tensor.get_format() == TensorFormat_t::WH &&
             out_tensor.get_format() == TensorFormat_t::WH) {
    CK_CUBLAS_THROW_(cublasGemmEx(cublas_handle_, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, &alpha, in,
                                  CUDA_R_32F, m, weight, CUDA_R_32F, k, &beta, out, CUDA_R_32F, m,
                                  CUDA_R_32F, algo));
    add_bias(out, bias, m, n, false, stream);
  } else
    CK_THROW_(Error_t::UnSupportedFormat, "The format combination is not supported");

  CK_CUDA_THROW_(get_set_device(o_device));
}
__inline__ __device__ float warpReduceSum(float val) {
  for (int mask = 16; mask > 0; mask >>= 1) val += __shfl_xor_sync(FINAL_MASK, val, mask, 32);
  return val;
}

/* Calculate the sum of all elements in a block */
__inline__ __device__ float blockReduceSum(float val) {
  static __shared__ float shared[32];
  int lane = threadIdx.x & 0x1f;
  int wid = threadIdx.x >> 5;

  val = warpReduceSum(val);

  if (lane == 0) shared[wid] = val;

  __syncthreads();

  val = (threadIdx.x < (blockDim.x >> 5)) ? shared[lane] : 0;
  val = warpReduceSum(val);

  return val;
}
void __global__ cal_bias_grad_kernel_col(float* out, float* bias_grad, int m, int n,
                                         bool row_major) {
  float local_sum = 0.0f;
  if (!row_major) {
    int offset = blockIdx.x * m;
    for (int tid = threadIdx.x; tid < m; tid += blockDim.x) local_sum += out[tid + offset];
  } else {
    for (int tid = threadIdx.x; tid < m; tid += blockDim.x) local_sum += out[tid * n + blockIdx.x];
  }
  __syncthreads();
  local_sum = blockReduceSum(local_sum);
  if (threadIdx.x == 0) {
    bias_grad[blockIdx.x] = local_sum;
  }
}
void cal_bias_grad(float* out, float* bias_grad, int m, int n, bool row_major,
                   cudaStream_t stream) {
  dim3 grid(n);
  dim3 block(1024);
  cal_bias_grad_kernel_col<<<grid, block, 0, stream>>>(out, bias_grad, m, n, row_major);
#ifndef NDEBUG
  cudaDeviceSynchronize();
  CK_CUDA_THROW_(cudaGetLastError());
#endif
}

void FullyConnectedLayer::bprop(cudaStream_t stream) {
  CK_CUBLAS_THROW_(cublasSetStream(cublas_handle_, stream));

  int o_device = -1;
  CK_CUDA_THROW_(get_set_device(get_device_id(), &o_device));

  Tensor<float> in_tensor = in_tensors_[0];
  Tensor<float> out_tensor = out_tensors_[0];

  float* wgrad = (wgrad_[0])->get_ptr();
  float* bias_grad = (wgrad_[1])->get_ptr();
  float* weight = (weights_[0])->get_ptr();
  float* in = in_tensor.get_ptr();
  float* out = out_tensor.get_ptr();

  std::vector<int> in_tensor_dim = in_tensor.get_dims();
  std::vector<int> out_tensor_dim = out_tensor.get_dims();

  int m, n, k;

  m = in_tensor.get_format() == TensorFormat_t::WH ? in_tensor_dim[1] : in_tensor_dim[0];
  n = out_tensor.get_format() == TensorFormat_t::WH ? out_tensor_dim[0] : out_tensor_dim[1];
  k = in_tensor.get_format() == TensorFormat_t::WH ? in_tensor_dim[0] : in_tensor_dim[1];

  cublasGemmAlgo_t algo;
#ifdef WMMA
  algo = CUBLAS_GEMM_DEFAULT_TENSOR_OP;
#else
  algo = CUBLAS_GEMM_DEFAULT;
#endif

  float alpha = 1.0f, beta = 0.0f;
  // row-major
  if ((wgrad_[0])->get_format() == TensorFormat_t::HW &&
      in_tensor.get_format() == TensorFormat_t::HW &&
      out_tensor.get_format() == TensorFormat_t::HW) {
    // gradient respect to W
    CK_CUBLAS_THROW_(cublasGemmEx(cublas_handle_, CUBLAS_OP_N, CUBLAS_OP_T, n, k, m, &alpha, out,
                                  CUDA_R_32F, n, in, CUDA_R_32F, k, &beta, wgrad, CUDA_R_32F, n,
                                  CUDA_R_32F, algo));
    // gradient respect to Xn
    CK_CUBLAS_THROW_(cublasGemmEx(cublas_handle_, CUBLAS_OP_T, CUBLAS_OP_N, k, m, n, &alpha, weight,
                                  CUDA_R_32F, n, out, CUDA_R_32F, n, &beta, in, CUDA_R_32F, k,
                                  CUDA_R_32F, algo));
    cal_bias_grad(out, bias_grad, m, n, true, stream);
  }
  // Col-major
  else if ((weights_[0])->get_format() == TensorFormat_t::WH &&
           in_tensor.get_format() == TensorFormat_t::WH &&
           out_tensor.get_format() == TensorFormat_t::WH) {
    // gradient respect to W
    CK_CUBLAS_THROW_(cublasGemmEx(cublas_handle_, CUBLAS_OP_T, CUBLAS_OP_N, k, n, m, &alpha, in,
                                  CUDA_R_32F, m, out, CUDA_R_32F, m, &beta, wgrad, CUDA_R_32F, k,
                                  CUDA_R_32F, algo));
    // gradient respect to Xn
    CK_CUBLAS_THROW_(cublasGemmEx(cublas_handle_, CUBLAS_OP_N, CUBLAS_OP_T, m, k, n, &alpha, out,
                                  CUDA_R_32F, m, weight, CUDA_R_32F, k, &beta, in, CUDA_R_32F, m,
                                  CUDA_R_32F, algo));
    cal_bias_grad(out, bias_grad, m, n, false, stream);
  } else
    CK_THROW_(Error_t::UnSupportedFormat, "The format combination is not supported");
  CK_CUDA_THROW_(get_set_device(o_device));
}

std::vector<float> FullyConnectedLayer::get_initializer() {
  std::vector<float> initializer;
  initializer.resize((weights_[0])->get_num_elements() + (weights_[1])->get_num_elements());
  Tensor<float>& in_tensor = in_tensors_[0];
  float in_dim = in_tensor.get_format() == TensorFormat_t::WH ? (in_tensor.get_dims())[0]
                                                              : (in_tensor.get_dims())[1];
  float sigma = 1.f / sqrt(in_dim);
  HugeCTR::GaussianDataSimulator<float> fdata_sim(0.f, sigma, -2 * sigma, 2 * sigma);
  for (size_t i = 0; i < initializer.size(); i++) initializer[i] = fdata_sim.get_num();
  return initializer;
}

}  // namespace HugeCTR
