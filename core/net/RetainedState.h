#pragma once

#include <atomic>
#include <type_traits>
#include <utility>

namespace rctl {

// Private cross-queue state, with no weak references or polymorphic deleter.
// iOS 14's arm64e libc++ cannot authenticate the shared_ptr control-block
// vtable emitted by the current toolchain. Keep destruction entirely in the
// owning payload rather than crossing that runtime ABI or disabling PAC.
template <typename T> class RetainedState {
    static_assert(!std::is_polymorphic<T>::value, "State must not cross a virtual ABI");
    struct Storage {
        std::atomic<unsigned> references{1};
        T value;
        template <typename... Args>
        explicit Storage(Args &&...args) : value(std::forward<Args>(args)...) {}
    };
    Storage *storage_ = nullptr;
    explicit RetainedState(Storage *storage) noexcept : storage_(storage) {}
    void retain() noexcept {
        if (storage_) storage_->references.fetch_add(1, std::memory_order_relaxed);
    }
    void release() noexcept {
        if (storage_ && storage_->references.fetch_sub(1, std::memory_order_acq_rel) == 1)
            delete storage_;
    }
public:
    RetainedState() noexcept = default;
    RetainedState(const RetainedState &other) noexcept : storage_(other.storage_) { retain(); }
    RetainedState(RetainedState &&other) noexcept : storage_(other.storage_) { other.storage_ = nullptr; }
    ~RetainedState() { release(); }
    RetainedState &operator=(RetainedState other) noexcept { swap(other); return *this; }
    void swap(RetainedState &other) noexcept { std::swap(storage_, other.storage_); }
    void reset() noexcept { RetainedState().swap(*this); }
    explicit operator bool() const noexcept { return storage_ != nullptr; }
    T *operator->() const noexcept { return &storage_->value; }
    T &operator*() const noexcept { return storage_->value; }
    bool operator==(const RetainedState &other) const noexcept { return storage_ == other.storage_; }
    template <typename... Args> static RetainedState create(Args &&...args) {
        return RetainedState(new Storage(std::forward<Args>(args)...));
    }
};

} // namespace rctl
