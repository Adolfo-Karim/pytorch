#pragma once

#include <istream>
#include <memory>

namespace caffe2 {
namespace serialize {
class ReadAdapterInterface;
class PyTorchStreamWriter;
} // namespace serialize
} // namespace caffe2

namespace torch {
namespace jit {
namespace mobile {

// The family of methods below load a serialized Mobile Module
TORCH_API bool _backport_for_mobile(std::istream& in, std::ostream& out);

TORCH_API bool _backport_for_mobile(
    std::istream& in,
    const std::string& output_filename);

TORCH_API bool _backport_for_mobile(
    const std::string& input_filename,
    std::ostream& out);

TORCH_API bool _backport_for_mobile(
    const std::string& input_filename,
    const std::string& output_filename);

TORCH_API bool _backport_for_mobile(
    std::shared_ptr<caffe2::serialize::ReadAdapterInterface> rai,
    std::shared_ptr<caffe2::serialize::PyTorchStreamWriter> writer);

} // namespace mobile
} // namespace jit
} // namespace torch
