#pragma once
#include "base_connection.hpp"
#include "common/static_string.hpp"
#include "streambuf.hpp"

namespace moon {
struct read_until {
    static constexpr size_t max_delim_size = 7;
    size_t max_size = 0;
    static_string<max_delim_size> delim;

    read_until(size_t max_size, std::string_view delims):
        max_size(max_size > 0 ? max_size : std::numeric_limits<size_t>::max()),
        delim(delims) {}
};

struct read_exactly {
    size_t size;
    int64_t session;
};

class stream_connection: public base_connection {
public:
    using base_connection_t = base_connection;

    template<
        typename... Args,
        std::enable_if_t<
            !std::disjunction_v<std::is_same<std::decay_t<Args>, stream_connection>...>,
            int> = 0>
    explicit stream_connection(Args&&... args):
        base_connection_t(std::forward<Args>(args)...),
        read_cache_(8192) {}

    direct_read_result read(size_t size, std::string_view delim, int64_t session) override {
        if (!is_open() || enum_has_any_bitmask(mask_, connection_mask::reading)) {
            CONSOLE_ERROR("invalid read operation. %u", fd_);
            return direct_read_result { false, { "Invalid read operation" } };
        }

        buffer* buf = read_cache_.as_buffer();
        buf->commit_unchecked(std::exchange(more_bytes_, 0));
        buf->consume_unchecked(std::exchange(consume_, 0));

        mask_ = mask_ | connection_mask::reading;
        read_cache_.session = session;

        return delim.empty() ? read(read_exactly { size }) : read(read_until { size, delim });
    }

private:
    direct_read_result read(read_until op) {
        if (size_t delim_size = op.delim.size(); read_cache_.size() >= delim_size) {
            std::string_view data { read_cache_.data(), read_cache_.size() };
            std::default_searcher searcher { op.delim.data(), op.delim.data() + delim_size };
            if (auto it = std::search(data.begin(), data.end(), searcher); it != data.end()) {
                mask_ = enum_unset_bitmask(mask_, connection_mask::reading);
                auto count = std::distance(data.begin(), it);
                read_cache_.as_buffer()->consume_unchecked(count + delim_size);
                return direct_read_result { true, { data.data(), static_cast<size_t>(count) } };
            }
        }

        asio::async_read_until(
            socket_,
            moon::streambuf(read_cache_.as_buffer(), op.max_size),
            op.delim.to_string_view(),
            [this,
             self = shared_from_this(),
             op](const asio::error_code& e, std::size_t bytes_transferred) {
                if (!e) {
                    response(bytes_transferred, op.delim.size());
                    return;
                }
                error(e);
            }
        );
        return direct_read_result { true, {} };
    }

    direct_read_result read(read_exactly op) {
        if (read_cache_.size() >= op.size) {
            mask_ = enum_unset_bitmask(mask_, connection_mask::reading);
            consume_ = op.size;
            return direct_read_result { true, { read_cache_.data(), op.size } };
        }

        std::size_t size = op.size - read_cache_.size();
        asio::async_read(
            socket_,
            moon::streambuf { read_cache_.as_buffer(), op.size },
            asio::transfer_exactly(size),
            [this, self = shared_from_this(), op](const asio::error_code& e, std::size_t) {
                if (!e) {
                    response(op.size, 0);
                    return;
                }
                error(e);
            }
        );
        return direct_read_result { true, {} };
    }

    void error(const asio::error_code& e, const std::string& additional = "") override {
        (void)additional;

        if (parent_ == nullptr) {
            return;
        }

        auto b = read_cache_.as_buffer();
        b->clear();

        if (e) {
            if (e == moon::error::read_timeout) {
                b->write_back(
                    moon::format("TIMEOUT %s.(%d)", e.message().data(), e.value())
                );
            } else if (e == asio::error::eof) {
                b->write_back(moon::format("EOF %s.(%d)", e.message().data(), e.value()));
            } else {
                b->write_back(
                    moon::format("SOCKET_ERROR %s.(%d)", e.message().data(), e.value())
                );
            }
        }

        parent_->close(fd_);
        if (enum_has_any_bitmask(mask_, connection_mask::reading)) {
            response(read_cache_.size(), 0, PTYPE_ERROR);
        }
        parent_ = nullptr;
    }

    void response(size_t count, size_t remove_tail, uint8_t type = PTYPE_SOCKET_TCP) {
        if (parent_ == nullptr) {
            return;
        }

        buffer* buf = read_cache_.as_buffer();
        size_t size = buf->size();
        assert(size >= count);

        more_bytes_ = (size - count) + remove_tail;
        consume_ = count;
        buf->revert(more_bytes_);
        read_cache_.type = type;
        read_cache_.sender = fd_;

        mask_ = enum_unset_bitmask(mask_, connection_mask::reading);

        assert(read_cache_.session != 0);
        handle_message(read_cache_);
    }

protected:
    size_t more_bytes_ = 0;
    size_t consume_ = 0;
    message read_cache_;
};
} // namespace moon