#include "transport.h"
#import <Security/Security.h>
#include <stdexcept>
#include <atomic>

namespace capture {
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
}
