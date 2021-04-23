#include <limits>

#include <ATen/ATen.h>
#include <ATen/WrapDimUtils.h>
#include <ATen/LegacyTHFunctionsCUDA.h>
#include <ATen/core/Array.h>
#include <ATen/cuda/cub.cuh>
#include <ATen/cuda/detail/KernelUtils.h>

namespace at { namespace native {

bool should_use_th_sort(const Tensor &self, int64_t dim) {
  int64_t ndim = self.dim();
  dim = maybe_wrap_dim(dim, ndim);
  int64_t nsort = self.sizes()[dim];
  int64_t threshold;
  if (self.scalar_type() == kLong || self.scalar_type() == kDouble) {
    threshold = 1024;
  } else {
    threshold = 2048;
  }
  return nsort <= threshold;
}

std::vector<int64_t> infer_dense_strides_dim_last(const Tensor & self, int64_t dim);

// If the dim being sorted is smaller than 2048/1024, then we will use the
// implementation THC. Otherwise we use cub's segmented sort
std::tuple<Tensor &,Tensor &> sort_out_stable_cuda(const Tensor & self, c10::optional<bool> stable, int64_t dim, bool descending, Tensor & values, Tensor & indices) {
  if (should_use_th_sort(self, dim)) {
    return legacy::cuda::_th_sort_out_stable(self, stable, dim, descending, values, indices);
  }
  // this algorithm is always stable
  TORCH_INTERNAL_ASSERT(stable.has_value(), "sort_out(): c10::optional<bool> for stable has to have value.");
  bool is_non_overlapping_and_dense = self.is_non_overlapping_and_dense();
  int64_t numel = self.numel();
  int64_t ndim = self.dim();
  dim = maybe_wrap_dim(dim, ndim);
  int64_t nsort = self.sizes()[dim];

  TORCH_CHECK(nsort <= std::numeric_limits<int>::max(),
    "The dimension being sorted can not have more than INT_MAX elsments.");

  if (ndim == 0) {
    if (!values.defined()) {
      values = self.clone();
    } else {
      values.resize_as_(self);
      values.copy_(self);
    }
    if (!indices.defined()) {
      indices = at::zeros({}, self.options().dtype(kLong));
    } else {
      indices.resize_as_(self);
      indices.zero_();
    }
    return std::forward_as_tuple(values, indices);
  }

  Tensor self_;
  if (is_non_overlapping_and_dense && self.stride(dim) == 1) {
    self_ = self;
  } else {
    auto new_strides_unsort = infer_dense_strides_dim_last(self, dim);
    self_ = at::empty_strided(self.sizes(), new_strides_unsort, self.options());
    self_.copy_(self);
  }

  Tensor values_tmp, indices_tmp;
  void *values_ptr_;
  int64_t *indices_ptr;
  if (!values.defined()) {
    if (is_non_overlapping_and_dense) {
      values = at::empty_strided(self.sizes(), self.strides(), self.options());
    } else {
      auto strides = at::infer_dense_strides(self.sizes(), self.strides());
      values = at::empty_strided(self.sizes(), strides, self.options());
    }
  } else {
    TORCH_CHECK(self_.scalar_type() == values.scalar_type(),
      "Unexpected dtype for values, expect ", self_.scalar_type(), ", got ", values.scalar_type());
    values.resize_as_(self);
  }
  if (values.strides() != self_.strides()) {
    values_tmp = at::empty_strided(self_.sizes(), self_.strides(), self_.options());
    values_ptr_ = values_tmp.data_ptr();
  } else {
    values_ptr_ = values.data_ptr();
  }

  if (!indices.defined()) {
    if (is_non_overlapping_and_dense) {
      indices = at::empty_strided(self.sizes(), self.strides(), self.options().dtype(kLong));
    } else {
      auto strides = at::infer_dense_strides(self.sizes(), self.strides());
      indices = at::empty_strided(self.sizes(), strides, self.options().dtype(kLong));
    }
  } else {
    TORCH_CHECK(kLong == indices.scalar_type(),
      "Unexpected dtype for values, expect torch.long, got ", indices.scalar_type());
    indices.resize_as_(self);
  }
  if (indices.strides() != self_.strides()) {
    indices_tmp = at::empty_strided(self_.sizes(), self_.strides(), self_.options().dtype(kLong));
    indices_ptr = indices_tmp.data_ptr<int64_t>();
  } else {
    indices_ptr = indices.data_ptr<int64_t>();
  }

  if (numel == 0) {
    return std::forward_as_tuple(values, indices);
  }

  int64_t numel_or_intmax = std::min(numel, static_cast<int64_t>(std::numeric_limits<int>::max()));
  int64_t nbatch = (numel_or_intmax / nsort) * nsort;

  AT_DISPATCH_ALL_TYPES_AND2(kBool, kHalf, self_.scalar_type(), "sort", [&]{
    const scalar_t *self_ptr = self_.data_ptr<scalar_t>();
    auto values_ptr = reinterpret_cast<scalar_t *>(values_ptr_);
    int64_t remaining = numel;
    while (remaining > 0) {
      int64_t n = std::min(remaining, nbatch);
      int64_t nsegments = n / nsort;

      auto int_options = indices.options().dtype(kInt);
      auto offset_begins = at::arange(0, n, nsort, int_options);
      auto offset_ends = at::arange(nsort, n + nsort, nsort, int_options);
      auto reverse_indices = at::arange(nsort, indices.options()).view({1, nsort}).expand({nsegments, nsort}).contiguous();

      at::cuda::cub::segmented_sort_pairs(self_ptr, values_ptr,
        reverse_indices.data_ptr<int64_t>(), indices_ptr, n, nsegments,
        offset_begins.data_ptr<int>(), offset_ends.data_ptr<int>(), descending);

      remaining -= n;
      self_ptr += n;
      values_ptr += n;
      indices_ptr += n;
    }
  });

  if (values_tmp.defined()) {
    values.copy_(values_tmp);
  }
  if (indices_tmp.defined()) {
    indices.copy_(indices_tmp);
  }
  return std::forward_as_tuple(values, indices);
}

// If the dim being sorted is smaller than 2048/1024, then we will use the
// implementation THC. Otherwise we use cub's segmented sort
std::tuple<Tensor &,Tensor &> sort_out_cuda(const Tensor & self, int64_t dim, bool descending, Tensor & values, Tensor & indices) {
  if (should_use_th_sort(self, dim)) {
    return legacy::cuda::_th_sort_out(self, dim, descending, values, indices);
  }
  return sort_out_stable_cuda(self, /*stable=*/false, dim, descending, values, indices);
}

// If the dim being sorted is smaller than 2048/1024, then we will use the
// implementation THC. Otherwise we use cub's segmented sort
std::tuple<Tensor,Tensor> sort_stable_cuda(const Tensor & self, c10::optional<bool> stable, int64_t dim, bool descending) {
  if (should_use_th_sort(self, dim)) {
    return legacy::cuda::_th_sort_stable(self, stable, dim, descending);
  }
  Tensor values, indices;
  return sort_out_stable_cuda(self, stable, dim, descending, values, indices);
}

// If the dim being sorted is smaller than 2048/1024, then we will use the
// implementation THC. Otherwise we use cub's segmented sort
std::tuple<Tensor,Tensor> sort_cuda(const Tensor & self, int64_t dim, bool descending) {  int64_t threshold;
  if (should_use_th_sort(self, dim)) {
    return legacy::cuda::_th_sort(self, dim, descending);
  }
  return sort_stable_cuda(self, /*stable=*/false, dim, descending);
}

}}  // namespace at::native
