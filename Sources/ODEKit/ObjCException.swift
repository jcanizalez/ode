import Foundation
import CObjCCatch

/// Runs `body`, converting any Objective-C exception into a thrown Swift
/// error. AVFAudio raises NSExceptions ("required condition is false: …")
/// when a device's format changes under it — e.g. between validating the
/// input format and installing a tap while a call is starting and devices
/// are renegotiating. Swift cannot catch those; unwrapped, they abort the
/// whole app.
func catchingObjCException(_ body: () -> Void) throws {
    var error: NSError?
    guard ODECatchObjCException(body, &error) else {
        throw error ?? NSError(domain: "ode.objc-exception", code: -1,
                               userInfo: [NSLocalizedDescriptionKey:
                                 "Unknown Objective-C exception"])
    }
}
