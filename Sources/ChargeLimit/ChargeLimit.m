#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "ChargeLimit.h"

int STReadChargeLimit(void) {
    @autoreleasepool {
        static void *framework;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            framework = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_LAZY);
        });
        if (!framework) return 0;
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        SEL init = NSSelectorFromString(@"initWithClientName:");
        SEL read = NSSelectorFromString(@"getMCLLimitWithError:");
        SEL enabled = NSSelectorFromString(@"isMCLCurrentlyEnabled:");
        if (!cls || ![cls instancesRespondToSelector:init]) return 0;
        id client = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], init, @"StatusTrio");
        int result = 0;
        if ([client respondsToSelector:read] && [client respondsToSelector:enabled]) {
            NSError *error = nil;
            unsigned long long on = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client, enabled, &error);
            if (!error && on) {
                unsigned char limit = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(client, read, &error);
                if (!error && limit >= 1 && limit <= 100) result = limit;
            }
        }
#if !__has_feature(objc_arc)
        [client release];
#endif
        return result;
    }
}
