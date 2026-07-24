import XCTest
@testable import ODEKit

final class ObjCExceptionTests: XCTestCase {
    func testExceptionBecomesThrownError() {
        XCTAssertThrowsError(try catchingObjCException {
            NSException(name: .invalidArgumentException,
                        reason: "required condition is false: format matches",
                        userInfo: nil).raise()
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("required condition"),
                          "the exception reason must survive into the error")
        }
    }

    func testCleanBlockRunsAndDoesNotThrow() throws {
        var ran = false
        try catchingObjCException { ran = true }
        XCTAssertTrue(ran)
    }
}
