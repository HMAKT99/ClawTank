import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ClawTank

/// Records events instead of posting them to the system.
final class RecordingPoster: EventPoster {
    var events: [CGEvent] = []
    var media: [(ScancodeMap.MediaKey, Bool)] = []
    func post(_ event: CGEvent) { events.append(event) }
    func postMediaKey(_ key: ScancodeMap.MediaKey, down: Bool) { media.append((key, down)) }
}

final class ScancodeMapTests: XCTestCase {
    private func map(_ code: UInt8, extended: Bool = false, swap: Bool = false) -> ScancodeMap.Target? {
        ScancodeMap.target(scancode: code, extended: extended, swapControlCommand: swap)
    }

    private func key(_ virtualKey: Int) -> ScancodeMap.Target { .key(CGKeyCode(virtualKey)) }

    func testLettersModifiersAndExtendedKeys() {
        XCTAssertEqual(map(0x1E), key(kVK_ANSI_A))
        XCTAssertEqual(map(0x48, extended: true), key(kVK_UpArrow))
        XCTAssertEqual(map(0x48), key(kVK_ANSI_Keypad8), "keypad 8 without E0")
        XCTAssertEqual(map(0x5B, extended: true), key(kVK_Command))
        XCTAssertEqual(map(0x56), key(kVK_ISO_Section), "ISO <> key")
        XCTAssertEqual(map(0x30, extended: true), .media(.volumeUp))
        XCTAssertNil(map(0x7F))
    }

    func testControlCommandSwap() {
        XCTAssertEqual(map(0x1D, swap: true), key(kVK_Command))
        XCTAssertEqual(map(0x1D, extended: true, swap: true), key(kVK_RightCommand))
        XCTAssertEqual(map(0x5B, extended: true, swap: true), key(kVK_Control))
        XCTAssertEqual(map(0x1E, swap: true), key(kVK_ANSI_A))
    }
}

final class CoordinateMapperTests: XCTestCase {
    func testCornersAndLetterbox() {
        // 1280x800-point display in a 1920x1080 session: scale 1.35 (height-bound), so the content
        // is 1728 px wide with 96 px bars left and right.
        let mapper = CoordinateMapper(sessionWidth: 1920, sessionHeight: 1080,
                                      displayBounds: CGRect(x: 0, y: 0, width: 1280, height: 800))
        XCTAssertEqual(mapper.scale, 1.35, accuracy: 0.0001)
        XCTAssertEqual(mapper.displayPoint(sessionX: 0, sessionY: 0), CGPoint(x: 0, y: 0), "clamped from the bar")
        let centre = mapper.displayPoint(sessionX: 960, sessionY: 540)
        XCTAssertEqual(centre.x, 640, accuracy: 0.1)
        XCTAssertEqual(centre.y, 400, accuracy: 0.1)
        let bottomRight = mapper.displayPoint(sessionX: 1919, sessionY: 1079)
        XCTAssertEqual(bottomRight, CGPoint(x: 1279, y: 799))
    }

    func testMatchesCaptureContentRect() {
        let config = ScreenCapture.Configuration(contentWidth: 1920, contentHeight: 1080, codedWidth: 1920,
                                                 codedHeight: 1088, displaySize: CGSize(width: 1280, height: 800))
        XCTAssertEqual(config.contentRect, CGRect(x: 0, y: 0, width: 1728, height: 1080).offsetBy(dx: 96, dy: 0))
    }
}

