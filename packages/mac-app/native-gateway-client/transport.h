#pragma once
#import "../Sources/Support/Onboarding/NativeCaptureService.h"
#include <functional>
#include <memory>

namespace capture {
constexpr size_t ControlLimit = 65536;
constexpr size_t JPEGLimit = 2 * 1024 * 1024;
using Reply = std::function<void(NSData *, NSData *)>;
using Lost = std::function<void()>;
// Only this edge is replaced in the offline test artifact. The addon owner,
// request slots, TSFNs, cleanup hooks and buffer copies are always production.
class Transport {
public:
    virtual ~Transport() = default;
    virtual void open(Lost lost) = 0;
    virtual void send(size_t slot, NSData *request, Reply reply) = 0;
    virtual void invalidate() = 0;
#ifdef TRON_CAPTURE_TEST
    virtual void reply(size_t slot, NSData *control, NSData *jpeg, bool delayed) = 0;
    virtual void lose() = 0;
#endif
};
std::shared_ptr<Transport> makeTransport();
#ifdef TRON_CAPTURE_TEST
void deliverDelayedReply();
unsigned delayedReplyCount();
#endif
}
