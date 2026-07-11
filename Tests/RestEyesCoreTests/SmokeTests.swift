import XCTest
@testable import RestEyesCore

final class SmokeTests: XCTestCase {
    func testSmoke() {
        XCTAssertEqual(RestEyesCore.version, "0.1.0")
    }
}
