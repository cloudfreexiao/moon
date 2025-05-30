#pragma once
#include "asio.hpp"
#include "common/buffer.hpp"

namespace moon {
using buffer_t = buffer;
class streambuf {
public:
    using const_buffers_type = asio::const_buffer;
    using mutable_buffers_type = asio::mutable_buffer;

    streambuf(buffer_t* buf, std::size_t maxsize = std::numeric_limits<std::size_t>::max()):
        buffer_(buf),
        max_size_(maxsize) {}

    std::size_t size() const noexcept {
        if (nullptr == buffer_)
            return 0;
        return buffer_->size();
    }

    std::size_t max_size() const noexcept {
        return max_size_;
    }

    std::size_t capacity() const noexcept {
        if (nullptr == buffer_)
            return 0;
        return buffer_->capacity();
    }

    const_buffers_type data() const noexcept {
        if (nullptr == buffer_)
            return asio::const_buffer { nullptr, 0 };
        return asio::const_buffer { buffer_->data(), buffer_->size() };
    }

    mutable_buffers_type prepare(std::size_t n) {
        if (nullptr == buffer_)
            return asio::mutable_buffer { nullptr, 0 };
        auto [k, v] = buffer_->prepare(n);
        return asio::mutable_buffer { k, v };
    }

    void commit(std::size_t n) {
        if (nullptr == buffer_)
            return;
        buffer_->commit_unchecked(n);
    }

    void consume(std::size_t n) {
        if (nullptr == buffer_)
            return;
        buffer_->consume_unchecked(n);
    }

private:
    buffer_t* buffer_;
    std::size_t max_size_;
};
} // namespace moon