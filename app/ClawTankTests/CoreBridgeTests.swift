import XCTest
import ClawTankCore
import Foundation
@testable import ClawTank

final class CoreBridgeTests: XCTestCase {
    func testVersionIsSemver() {
        let parts = CoreBridge.shared.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "unexpected version: \(CoreBridge.shared.version)")
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }

    func testInitIsIdempotent() {
        XCTAssertEqual(CoreBridge.shared.reinitialize(), CT_STATUS_ALREADY_INITIALIZED)
    }
}
