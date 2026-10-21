import XCTest
@testable import ClawTank

final class AdaptiveBitrateTests: XCTestCase {
    private func sample(skipped: Int = 0, inFlight: Int = 1, latency: Double = 10, sent: Int = 60)
        -> AdaptiveBitrate.Sample {
        .init(skippedFrames: skipped, framesInFlight: inFlight, ackLatencyMs: latency, framesSent: sent)
    }

    func testBacksOffOnCongestionAndRecoversSlowly() {
        var rate = AdaptiveBitrate(target: 20_000_000)
        XCTAssertNil(rate.update(sample()), "healthy at target: no change")
        XCTAssertEqual(rate.update(sample(skipped: 10)), 14_000_000, "×0.7 on skipped frames")
        XCTAssertEqual(rate.update(sample(inFlight: 12)), 9_800_000, "×0.7 on a deep ack backlog")
        XCTAssertNil(rate.update(sample()))
        XCTAssertNil(rate.update(sample()))
        XCTAssertEqual(rate.update(sample()), 11_270_000, "×1.15 after 3 healthy seconds")
    }

    func testLatencyIsJudgedAgainstTheBestSeen() {
        var rate = AdaptiveBitrate(target: 10_000_000)
        _ = rate.update(sample(latency: 40))          // steady 40 ms link: fine
        XCTAssertNil(rate.update(sample(latency: 60)), "under 3× best and under 80 ms floor")
        XCTAssertNotNil(rate.update(sample(latency: 200)), "5× best: congested")
        XCTAssertTrue(rate.congested)
    }

    func testFloorAndCeiling() {
        var rate = AdaptiveBitrate(target: 12_000_000)
        for _ in 0..<20 { _ = rate.update(sample(skipped: 10)) }
        XCTAssertEqual(rate.current, 2_000_000, "never below target/6")
        for _ in 0..<60 { _ = rate.update(sample()) }
        XCTAssertEqual(rate.current, 12_000_000, "recovers to, not past, the target")
        XCTAssertNil(rate.update(sample(sent: 0)), "idle seconds don't count as healthy or congested")
    }
}
