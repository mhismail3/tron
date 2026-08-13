#import "PrivateVariableBlurBridge.h"

#if TRON_PRIVATE_VARIABLE_BLUR
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#endif

NSObject * _Nullable TronMakePrivateVariableBlurFilter(void) {
#if TRON_PRIVATE_VARIABLE_BLUR
    @try {
        Class filterClass = NSClassFromString(@"CAFilter");
        SEL factorySelector = NSSelectorFromString(@"filterWithType:");
        if (filterClass == Nil || ![filterClass respondsToSelector:factorySelector]) {
            return nil;
        }

        return ((id (*)(id, SEL, id))objc_msgSend)(
            filterClass,
            factorySelector,
            @"variableBlur"
        );
    } @catch (__unused NSException *exception) {
        return nil;
    }
#else
    return nil;
#endif
}

BOOL TronConfigurePrivateVariableBlurFilter(
    NSObject *filter,
    UIVisualEffectView *effectView,
    CGFloat radius,
    CGImageRef maskImage
) {
#if TRON_PRIVATE_VARIABLE_BLUR
    @try {
        UIView *backdropView = nil;
        for (UIView *subview in effectView.subviews) {
            NSString *className = NSStringFromClass(subview.class);
            if ([className localizedCaseInsensitiveContainsString:@"backdrop"]) {
                backdropView = subview;
                break;
            }
        }
        if (backdropView == nil) { return NO; }

        [filter setValue:@(radius) forKey:@"inputRadius"];
        [filter setValue:(__bridge id)maskImage forKey:@"inputMaskImage"];
        [filter setValue:@YES forKey:@"inputNormalizeEdges"];
        [backdropView.layer setValue:@[filter] forKey:@"filters"];

        for (UIView *subview in effectView.subviews) {
            if (subview != backdropView) { subview.alpha = 0; }
        }
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
#else
    return NO;
#endif
}
