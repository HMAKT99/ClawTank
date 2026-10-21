// "Mute this Mac while connected": mutes the default output device for the session and restores
// the previous state afterwards. ScreenCaptureKit captures app audio before the device, so the
// remote client still hears everything.

import CoreAudio
import Foundation

final class LocalMute {
    private var mutedDevice: AudioDeviceID?
    private var previous: UInt32 = 0

    func mute() {
        guard mutedDevice == nil, let device = Self.defaultOutput(),
              let current = Self.muteState(device) else { return }
        previous = current
        if Self.setMute(device, 1) { mutedDevice = device }
    }

    func restore() {
        guard let device = mutedDevice else { return }
        _ = Self.setMute(device, previous)
        mutedDevice = nil
    }

    deinit { restore() }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func muteState(_ device: AudioDeviceID) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setMute(_ device: AudioDeviceID, _ value: UInt32) -> Bool {
        var value = value
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
