#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception — which Swift cannot
/// catch — and returning it as an NSError. AVFAudio raises NSExceptions for
/// "required condition" failures (e.g. a device format changing between
/// validation and installTap); without this shim those abort the process.
/// Returns YES if the block completed without raising.
BOOL ODECatchObjCException(void (NS_NOESCAPE ^block)(void),
                           NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
