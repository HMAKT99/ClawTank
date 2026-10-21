// Adapts the encoder bit rate to the network, once per second, from signals the core measures:
// frames skipped for backpressure, frames sent but not yet acknowledged, and the smoothed
// send→ack time (EGFX frame acknowledgements, which include the client's decode time).
//
// Policy: back off quickly (×0.7) on congestion, recover slowly (×1.15 after 3 healthy
// seconds), never below a floor or above the preset's target. Latency is judged relative to the
// best latency seen this session, so a slow-but-steady link isn't mistaken for congestion.

import Foundation

struct AdaptiveBitrate: Equatable {
    struct Sample: Equatable {
        var skippedFrames: Int
        var framesInFlight: Int
        var ackLatencyMs: Double
        var framesSent: Int
    }

    let target: Int
    let floor: Int
    private(set) var current: Int
    private var healthySeconds = 0
    private var bestLatencyMs = Double.infinity

    init(target: Int) {
        self.target = target
        self.floor = max(1_000_000, target / 6)
        self.current = target
    }

    /// True when the last sample showed congestion (for the stats readout).
    private(set) var congested = false

    /// Feeds one second of measurements; returns the new bit rate if it changed.
    mutating func update(_ sample: Sample) -> Int? {
        if sample.ackLatencyMs > 0 { bestLatencyMs = min(bestLatencyMs, sample.ackLatencyMs) }
        let latencyLimit = max(80, (bestLatencyMs.isFinite ? bestLatencyMs : 0) * 3)
        congested = sample.skippedFrames > 2 || sample.framesInFlight > 6
            || (sample.ackLatencyMs > 0 && sample.ackLatencyMs > latencyLimit)
        let previous = current
        if congested {
            healthySeconds = 0
            current = max(floor, Int(Double(current) * 0.7))
        } else if sample.framesSent > 0 {
            healthySeconds += 1
            if healthySeconds >= 3, current < target {
                current = min(target, Int(Double(current) * 1.15))
                healthySeconds = 0
            }
        }
        return current == previous ? nil : current
    }
}