final class InputInjectorTests: XCTestCase {
    private func makeInjector(swap: Bool = false) -> (InputInjector, RecordingPoster) {
        let poster = RecordingPoster()
        let mapper = CoordinateMapper(sessionWidth: 1000, sessionHeight: 500,
                                      displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 500))
        return (InputInjector(mapper: mapper, swapControlCommand: swap, poster: poster), poster)
    }

    func testShiftAppliesToFollowingKeysAndRepeatIsFlagged() {
        let (injector, poster) = makeInjector()
        injector.handle(.key(scancode: 0x2A, extended: false, down: true))   // shift
        injector.handle(.key(scancode: 0x1E, extended: false, down: true))   // a
        injector.handle(.key(scancode: 0x1E, extended: false, down: true))   // a (repeat)
        injector.handle(.key(scancode: 0x1E, extended: false, down: false))
        injector.handle(.key(scancode: 0x2A, extended: false, down: false))
        let events = poster.events
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyDown, .keyUp, .flagsChanged])
        XCTAssertTrue(events[1].flags.contains(.maskShift))
        XCTAssertEqual(events[1].getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_A))
        XCTAssertEqual(events[2].getIntegerValueField(.keyboardEventAutorepeat), 1)
        XCTAssertFalse(events[4].flags.contains(.maskShift), "shift released")
    }

    func testSwappedControlBecomesCommand() {
        let (injector, poster) = makeInjector(swap: true)
        injector.handle(.key(scancode: 0x1D, extended: false, down: true))
        injector.handle(.key(scancode: 0x2E, extended: false, down: true))   // c
        XCTAssertTrue(poster.events[1].flags.contains(.maskCommand), "Ctrl+C arrives as ⌘C")
    }

    func testClickDragAndDoubleClick() {
        let (injector, poster) = makeInjector()
        injector.handle(.move(x: 100, y: 50))
        injector.handle(.button(0, down: true))
        injector.handle(.move(x: 110, y: 50))
        injector.handle(.button(0, down: false))
        injector.handle(.button(0, down: true))   // same place, quickly: double click
        injector.handle(.button(0, down: false))
        injector.handle(.move(x: 200, y: 50))
        injector.handle(.button(0, down: true))   // moved away: single click again
        XCTAssertEqual(poster.events.map(\.type),
                       [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .leftMouseDown, .leftMouseUp,
                        .mouseMoved, .leftMouseDown])
        XCTAssertEqual(poster.events[0].location, CGPoint(x: 100, y: 50))
        XCTAssertEqual(poster.events[1].getIntegerValueField(.mouseEventClickState), 1)
        XCTAssertEqual(poster.events[4].getIntegerValueField(.mouseEventClickState), 1,
                       "drag moved 10 px since the first press, beyond the 4 px double-click slop")
        XCTAssertEqual(poster.events[7].getIntegerValueField(.mouseEventClickState), 1)
    }

    func testDoubleClickInPlace() {
        let (injector, poster) = makeInjector()
        injector.handle(.move(x: 100, y: 50))
        for _ in 0..<3 {
            injector.handle(.button(0, down: true))
            injector.handle(.button(0, down: false))
        }
        let downs = poster.events.filter { $0.type == .leftMouseDown }
        let counts = downs.map { $0.getIntegerValueField(.mouseEventClickState) }
        XCTAssertEqual(counts, [1, 2, 3], "single, double, triple")
    }

    func testMiddleAndBackButtonsUseOtherMouseEvents() {
        let (injector, poster) = makeInjector()
        injector.handle(.button(2, down: true))
        injector.handle(.button(3, down: true))
        XCTAssertEqual(poster.events.map(\.type), [.otherMouseDown, .otherMouseDown])
        XCTAssertEqual(poster.events.map { $0.getIntegerValueField(.mouseEventButtonNumber) }, [2, 3])
    }

    func testWheelBecomesContinuousPixelScroll() {
        let (injector, poster) = makeInjector()
        injector.handle(.wheel(vertical: 120, horizontal: 0))
        injector.handle(.wheel(vertical: 0, horizontal: 120))
        injector.handle(.wheel(vertical: 1, horizontal: 0))   // below one pixel: accumulates
        XCTAssertEqual(poster.events.count, 2)
        XCTAssertEqual(poster.events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 40)
        XCTAssertEqual(poster.events[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -40, "tilt right")
        XCTAssertEqual(poster.events[0].getIntegerValueField(.scrollWheelEventIsContinuous), 1)
    }

    func testReleaseAllLiftsHeldKeysAndButtons() {
        let (injector, poster) = makeInjector()
        injector.handle(.key(scancode: 0x1D, extended: false, down: true))
        injector.handle(.key(scancode: 0x1E, extended: false, down: true))
        injector.handle(.button(1, down: true))
        poster.events.removeAll()
        injector.releaseAll()
        XCTAssertEqual(Set(poster.events.map(\.type)), [.rightMouseUp, .keyUp, .flagsChanged])
        XCTAssertEqual(injector.currentFlags, [])
    }

    func testMediaKeysAndUnicodeSurrogates() {
        let (injector, poster) = makeInjector()
        injector.handle(.key(scancode: 0x20, extended: true, down: true))
        XCTAssertEqual(poster.media.first?.0, .mute)
        injector.handle(.unicode(0xD83D, down: true))   // 😀 = D83D DE00
        injector.handle(.unicode(0xDE00, down: true))
        XCTAssertEqual(poster.events.count, 1, "high surrogate waits for its pair")
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        poster.events[0].keyboardGetUnicodeString(
            maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        XCTAssertEqual(Array(chars.prefix(length)), [0xD83D, 0xDE00])
    }
}

final class CursorPublisherTests: XCTestCase {
    func testArrowRendersBottomUpWithinLimits() throws {
        let cursor = NSCursor.arrow
        let shape = try XCTUnwrap(CursorPublisher.render(cursor.image, hotSpot: cursor.hotSpot, scale: 1))
        XCTAssertLessThanOrEqual(max(shape.width, shape.height), CursorPublisher.maxSide)
        XCTAssertEqual(shape.bgra.count, shape.width * shape.height * 4)
        XCTAssertLessThan(shape.hotX, shape.width)
        XCTAssertLessThan(shape.hotY, shape.height)
        XCTAssertTrue(shape.bgra.enumerated().contains { $0.offset % 4 == 3 && $0.element == 255 }, "has opaque pixels")
    }

    func testLargeScaleIsCappedAndHotspotScales() throws {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        let shape = try XCTUnwrap(CursorPublisher.render(image, hotSpot: NSPoint(x: 32, y: 32), scale: 2))
        XCTAssertEqual(shape.width, 32)
        XCTAssertEqual(shape.hotX, 16)
    }
}
