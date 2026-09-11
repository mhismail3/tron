#include "transport.h"
#import <Security/Security.h>
#include <stdexcept>
#include <atomic>
#ifdef TRON_CAPTURE_TEST
#include <mutex>
#endif

namespace capture {
#ifndef TRON_CAPTURE_TEST
// Neither callers nor mutable runtime settings supply endpoints or expected
// identities. The actual signed Node's publisher pins the canonical wrapper;
// that validated installed composition pins the exact native host build.
static NSString *hostRequirement() {
    SecCodeRef self = nullptr;
    CFDictionaryRef selfInfo = nullptr;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess)
        throw std::runtime_error("native capture signing identity unavailable");
    OSStatus status = SecCodeCopySigningInformation(self, kSecCSSigningInformation, &selfInfo);
    CFRelease(self);
    NSDictionary *info = CFBridgingRelease(selfInfo);
    NSString *team = info[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    if (status != errSecSuccess || ![team isKindOfClass:NSString.class] ||
        [team rangeOfString:@"^[A-Z0-9]{10}$" options:NSRegularExpressionSearch].location == NSNotFound)
        throw std::runtime_error("native capture signed publisher unavailable");
    NSString *base = [NSString stringWithFormat:@"anchor apple generic and certificate leaf[subject.OU] = \"%@\" and identifier ", team];
    auto pin = [](NSString *path, NSString *requirement) -> NSString * {
        SecStaticCodeRef code = nullptr;
        SecRequirementRef expected = nullptr;
        CFDictionaryRef signing = nullptr;
        OSStatus result = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path], kSecCSDefaultFlags, &code);
        if (result == errSecSuccess)
            result = SecRequirementCreateWithString((__bridge CFStringRef)requirement, kSecCSDefaultFlags, &expected);
        if (result == errSecSuccess) result = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, expected);
        if (result == errSecSuccess) result = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &signing);
        if (expected) CFRelease(expected);
        if (code) CFRelease(code);
        NSDictionary *details = CFBridgingRelease(signing);
        NSData *hash = details[(__bridge NSString *)kSecCodeInfoUnique];
        if (result != errSecSuccess || ![hash isKindOfClass:NSData.class] || hash.length != 20)
            throw std::runtime_error("canonical installed native capture host is unavailable; manual signed Mac app update required");
        NSMutableString *hex = [NSMutableString stringWithCapacity:40];
        for (NSUInteger i = 0; i < hash.length; ++i) [hex appendFormat:@"%02x", ((const uint8_t *)hash.bytes)[i]];
        return [requirement stringByAppendingFormat:@" and cdhash H\"%@\"", hex];
    };
    (void)pin(@"/Applications/Tron.app", [base stringByAppendingString:@"\"com.tron.mac\""]);
    return pin(@"/Applications/Tron.app/Contents/Library/Native/Tron Native Host.app",
               [base stringByAppendingString:@"\"com.tron.mac.native-host\""]);
}

class XPCTransport final : public Transport {
    NSXPCConnection *connection_ = nil;
    std::shared_ptr<std::atomic<bool>> terminal_ = std::make_shared<std::atomic<bool>>(false);
public:
    void open(Lost lost) override {
        NSString *requirement = hostRequirement();
        connection_ = [[NSXPCConnection alloc] initWithMachServiceName:@"com.tron.mac.native-host.capture" options:0];
        connection_.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(TronNativeCaptureService)];
        [connection_ setCodeSigningRequirement:requirement];
        __weak NSXPCConnection *weak = connection_;
        auto terminal = terminal_;
        connection_.interruptionHandler = ^{
            terminal->store(true);
            // NSXPC interruption otherwise permits reconnect. Invalidate at
            // the native boundary, not after the Node loop drains a TSFN.
            [weak invalidate];
            lost();
        };
        connection_.invalidationHandler = ^{ terminal->store(true); lost(); };
        [connection_ resume];
    }
    void send(size_t, NSData *request, Reply reply) override {
        if (terminal_->load()) throw std::runtime_error("native capture connection terminal");
        // Check+send is not atomic with interruption. An already-admitted call
        // can race invalidation and is uncertain; never allocate a successor.
        id<TronNativeCaptureService> peer = [connection_ remoteObjectProxyWithErrorHandler:^(NSError *) {
            reply(nil, nil);
        }];
        [peer executeCaptureRequest:request withReply:^(NSData *control, NSData *jpeg) {
            reply(control, jpeg);
        }];
    }
    void invalidate() override {
        terminal_->store(true);
        NSXPCConnection *connection = connection_;
        connection_ = nil;
        connection.interruptionHandler = nil;
        connection.invalidationHandler = nil;
        [connection invalidate];
    }
    ~XPCTransport() override { invalidate(); }
};
std::shared_ptr<Transport> makeTransport() { return std::make_shared<XPCTransport>(); }
#else
static std::mutex delayedMutex;
static std::function<void()> delayedReply; // one bounded, explicitly released test-edge reply
static std::atomic<unsigned> deliveries{0};
void deliverDelayedReply() {
    std::function<void()> reply;
    { std::lock_guard lock(delayedMutex); reply = std::move(delayedReply); delayedReply = {}; }
    if (!reply) throw std::runtime_error("no delayed test reply");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        reply();
        ++deliveries; // observable AFTER the actual weak callback returned
    });
}
unsigned delayedReplyCount() { return deliveries.load(); }
// Fixed-size retained callbacks deliberately survive invalidation. A delayed
// reply must be harmless even after the real owner or Node worker has retired.
class TestTransport final : public Transport {
    Reply replies_[5];
    Lost lost_;
    bool delayUsed_ = false, terminal_ = false;
public:
    void open(Lost lost) override { lost_ = std::move(lost); }
    void send(size_t slot, NSData *, Reply reply) override {
        if (terminal_) throw std::runtime_error("native capture connection terminal");
        replies_[slot] = std::move(reply);
    }
    void invalidate() override { terminal_ = true; }
    void reply(size_t slot, NSData *control, NSData *jpeg, bool delayed) override {
        if (slot >= 5 || !replies_[slot]) throw std::runtime_error("test slot not admitted");
        Reply reply = replies_[slot];
        if (!delayed) { reply(control, jpeg); return; }
        if (delayUsed_) throw std::runtime_error("one delayed callback per test transport");
        std::lock_guard lock(delayedMutex);
        if (delayedReply) throw std::runtime_error("delayed test edge capacity exhausted");
        delayUsed_ = true;
        delayedReply = [reply, control, jpeg] { reply(control, jpeg); };
    }
    void lose() override { terminal_ = true; lost_(); }
};
std::shared_ptr<Transport> makeTransport() { return std::make_shared<TestTransport>(); }
#endif
}
