import CoreGraphics
import XCTest
@testable import ClawTank

/// Records what DisplayService asks of the provider; never touches the real window server.
struct Request: Equatable {
    let width: Int
    let height: Int
    let hiDPI: Bool
}

@MainActor
final class FakeVirtualDisplay: VirtualDisplay {
    let displayID: CGDirectDisplayID
    var sizes: [Request] = []
    var invalidated = false
    var acceptResize = true
    init(id: CGDirectDisplayID) { displayID = id }
    nonisolated func resize(widthPixels: Int, heightPixels: Int, hiDPI: Bool) -> Bool {
        MainActor.assumeIsolated {
            sizes.append(Request(width: widthPixels, height: heightPixels, hiDPI: hiDPI))
            return acceptResize
        }
    }
    nonisolated func invalidate() { MainActor.assumeIsolated { invalidated = true } }
}

@MainActor
final class FakeProvider: VirtualDisplayProvider {
    var isAvailable = true
    var fail = false
    var created: [FakeVirtualDisplay] = []
    var requests: [Request] = []
    func create(widthPixels: Int, heightPixels: Int, hiDPI: Bool) async throws -> VirtualDisplay {
        requests.append(Request(width: widthPixels, height: heightPixels, hiDPI: hiDPI))
        if fail { throw VirtualDisplayError.applyFailed }
        let display = FakeVirtualDisplay(id: CGDirectDisplayID(100 + created.count))
        created.append(display)
        return display
    }
}

@MainActor
final class DisplayServiceTests: XCTestCase {
    private func makeService(physical: [CGDirectDisplayID], provider: FakeProvider) -> DisplayService {
        DisplayService(provider: provider, physicalDisplays: { physical },
                       boundsOf: { CGRect(x: 0, y: 0, width: Double($0), height: 100) })
    }

    func testAutomaticUsesPhysicalWhenAScreenIsAttached() async {
        let provider = FakeProvider()
        let service = makeService(physical: [7], provider: provider)
        let target = await service.prepare(width: 1512, height: 982, scalePercent: nil, mode: .automatic)
        XCTAssertEqual(target?.displayID, 7)
        XCTAssertEqual(target?.isVirtual, false)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testAutomaticCreatesVirtualWhenHeadless() async {
        let provider = FakeProvider()
        let service = makeService(physical: [], provider: provider)
        let target = await service.prepare(width: 3024, height: 1964, scalePercent: 200, mode: .automatic)
        XCTAssertEqual(target?.isVirtual, true)
        XCTAssertEqual(target?.displayID, 100)
        XCTAssertEqual(provider.requests.first, Request(width: 3024, height: 1964, hiDPI: true),
                       "Retina client gets a HiDPI display at its exact pixel size")
    }

    func testResizeReconfiguresInPlaceAndReleaseRemoves() async throws {
        let provider = FakeProvider()
        let service = makeService(physical: [7], provider: provider)
        _ = await service.prepare(width: 1512, height: 982, scalePercent: 100, mode: .virtual)
        let again = await service.prepare(width: 1280, height: 800, scalePercent: 100, mode: .virtual)
        let display = try XCTUnwrap(provider.created.first)
        XCTAssertEqual(provider.created.count, 1, "resized, not recreated")
        XCTAssertEqual(display.sizes, [Request(width: 1280, height: 800, hiDPI: false)])
        XCTAssertEqual(again?.displayID, display.displayID)
        service.release()
        XCTAssertTrue(display.invalidated)
    }

    func testFallsBackToPhysicalWhenVirtualFails() async {
        let provider = FakeProvider()
        provider.fail = true
        let service = makeService(physical: [7], provider: provider)
        let target = await service.prepare(width: 1512, height: 982, scalePercent: nil, mode: .virtual)
        XCTAssertEqual(target?.displayID, 7)
        XCTAssertEqual(target?.isVirtual, false)

        provider.isAvailable = false
        let noApi = await service.prepare(width: 1512, height: 982, scalePercent: nil, mode: .virtual)
        XCTAssertEqual(noApi?.isVirtual, false)
    }

    func testHeadlessWithoutVirtualDisplaysHasNothingToShow() async {
        let provider = FakeProvider()
        provider.isAvailable = false
        let target = await makeService(physical: [], provider: provider)
            .prepare(width: 1512, height: 982, scalePercent: nil, mode: .automatic)
        XCTAssertNil(target)
    }

    func testHiDPIHeuristicAndModes() {
        XCTAssertTrue(DisplayService.wantsHiDPI(width: 1512, height: 982, scalePercent: 200))
        XCTAssertFalse(DisplayService.wantsHiDPI(width: 3024, height: 1964, scalePercent: 100))
        XCTAssertTrue(DisplayService.wantsHiDPI(width: 3024, height: 1964, scalePercent: nil))
        XCTAssertFalse(DisplayService.wantsHiDPI(width: 1512, height: 982, scalePercent: nil))
        let settings = CGVirtualDisplayHandle.settings(widthPixels: 3024, heightPixels: 1964, hiDPI: true)
        XCTAssertEqual(settings.modes.first?.width, 1512, "HiDPI mode is in points")
        XCTAssertEqual(settings.hiDPI, 1)
    }
}

/// Creates a REAL virtual display (it briefly appears as an extra screen). Opt in with
/// CLAWTANK_VD_TESTS=1 (`TEST_RUNNER_CLAWTANK_VD_TESTS=1 make test-app`).
@MainActor
final class RealVirtualDisplayTests: XCTestCase {
    func testCreateResizeRemove() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAWTANK_VD_TESTS"] == "1", "set CLAWTANK_VD_TESTS=1")
        let provider = CGVirtualDisplayProvider()
        try XCTSkipUnless(provider.isAvailable, "CGVirtualDisplay not available on this macOS")
        let display = try await provider.create(widthPixels: 2560, heightPixels: 1600, hiDPI: true)
        let id = display.displayID
        XCTAssertTrue(CGVirtualDisplayProvider.onlineDisplays().contains(id))
        XCTAssertFalse(DisplayService.onlinePhysicalDisplays().contains(id), "ours are not 'physical'")
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(id))
        XCTAssertEqual(mode.pixelWidth, 2560)
        XCTAssertEqual(mode.width, 1280)

        XCTAssertTrue(display.resize(widthPixels: 1920, heightPixels: 1200, hiDPI: false))
        for _ in 0..<40 where CGDisplayCopyDisplayMode(id)?.pixelWidth != 1920 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(CGDisplayCopyDisplayMode(id)?.pixelWidth, 1920)

        display.invalidate()
        for _ in 0..<60 where CGVirtualDisplayProvider.onlineDisplays().contains(id) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(CGVirtualDisplayProvider.onlineDisplays().contains(id), "removed")
    }
}
