import XCTest
@testable import RestEyesCore

final class FormatTests: XCTestCase {
    func testMMSS() {
        XCTAssertEqual(Format.mmss(0), "0:00")
        XCTAssertEqual(Format.mmss(59.4), "0:59")
        XCTAssertEqual(Format.mmss(60), "1:00")
        XCTAssertEqual(Format.mmss(3599), "59:59")
        XCTAssertEqual(Format.mmss(-5), "0:00")
    }
}
