#pragma once
#import "../Sources/Support/Onboarding/NativeCaptureService.h"
#include <functional>
#include <memory>

namespace capture {
constexpr size_t ControlLimit = 65536;
constexpr size_t JPEGLimit = 2 * 1024 * 1024;
using Reply = std::function<void(NSData *, NSData *)>;
using Lost = std::function<void()>;
// The NSXPC edge. The addon owner, request slots, TSFNs, cleanup hooks and
// buffer copies never depend on which transport carries a request.
class Transport {
public:
    virtual ~Transport() = default;
    virtual void open(Lost lost) = 0;
    virtual void send(size_t slot, NSData *request, Reply reply) = 0;
    virtual void invalidate() = 0;
};
std::shared_ptr<Transport> makeTransport();
}
