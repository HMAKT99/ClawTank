// Keeps the Mac (and its display) awake while a client is connected, so a session doesn't freeze
// when the host's idle timer fires. Released when the session ends.

import Foundation
import IOKit.pwr_mgt

protocol PowerManaging: AnyObject {
    func begin(reason: String) -> Bool
    func end()
    var isActive: Bool { get }
}

final class PowerAssertions: PowerManaging {
    private var assertions: [IOPMAssertionID] = []

    var isActive: Bool { !assertions.isEmpty }

    func begin(reason: String) -> Bool {
        guard assertions.isEmpty else { return true }
        for type in [kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertPreventUserIdleDisplaySleep] {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           reason as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        return isActive
    }

    func end() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
    }

    deinit { end() }
}
