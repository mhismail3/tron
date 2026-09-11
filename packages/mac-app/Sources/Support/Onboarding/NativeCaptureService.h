#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Canonical NSXPC contract for Swift NativeHost and the direct Objective-C++
// Node-API client. Import this header; do not redeclare the protocol in the addon.
// Control is UTF-8 JSON <= 64 KiB; the optional JPEG is separate and <= 2 MiB.
// See docs/computer-control.md, "Installed capture wire contract" for schema.
@protocol TronNativeCaptureService
- (void)executeCaptureRequest:(NSData *)request
                   withReply:(void (NS_SWIFT_SENDABLE ^)(NSData *control, NSData * _Nullable jpeg))reply;
@end

NS_ASSUME_NONNULL_END
