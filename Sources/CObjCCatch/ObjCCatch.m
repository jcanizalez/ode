#import "include/ObjCCatch.h"

BOOL ODECatchObjCException(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            NSString *reason = e.reason ?: e.name;
            *error = [NSError errorWithDomain:@"ode.objc-exception"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}
