#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TronNativeCaptureService
- (void)executeCaptureRequest:(NSData *)request
                   withReply:(void (NS_SWIFT_SENDABLE ^)(NSData *control, NSData * _Nullable jpeg))reply;
@end

NS_ASSUME_NONNULL_END
