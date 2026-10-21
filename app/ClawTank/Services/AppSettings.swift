// User settings, persisted in UserDefaults. One place for every tunable so the Settings window,
// the menu and the server all agree. Network settings (port, LAN-only, allowlist) take effect by
// restarting the server; the rest apply at the next session or immediately where noted.

import Combine
import Foundation

enum QualityPreset: String, CaseIterable, Identifiable, Sendable {
    case balanced, sharpText, lowBandwidth
    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .sharpText: "Sharp text (more bandwidth)"
        case .lowBandwidth: "Low bandwidth"
        }
    }

    /// Multiplier on the encoder's default bit rate.
    var bitRateFactor: Double {
        switch self {
        case .balanced: 1.0
        case .sharpText: 1.6
        case .lowBandwidth: 0.35
        }
    }

    /// Upper bound on frame rate regardless of the max-fps setting.
    var frameRateCap: Int {
        self == .lowBandwidth ? 30 : 60
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var displayMode: DisplayMode { didSet { save(displayMode.rawValue, "displayMode") } }
    @Published var maxFrameRate: Int { didSet { save(maxFrameRate, "maxFrameRate") } }
    @Published var quality: QualityPreset { didSet { save(quality.rawValue, "quality") } }
    @Published var swapControlCommand: Bool { didSet { save(swapControlCommand, "swapControlCommand") } }
    @Published var showsStatsOverlay: Bool { didSet { save(showsStatsOverlay, "showsStatsOverlay") } }
    @Published var keepAwake: Bool { didSet { save(keepAwake, "keepAwake") } }
    @Published var port: Int { didSet { save(port, "port") } }
    @Published var lanOnly: Bool { didSet { save(lanOnly, "lanOnly") } }
    /// Comma-separated IPs/CIDRs; empty = anyone allowed by LAN-only.
    @Published var allowlist: String { didSet { save(allowlist, "allowlist") } }
    @Published var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "onboarded") } }
    /// Send the Mac's sound to the client (applies from the next connection).
    @Published var audioEnabled: Bool { didSet { save(audioEnabled, "audioEnabled") } }
    /// Mute the Mac's own speakers while a client is connected.
    @Published var muteLocalAudio: Bool { didSet { save(muteLocalAudio, "muteLocalAudio") } }
    /// Share the clipboard both ways (applies from the next connection).
    @Published var clipboardEnabled: Bool { didSet { save(clipboardEnabled, "clipboardEnabled") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .automatic
        let savedFrameRate = defaults.integer(forKey: "maxFrameRate")
        maxFrameRate = [30, 60].contains(savedFrameRate) ? savedFrameRate : 60
        quality = QualityPreset(rawValue: defaults.string(forKey: "quality") ?? "") ?? .balanced
        swapControlCommand = defaults.bool(forKey: "swapControlCommand")
        showsStatsOverlay = defaults.bool(forKey: "showsStatsOverlay")
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
        let savedPort = defaults.integer(forKey: "port")
        port = (1...65535).contains(savedPort) ? savedPort : 3389
        lanOnly = defaults.object(forKey: "lanOnly") as? Bool ?? true
        allowlist = defaults.string(forKey: "allowlist") ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: "onboarded")
        audioEnabled = defaults.object(forKey: "audioEnabled") as? Bool ?? true
        muteLocalAudio = defaults.bool(forKey: "muteLocalAudio")
        clipboardEnabled = defaults.object(forKey: "clipboardEnabled") as? Bool ?? true
    }

    /// Effective frame rate for capture/encode.
    var frameRate: Int { min(maxFrameRate, quality.frameRateCap) }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// Settings for the diagnostics bundle (no secrets are stored here, but keep it explicit).
    var diagnosticsSummary: [String: String] {
        [
            "displayMode": displayMode.rawValue, "maxFrameRate": "\(maxFrameRate)", "quality": quality.rawValue,
            "swapControlCommand": "\(swapControlCommand)", "showsStatsOverlay": "\(showsStatsOverlay)",
            "keepAwake": "\(keepAwake)", "port": "\(port)", "lanOnly": "\(lanOnly)",
            "allowlist": allowlist.isEmpty ? "(none)" : allowlist,
            "audioEnabled": "\(audioEnabled)", "muteLocalAudio": "\(muteLocalAudio)",
            "clipboardEnabled": "\(clipboardEnabled)"
        ]
    }
}
