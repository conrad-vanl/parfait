import AppKit
import CoreAudio
import Foundation
import os

struct MicEvent: Sendable {
    let pid: pid_t
    let bundleID: String?
    let appName: String?
    let isRunningInput: Bool
}

/// Watches Core Audio process objects for another app opening the microphone —
/// the "a meeting just started" signal. Observation needs no permissions.
/// All mutable state is confined to `queue`.
final class MeetingDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.conrad-vanl.Parfait.detector")
    private var onEvent: (@Sendable (MicEvent) -> Void)?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var lastState: [AudioObjectID: (pid: pid_t, running: Bool)] = [:]
    private var systemListener: AudioObjectPropertyListenerBlock?
    private let ownPID = getpid()
    private let log = Logger(subsystem: "io.github.conrad-vanl.Parfait", category: "detector")

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    func start(onEvent: @escaping @Sendable (MicEvent) -> Void) {
        queue.async {
            guard self.systemListener == nil else { return }
            self.log.info("detector starting")
            self.onEvent = onEvent
            var listAddr = Self.address(kAudioHardwarePropertyProcessObjectList)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.syncProcessList()
            }
            self.systemListener = block
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listAddr, self.queue, block)
            self.syncProcessList()
        }
    }

    func stop() {
        queue.async {
            var listAddr = Self.address(kAudioHardwarePropertyProcessObjectList)
            if let block = self.systemListener {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &listAddr, self.queue, block)
                self.systemListener = nil
            }
            var runAddr = Self.address(kAudioProcessPropertyIsRunningInput)
            for (object, block) in self.processListeners {
                AudioObjectRemovePropertyListenerBlock(object, &runAddr, self.queue, block)
            }
            self.processListeners.removeAll()
            self.lastState.removeAll()
            self.onEvent = nil
        }
    }

    // MARK: - Classification

    /// Prefix-matched Apple daemons whose mic use is never a meeting.
    private static let daemonPrefixes = [
        "com.apple.siri",
        "com.apple.Siri",
        "com.apple.assistant",
        "com.apple.corespeech",
        "com.apple.SpeechRecognitionCore",
        "com.apple.dictation",
        "com.apple.controlcenter",
        "com.apple.VoiceMemos",
    ]

    static func isIgnored(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if bundleID == Bundle.main.bundleIdentifier { return true }
        if AppSettings.ignoredBundleIDs.contains(bundleID) { return true }
        return daemonPrefixes.contains { bundleID.hasPrefix($0) }
    }

    private static let helperNames: [(prefix: String, name: String)] = [
        ("com.apple.WebKit", "Safari"),
        ("com.google.Chrome", "Chrome"),
        ("org.mozilla", "Firefox"),
        ("com.microsoft.edgemac", "Edge"),
        ("us.zoom", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
    ]

    static func displayName(for event: MicEvent) -> String {
        if let bundleID = event.bundleID,
           let match = helperNames.first(where: { bundleID.hasPrefix($0.prefix) }) {
            return match.name
        }
        if let name = event.appName { return name }
        if let bundleID = event.bundleID { return bundleID }
        return "PID \(event.pid)"
    }

    // MARK: - Internals (all on `queue`)

    private func syncProcessList() {
        let current = Set(processObjectList())
        let known = Set(processListeners.keys)
        var runAddr = Self.address(kAudioProcessPropertyIsRunningInput)

        for gone in known.subtracting(current) {
            if let block = processListeners.removeValue(forKey: gone) {
                // Removal errs harmlessly when the object died with its process.
                AudioObjectRemovePropertyListenerBlock(gone, &runAddr, queue, block)
            }
            // No final IsRunningInput=0 fires for a dead process — synthesize it.
            if let state = lastState.removeValue(forKey: gone), state.running {
                emit(object: nil, pid: state.pid, running: false)
            }
        }

        for added in current.subtracting(known) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.evaluate(added)
            }
            if AudioObjectAddPropertyListenerBlock(added, &runAddr, queue, block) == noErr {
                processListeners[added] = block
            }
            evaluate(added)
        }
    }

    private func evaluate(_ object: AudioObjectID) {
        guard let pid: pid_t = readScalar(object, kAudioProcessPropertyPID),
              pid != ownPID else { return }
        let running = (readScalar(object, kAudioProcessPropertyIsRunningInput) as UInt32?) == 1
        let previous = lastState[object]?.running
        lastState[object] = (pid, running)
        // Transitions only; `?? false` keeps first sight of the (mostly idle)
        // client list from flooding stop events at startup.
        guard running != (previous ?? false) else { return }
        emit(object: object, pid: pid, running: running)
    }

    private func emit(object: AudioObjectID?, pid: pid_t, running: Bool) {
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = object.flatMap(readBundleID) ?? app?.bundleIdentifier
        log.debug("emit pid=\(pid) bundleID=\(bundleID ?? "nil", privacy: .public) running=\(running)")
        onEvent?(MicEvent(
            pid: pid,
            bundleID: bundleID,
            appName: app?.localizedName,
            isRunningInput: running))
    }

    private func processObjectList() -> [AudioObjectID] {
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private func readScalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private func readBundleID(_ object: AudioObjectID) -> String? {
        var addr = Self.address(kAudioProcessPropertyBundleID)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr else { return nil }
        let string = ref?.takeRetainedValue() as String?
        return (string?.isEmpty == true) ? nil : string // HAL returns "" for unbundled processes
    }
}
