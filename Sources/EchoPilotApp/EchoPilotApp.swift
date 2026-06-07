import SwiftUI
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreMediaIO
import AppKit
import ApplicationServices
import AudioToolbox
import Foundation
import IOKit
import UserNotifications

struct TrackStats: Equatable {
    var buffers: Int = 0
    var writtenBuffers: Int = 0
    var samples: Int64 = 0
    var duration: Double? = nil
    var failed: Bool = false
    var level: Float = 0

    var hasWrittenAudio: Bool { writtenBuffers > 0 && samples > 0 }
}

enum AudioLevelMeter {
    static func level(from sampleBuffer: CMSampleBuffer) -> Float {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return 0 }

        var neededSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard status == noErr, neededSize > 0 else { return 0 }

        var storage = [UInt8](repeating: 0, count: neededSize)
        var sumSquares: Double = 0
        var sampleCounter = 0

        status = storage.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return OSStatus(-1) }
            let audioBufferList = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
            var localBlockBuffer: CMBlockBuffer?
            let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList,
                bufferListSize: neededSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &localBlockBuffer
            )
            guard result == noErr else { return result }

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let flags = streamDescription.mFormatFlags
            let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
            let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
            let bytesPerSample = max(1, Int(streamDescription.mBitsPerChannel / 8))

            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let byteCount = Int(buffer.mDataByteSize)
                if isFloat && bytesPerSample == MemoryLayout<Float>.size {
                    let count = byteCount / MemoryLayout<Float>.size
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for index in 0..<count {
                        let value = max(-1, min(1, Double(samples[index])))
                        sumSquares += value * value
                    }
                    sampleCounter += count
                } else if isSignedInteger && bytesPerSample == MemoryLayout<Int16>.size {
                    let count = byteCount / MemoryLayout<Int16>.size
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    for index in 0..<count {
                        let value = Double(samples[index]) / Double(Int16.max)
                        sumSquares += value * value
                    }
                    sampleCounter += count
                }
            }
            return result
        }

        guard status == noErr, sampleCounter > 0 else { return 0 }
        let rms = max(0.000001, sqrt(sumSquares / Double(sampleCounter)))
        let db = 20.0 * log10(rms)
        // Map roughly -55 dBFS...0 dBFS to 0...1. Normal speech should sit green/yellow;
        // red is reserved for very loud / near-clipping input.
        let normalized = (db + 55.0) / 55.0
        return Float(max(0.0, min(1.0, normalized)))
    }

    static func smooth(previous: Float, measured: Float) -> Float {
        if measured > previous {
            return previous * 0.15 + measured * 0.85
        }
        return previous * 0.52 + measured * 0.48
    }
}

struct RecordingSession: Equatable {
    let outputDir: URL
    let systemURL: URL
    let micURL: URL
    let manifestURL: URL
    let startedAt: Date
}

final class SystemAudioFileRecorder: NSObject, SCStreamOutput {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var didStartSession = false
    private var didSeeAppendFailure = false

    private var buffers = 0
    private var appendedBuffers = 0
    private var samples: Int64 = 0
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var level: Float = 0

    init(outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RuntimeError("AVAssetWriter cannot add system audio input for \(outputURL.path)")
        }
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        lock.lock()
        buffers += 1
        samples += Int64(CMSampleBufferGetNumSamples(sampleBuffer))
        level = AudioLevelMeter.smooth(previous: level, measured: AudioLevelMeter.level(from: sampleBuffer))
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil { firstPTS = pts }
        lastPTS = pts

        if !didStartSession {
            guard writer.startWriting() else {
                didSeeAppendFailure = true
                let err = writer.error?.localizedDescription ?? "unknown writer error"
                lock.unlock()
                fputs("Failed to start system AVAssetWriter: \(err)\n", stderr)
                return
            }
            writer.startSession(atSourceTime: pts)
            didStartSession = true
        }

        guard input.isReadyForMoreMediaData else {
            lock.unlock()
            return
        }
        if input.append(sampleBuffer) {
            appendedBuffers += 1
        } else {
            didSeeAppendFailure = true
            let err = writer.error?.localizedDescription ?? "unknown append error"
            lock.unlock()
            fputs("Failed to append system audio sample buffer: \(err)\n", stderr)
            return
        }
        lock.unlock()
    }

    func snapshot() -> TrackStats {
        lock.lock()
        defer { lock.unlock() }
        let duration: Double?
        if let firstPTS, let lastPTS { duration = CMTimeGetSeconds(lastPTS - firstPTS) } else { duration = nil }
        return TrackStats(buffers: buffers, writtenBuffers: appendedBuffers, samples: samples, duration: duration, failed: didSeeAppendFailure, level: level)
    }

    func finish() async throws {
        lock.lock()
        let didStart = didStartSession
        lock.unlock()
        guard didStart else { return }
        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = self.writer.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String

    static func available() -> [AudioInputDevice] {
        AVCaptureDevice.devices(for: .audio)
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct WhisperModelInfo: Identifiable, Equatable {
    let id: String
    let installed: Bool

    var label: String {
        label(language: AppSettings.currentLanguage)
    }

    func label(language: AppLanguage) -> String {
        let hint: String
        switch id {
        case "turbo": hint = L10n.text("modelHint.turbo", language: language)
        case "small": hint = L10n.text("modelHint.small", language: language)
        case "large-v3": hint = L10n.text("modelHint.large", language: language)
        default: hint = ""
        }
        let suffix = hint.isEmpty ? "" : " · \(hint)"
        let state = installed ? L10n.text("modelState.installed", language: language) : L10n.text("modelState.download", language: language)
        return "\(id) · \(state)\(suffix)"
    }

    static let knownModelIDs = ["turbo", "small", "medium", "large-v3", "tiny", "base", "large", "large-v2"]

    static func available() -> [WhisperModelInfo] {
        let installed = installedModelIDs()
        return knownModelIDs.map { WhisperModelInfo(id: $0, installed: installed.contains($0)) }
    }

    static func installedModelIDs() -> Set<String> {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) else {
            return []
        }
        return Set(files.compactMap { url in
            guard url.pathExtension == "pt" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        })
    }
}

struct MeetingSuggestion: Equatable {
    let appName: String
    let detail: String
    var title: String? = nil
    var participants: [String] = []
}

struct MeetingDeviceStatus: Equatable {
    var inMeeting: Bool = false
    var micActive: Bool = false
    var cameraActive: Bool = false
    var activeMics: [String] = []

    func summary(language: AppLanguage = AppSettings.currentLanguage) -> String {
        if inMeeting {
            var parts: [String] = []
            if micActive { parts.append(L10n.text("meetingDetection.micActive", language: language)) }
            if cameraActive { parts.append(L10n.text("meetingDetection.cameraActive", language: language)) }
            if !activeMics.isEmpty { parts.append(activeMics.joined(separator: ", ")) }
            return parts.isEmpty ? L10n.text("meetingDetection.inMeeting", language: language) : parts.joined(separator: " · ")
        }
        return L10n.text("meetingDetection.notInMeeting", language: language)
    }
}

enum TranscriptPreviewKind: String, CaseIterable, Identifiable, Hashable {
    case combinedTimeline
    case combinedHandover
    case timeline
    case kiHandover
    case system
    case microphone

    var id: String { rawValue }

    var title: String {
        title(language: AppSettings.currentLanguage)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .combinedTimeline: return L10n.text("preview.combinedTimeline", language: language)
        case .combinedHandover: return L10n.text("preview.combinedHandover", language: language)
        case .timeline: return L10n.text("preview.timeline", language: language)
        case .kiHandover: return L10n.text("preview.kiHandover", language: language)
        case .system: return L10n.text("preview.system", language: language)
        case .microphone: return L10n.text("preview.microphone", language: language)
        }
    }

    var relativePath: String {
        switch self {
        case .combinedTimeline: return "transcription-input/combined-timeline.md"
        case .combinedHandover: return "transcription-input/combined-meeting-notes-input.md"
        case .timeline: return "transcription-input/timeline.md"
        case .kiHandover: return "transcription-input/meeting-notes-input.md"
        case .system: return "transcription-input/system.txt"
        case .microphone: return "transcription-input/mic.txt"
        }
    }
}

enum EchoPilotNotifications {
    static let recordingStateChanged = Notification.Name("EchoPilotRecordingStateChanged")
    static let startRecordingRequested = Notification.Name("EchoPilotStartRecordingRequested")
    static let stopRecordingRequested = Notification.Name("EchoPilotStopRecordingRequested")
    static let checkUpdatesRequested = Notification.Name("EchoPilotCheckUpdatesRequested")
    static let checkPermissionsRequested = Notification.Name("EchoPilotCheckPermissionsRequested")
    static let languageChanged = Notification.Name("EchoPilotLanguageChanged")
}

enum EchoPilotRecordingState {
    static var isRecording = false
}

enum MeetingCallDetector {
    static func deviceStatus() -> MeetingDeviceStatus {
        let activeMics = activeMicrophoneNames()
        let cameraActive = isCameraRunningSomewhere()
        return MeetingDeviceStatus(
            inMeeting: !activeMics.isEmpty || cameraActive,
            micActive: !activeMics.isEmpty,
            cameraActive: cameraActive,
            activeMics: activeMics
        )
    }

    static func detectMeetingContext() async -> MeetingSuggestion? {
        if let teamsAXSuggestion = await detectTeamsCallFromAccessibility() {
            return teamsAXSuggestion
        }
        if let teamsLogSuggestion = detectTeamsCallFromLogs() {
            return teamsLogSuggestion
        }
        // Window-title detection uses ScreenCaptureKit and must not trigger the
        // macOS Screen Recording permission prompt during idle app startup.
        // Only run it after the user has already granted permission.
        guard CGPreflightScreenCaptureAccess() else { return nil }

        let dedicatedMeetingAppFragments = ["teams", "zoom", "webex", "msteams"]
        let browserAppFragments = ["chrome", "safari", "edge", "firefox", "arc", "brave", "opera"]
        let meetingClientTitleFragments = [
            "meeting", "call", "besprechung", "anruf", "zoom meeting", "google meet",
            "waiting room", "lobby", "meeting room", "meet now", "beitreten",
            "teilnehmen", "warteraum", "in a meeting", "in meeting"
        ]
        let browserMeetingTitleFragments = [
            "meet.google.com", "google meet",
            "teams.microsoft.com", "microsoft teams meeting",
            "zoom.us/j/", "zoom meeting",
            "webex.com", "webex meeting",
            "whereby.com", "around.co"
        ]

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            for window in content.windows {
                let appName = window.owningApplication?.applicationName ?? ""
                let bundleID = window.owningApplication?.bundleIdentifier ?? ""
                let title = window.title ?? ""
                let appHaystack = "\(appName) \(bundleID)".lowercased()
                let titleHaystack = title.lowercased()
                let appLooksLikeMeetingClient = dedicatedMeetingAppFragments.contains { appHaystack.contains($0) }
                let appLooksLikeBrowser = browserAppFragments.contains { appHaystack.contains($0) }
                let meetingClientTitleLooksLikeCall = meetingClientTitleFragments.contains { titleHaystack.contains($0) }
                let browserTitleLooksLikeMeetingService = browserMeetingTitleFragments.contains { titleHaystack.contains($0) }
                guard (appLooksLikeMeetingClient && meetingClientTitleLooksLikeCall) || (appLooksLikeBrowser && browserTitleLooksLikeMeetingService) else { continue }
                let detail = title.isEmpty ? appName : "\(appName): \(title)"
                return MeetingSuggestion(appName: appName.isEmpty ? "Meeting-App" : appName, detail: detail)
            }
        } catch {
            // ScreenCaptureKit may need permission. Window-title detection is best-effort.
        }

        return nil
    }

    private static func detectTeamsCallFromAccessibility() async -> MeetingSuggestion? {
        await Task.detached(priority: .utility) {
            detectTeamsCallFromAccessibilitySync()
        }.value
    }

    private static func detectTeamsCallFromAccessibilitySync() -> MeetingSuggestion? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var meetingWindow: AXUIElement?
        for _ in 0..<8 {
            if let window = teamsMeetingWindow(in: axApp) {
                meetingWindow = window
                break
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        guard let meetingWindow else { return nil }

        let title = teamsMeetingTitle(from: meetingWindow)
        let participantNames = teamsParticipantNames(in: meetingWindow)
        let detail: String
        if let title, !title.isEmpty {
            detail = title
        } else if !participantNames.isEmpty {
            detail = participantNames.joined(separator: ", ")
        } else {
            detail = "Microsoft Teams"
        }
        return MeetingSuggestion(appName: "Microsoft Teams", detail: detail, title: title, participants: participantNames)
    }

    private static func teamsMeetingWindow(in app: AXUIElement) -> AXUIElement? {
        guard let windows = axAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement] else { return nil }
        let meetingMarkers = ["Besprechungssteuerung", "Verstrichene Zeit", "Meeting controls", "Elapsed time"]
        for window in windows where axTreeContainsText(window, markers: meetingMarkers, maxDepth: 34) {
            return window
        }
        return nil
    }

    private static func teamsMeetingTitle(from window: AXUIElement) -> String? {
        let rawTitle = axString(window, kAXTitleAttribute as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return nil }
        let viewLabels = ["Kompakte Besprechungsansicht", "Compact meeting view", "Besprechungsansicht", "Meeting view"]
        let segments = rawTitle.components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return segments.first { !viewLabels.contains($0) } ?? segments.first ?? rawTitle
    }

    private static func teamsParticipantNames(in window: AXUIElement) -> [String] {
        let leadingPrefixes = [
            "Video von mir selbst, ", "Video von ", "Video ist aus, ", "Video ist ein, ",
            "Video from me, ", "Video from ", "Video is off, ", "Video is on, "
        ]
        let trailingSeparators = [
            ", Video ist", ", Stummschaltung", ", Kontextmenü", ", Hat Kontextmenü", ", Frame", ", spricht", ", Bildschirm",
            ", video is", ", muted", ", unmuted", ", context menu", ", has context menu", ", speaking", ", screen", ", your video"
        ]
        let nameMarkers = ["Video von", "Video ist ein", "Video ist aus", "Video from", "video is on", "video is off"]
        var names: [String] = []

        func addName(from raw: String) {
            var name = raw
            for prefix in leadingPrefixes where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                break
            }
            for separator in trailingSeparators {
                if let range = name.range(of: separator) {
                    name = String(name[..<range.lowerBound])
                    break
                }
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            guard !name.isEmpty, !names.contains(name) else { return }
            names.append(name)
        }

        func scan(_ element: AXUIElement, depth: Int) {
            guard depth <= 40 else { return }
            let role = axString(element, kAXRoleAttribute as String)
            if role == "AXImage" || role == "AXMenuItem" {
                let description = axString(element, kAXDescriptionAttribute as String)
                let title = axString(element, kAXTitleAttribute as String)
                let text = description.isEmpty ? title : description
                if nameMarkers.contains(where: { text.contains($0) }) {
                    addName(from: text)
                }
            }
            if let children = axAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
                for child in children { scan(child, depth: depth + 1) }
            }
        }

        scan(window, depth: 0)
        return names
    }

    private static func axTreeContainsText(_ element: AXUIElement, markers: [String], maxDepth: Int, depth: Int = 0) -> Bool {
        guard depth <= maxDepth else { return false }
        let text = axString(element, kAXTitleAttribute as String) + " ¦ " + axString(element, kAXDescriptionAttribute as String)
        if markers.contains(where: { text.contains($0) }) { return true }
        guard let children = axAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return false }
        return children.contains { axTreeContainsText($0, markers: markers, maxDepth: maxDepth, depth: depth + 1) }
    }

    private static func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String {
        axAttribute(element, attribute) as? String ?? ""
    }

    private static func activeMicrophoneNames() -> [String] {
        audioInputDevices().compactMap { deviceID in
            isAudioDeviceRunningSomewhere(deviceID) ? audioDeviceName(deviceID) : nil
        }
    }

    private static func audioInputDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.filter { audioDeviceHasInput($0) }
    }

    private static func audioDeviceHasInput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }
        return buffer.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers > 0
    }

    private static func isAudioDeviceRunningSomewhere(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static func audioDeviceName(_ id: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? name as String : L10n.text("meetingDetection.unknownMic")
    }

    private static func isCameraRunningSomewhere() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, &devices) == noErr else {
            return false
        }
        return devices.contains { deviceID in
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard CMIOObjectGetPropertyData(deviceID, &runningAddress, 0, nil, runningSize, &runningSize, &running) == noErr else { return false }
            return running != 0
        }
    }

    private static func detectTeamsCallFromLogs() -> MeetingSuggestion? {
        guard let logURL = newestTeamsLogFile() else { return nil }
        guard let values = try? logURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate,
              Date().timeIntervalSince(modifiedAt) < 30 * 60
        else { return nil }

        guard let tail = readTail(url: logURL, maxBytes: 512 * 1024) else { return nil }
        let markers: [(String, Bool, String)] = [
            ("eventData: s::;m::1;a::0", true, "Teams-Call aktiv, Screen Sharing erkannt"),
            ("eventData: s::;m::1;a::1", true, "Teams-Call gestartet/beigetreten"),
            ("eventData: s::;m::1;a::3", false, "Teams-Call verlassen")
        ]

        var lastMatch: (range: Range<String.Index>, active: Bool, detail: String)?
        for marker in markers {
            if let range = tail.range(of: marker.0, options: [.backwards]) {
                if lastMatch == nil || range.lowerBound > lastMatch!.range.lowerBound {
                    lastMatch = (range, marker.1, marker.2)
                }
            }
        }

        guard let lastMatch, lastMatch.active else { return nil }
        return MeetingSuggestion(
            appName: "Microsoft Teams",
            detail: "\(lastMatch.detail) · erkannt aus lokalem Teams-Log"
        )
    }

    private static func newestTeamsLogFile() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Microsoft/Teams/logs.txt"),
            home.appendingPathComponent("Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/logs.txt"),
            home.appendingPathComponent("Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/logs"),
            home.appendingPathComponent("Library/Application Support/Microsoft/MSTeams/logs"),
            home.appendingPathComponent("Library/Application Support/Microsoft/Teams/logs")
        ]

        var files: [URL] = []
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: candidate, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                while let file = enumerator?.nextObject() as? URL {
                    let ext = file.pathExtension.lowercased()
                    let name = file.lastPathComponent.lowercased()
                    if ext == "log" || ext == "txt" || name.contains("log") {
                        files.append(file)
                    }
                }
            } else {
                files.append(candidate)
            }
        }

        return files.max { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return leftDate < rightDate
        }
    }

    private static func readTail(url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
    }
}

enum AppPermissions {
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isMicrophoneGranted: Bool {
        microphoneStatus == .authorized
    }

    static var microphoneStatusText: String {
        switch microphoneStatus {
        case .authorized: return L10n.text("permissionStatus.granted")
        case .notDetermined: return L10n.text("permissionStatus.notRequested")
        case .denied: return L10n.text("permissionStatus.denied")
        case .restricted: return L10n.text("permissionStatus.restricted")
        @unknown default: return L10n.text("permissionStatus.unknown")
        }
    }

    @MainActor
    static func requestMicrophone() -> Bool {
        MicrophoneFileRecorder.requestPermissionSync()
    }

    static var isScreenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var screenCaptureStatusText: String {
        isScreenCaptureGranted ? L10n.text("permissionStatus.granted") : L10n.text("permissionStatus.notGranted")
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static var accessibilityStatusText: String {
        isAccessibilityTrusted ? L10n.text("permissionStatus.granted") : L10n.text("permissionStatus.notGranted")
    }

    @MainActor
    static func requestScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    static func openScreenCaptureSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AppDependencies {
    static var homebrewPath: String? {
        executablePath(named: "brew", candidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    }

    static var ffmpegPath: String? {
        executablePath(named: "ffmpeg", candidates: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
    }

    static var isHomebrewInstalled: Bool { homebrewPath != nil }
    static var isFFmpegInstalled: Bool { ffmpegPath != nil }

    static func openHomebrewInstallTerminal() {
        openTerminalScript(
            basename: "install-homebrew",
            body: """
            #!/bin/bash
            set -e
            export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
            echo "EchoPilot dependency setup"
            echo "Installing Homebrew if it is missing..."
            if command -v brew >/dev/null 2>&1; then
              echo "Homebrew already installed: $(command -v brew)"
            else
              /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            echo
            echo "Done. Return to EchoPilot and click Check Again."
            read -n 1 -s -r -p "Press any key to close this window..."
            """
        )
    }

    static func openFFmpegInstallTerminal() {
        openTerminalScript(
            basename: "install-ffmpeg",
            body: """
            #!/bin/bash
            set -e
            export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
            echo "EchoPilot dependency setup"
            if ! command -v brew >/dev/null 2>&1; then
              echo "Homebrew is required before FFmpeg can be installed."
              echo "Install Homebrew first, then run this again."
              read -n 1 -s -r -p "Press any key to close this window..."
              exit 1
            fi
            echo "Installing FFmpeg via Homebrew..."
            brew install ffmpeg
            echo
            echo "Done. Return to EchoPilot and click Check Again."
            read -n 1 -s -r -p "Press any key to close this window..."
            """
        )
    }

    private static func executablePath(named name: String, candidates: [String]) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func openTerminalScript(basename: String, body: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echopilot-\(basename)-\(Int(Date().timeIntervalSince1970)).command")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            fputs("Failed to open EchoPilot dependency installer: \(error.localizedDescription)\n", stderr)
        }
    }
}

enum SystemIdleMonitor {
    static var idleSeconds: TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let rawProperties = properties?.takeRetainedValue()
        else {
            return 0
        }
        let dictionary = rawProperties as NSDictionary
        guard let idleNanoseconds = dictionary["HIDIdleTime"] as? NSNumber else {
            return 0
        }
        return idleNanoseconds.doubleValue / 1_000_000_000
    }
}

enum EchoPilotUserNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyMeetingDetected(detail: String) {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("meetingDetection.notification.title")
        content.body = "\(L10n.text("meetingDetection.notification.body"))\n\(detail)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "echopilot-meeting-detected-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

final class MicrophoneFileRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.echopilot.app.microphone")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var didStartSession = false
    private var didSeeAppendFailure = false
    private var buffers = 0
    private var appendedBuffers = 0
    private var samples: Int64 = 0
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var level: Float = 0

    let outputURL: URL
    let deviceID: String?

    init(outputURL: URL, deviceID: String?) throws {
        self.outputURL = outputURL
        self.deviceID = deviceID
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RuntimeError("AVAssetWriter cannot add microphone input for \(outputURL.path)")
        }
        writer.add(input)
        super.init()
    }

    static func requestPermission() async -> Bool {
        await MainActor.run { requestPermissionSync() }
    }

    @MainActor
    static func requestPermissionSync() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var result = false
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                result = granted
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            return result
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() throws {
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else {
            throw RuntimeError("Selected microphone device not found")
        }

        let deviceInput = try AVCaptureDeviceInput(device: device)
        captureSession.beginConfiguration()
        if captureSession.canAddInput(deviceInput) {
            captureSession.addInput(deviceInput)
        } else {
            captureSession.commitConfiguration()
            throw RuntimeError("Cannot add microphone input: \(device.localizedName)")
        }
        output.setSampleBufferDelegate(self, queue: queue)
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            captureSession.commitConfiguration()
            throw RuntimeError("Cannot add microphone audio output")
        }
        captureSession.commitConfiguration()
        captureSession.startRunning()
    }

    func stop() {
        captureSession.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        lock.lock()
        buffers += 1
        samples += Int64(CMSampleBufferGetNumSamples(sampleBuffer))
        level = AudioLevelMeter.smooth(previous: level, measured: AudioLevelMeter.level(from: sampleBuffer))
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil { firstPTS = pts }
        lastPTS = pts

        if !didStartSession {
            guard writer.startWriting() else {
                didSeeAppendFailure = true
                let err = writer.error?.localizedDescription ?? "unknown writer error"
                lock.unlock()
                fputs("Failed to start microphone AVAssetWriter: \(err)\n", stderr)
                return
            }
            writer.startSession(atSourceTime: pts)
            didStartSession = true
        }

        guard input.isReadyForMoreMediaData else {
            lock.unlock()
            return
        }
        if input.append(sampleBuffer) {
            appendedBuffers += 1
        } else {
            didSeeAppendFailure = true
            let err = writer.error?.localizedDescription ?? "unknown append error"
            lock.unlock()
            fputs("Failed to append microphone sample buffer: \(err)\n", stderr)
            return
        }
        lock.unlock()
    }

    func snapshot() -> TrackStats {
        lock.lock()
        defer { lock.unlock() }
        let duration: Double?
        if let firstPTS, let lastPTS { duration = CMTimeGetSeconds(lastPTS - firstPTS) } else { duration = nil }
        return TrackStats(buffers: buffers, writtenBuffers: appendedBuffers, samples: samples, duration: duration, failed: didSeeAppendFailure, level: level)
    }

    func finish() async throws {
        lock.lock()
        let didStart = didStartSession
        lock.unlock()
        guard didStart else { return }
        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = self.writer.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}


final class MeetingCaptureService {
    private var stream: SCStream?
    private var systemRecorder: SystemAudioFileRecorder?
    private var micRecorder: MicrophoneFileRecorder?
    private var session: RecordingSession?

    var currentSession: RecordingSession? { session }

    func start(microphoneDeviceID: String?) async throws -> RecordingSession {
        guard stream == nil else { throw RuntimeError("Recording is already running") }
        let hasMicrophonePermission = await MainActor.run {
            MicrophoneFileRecorder.requestPermissionSync()
        }
        guard hasMicrophonePermission else {
            throw RuntimeError("Microphone permission denied. Enable EchoPilot in System Settings → Privacy & Security → Microphone. If EchoPilot is missing there, rebuild/reinstall the stable app and verify entitlements with scripts/diagnose-echopilot-app.sh.")
        }
        let hasScreenCapturePermission = await MainActor.run {
            Self.requestScreenCapturePermissionIfNeeded()
        }
        guard hasScreenCapturePermission else {
            throw RuntimeError("Screen & System Audio Recording permission denied. Enable EchoPilot in System Settings → Privacy & Security → Screen & System Audio Recording. If it was denied before, reset it with: tccutil reset ScreenCapture com.echopilot.app. If you run from Xcode, also allow/reset Xcode itself.")
        }

        let session = try Self.makeSessionFolder()
        var startedMicRecorder: MicrophoneFileRecorder?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw RuntimeError("No display found. ScreenCaptureKit needs a display content filter even for audio capture.")
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            config.sampleRate = 48_000
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let systemRecorder = try SystemAudioFileRecorder(outputURL: session.systemURL)
            let micRecorder = try MicrophoneFileRecorder(outputURL: session.micURL, deviceID: microphoneDeviceID)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let queue = DispatchQueue(label: "com.echopilot.app.system")
            try stream.addStreamOutput(systemRecorder, type: .audio, sampleHandlerQueue: queue)

            try micRecorder.start()
            startedMicRecorder = micRecorder
            try await stream.startCapture()

            self.stream = stream
            self.systemRecorder = systemRecorder
            self.micRecorder = micRecorder
            self.session = session
            return session
        } catch {
            startedMicRecorder?.stop()
            try? await startedMicRecorder?.finish()
            try? FileManager.default.removeItem(at: session.outputDir)
            throw RuntimeError(L10n.format("recording.errorStart", error.localizedDescription))
        }
    }

    func stop() async throws -> RecordingSession? {
        guard let session else { return nil }
        let stream = self.stream
        let micRecorder = self.micRecorder
        let systemRecorder = self.systemRecorder

        self.stream = nil
        self.micRecorder = nil
        self.systemRecorder = nil
        self.session = nil

        try await stream?.stopCapture()
        micRecorder?.stop()
        try await micRecorder?.finish()
        try await systemRecorder?.finish()
        let systemStats = systemRecorder?.snapshot() ?? TrackStats()
        let micStats = micRecorder?.snapshot() ?? TrackStats()
        try writeManifest(session: session, system: systemStats, mic: micStats)
        guard systemStats.hasWrittenAudio || micStats.hasWrittenAudio else {
            try? FileManager.default.removeItem(at: session.outputDir)
            throw RuntimeError(L10n.text("recording.errorEmpty"))
        }
        return session
    }

    func stats() -> (system: TrackStats, mic: TrackStats) {
        (systemRecorder?.snapshot() ?? TrackStats(), micRecorder?.snapshot() ?? TrackStats())
    }

    private static func requestScreenCapturePermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    private static func makeSessionFolder() throws -> RecordingSession {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let dir = documents
            .appendingPathComponent("EchoPilot", isDirectory: true)
            .appendingPathComponent("meeting-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RecordingSession(
            outputDir: dir,
            systemURL: dir.appendingPathComponent("system.m4a"),
            micURL: dir.appendingPathComponent("mic.m4a"),
            manifestURL: dir.appendingPathComponent("manifest.json"),
            startedAt: Date()
        )
    }

    private func writeManifest(session: RecordingSession, system: TrackStats, mic: TrackStats) throws {
        let manifest: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: session.startedAt),
            "finished_at": ISO8601DateFormatter().string(from: Date()),
            "tracks": [
                "system": [
                    "path": session.systemURL.path,
                    "buffers": system.buffers,
                    "written_buffers": system.writtenBuffers,
                    "samples": system.samples,
                    "approx_duration_seconds": system.duration as Any,
                    "failed": system.failed
                ],
                "microphone": [
                    "path": session.micURL.path,
                    "buffers": mic.buffers,
                    "written_buffers": mic.writtenBuffers,
                    "samples": mic.samples,
                    "approx_duration_seconds": mic.duration as Any,
                    "failed": mic.failed
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: session.manifestURL)
    }
}

struct PostProcessResult: Equatable {
    let inputDir: URL
    let notesInputURL: URL
}

final class PostProcessor {
    static func prepareTranscriptionInput(
        for session: RecordingSession,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws -> PostProcessResult {
        try await MainActor.run { progress(0.05, L10n.text("processing.started")) }
        let inputDir = session.outputDir.appendingPathComponent("transcription-input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)

        let systemDest = inputDir.appendingPathComponent("system.m4a")
        let micDest = inputDir.appendingPathComponent("mic.m4a")
        let manifestDest = inputDir.appendingPathComponent("manifest.json")
        for url in [systemDest, micDest, manifestDest] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        try await MainActor.run { progress(0.25, L10n.text("processing.copySystem")) }
        try FileManager.default.copyItem(at: session.systemURL, to: systemDest)
        try await MainActor.run { progress(0.45, L10n.text("processing.copyMic")) }
        try FileManager.default.copyItem(at: session.micURL, to: micDest)
        try await MainActor.run { progress(0.60, L10n.text("processing.copyManifest")) }
        try FileManager.default.copyItem(at: session.manifestURL, to: manifestDest)

        try await MainActor.run { progress(0.75, L10n.text("processing.writeHandoff")) }
        let readme = """
        # Transcription Input

        - `system.m4a` — system/meeting audio, usually other participants
        - `mic.m4a` — selected local microphone, usually the local speaker
        - `manifest.json` — capture stats

        Next step: transcribe both audio tracks, then assemble the KI-agent handover.
        """
        try readme.write(to: inputDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let notesInputURL = inputDir.appendingPathComponent("meeting-notes-input.md")
        let notes = """
        # Meeting Notes Input

        ## Speaker assumptions

        - **Local speaker / microphone** comes from `mic.m4a`.
        - **Other participants / system audio** comes from `system.m4a`.
        - After transcription, `timeline.md` is generated from timestamped `mic.vtt` + `system.vtt` and should be used as the primary KI-agent source.
        - Timeline labels are track-based (`mic/Local speaker`, `system/Andere`); this is not full multi-speaker diarization.

        ## KI-agent task

        Produce every section below. If the transcript contains no evidence for a section, write `Keine im Transkript erkennbar` instead of omitting it.

        1. concise German meeting summary
        2. decisions with evidence quote/time if available
        3. open questions with evidence quote/time if available
        4. action items with owner/due date/status/evidence
        5. suggested task entries
        6. approval gates for anything external/customer-facing/destructive
        7. unclear or missing context that needs follow-up

        ## Transcript status

        Audio prepared. Transcription step is pending.
        """
        try notes.write(to: notesInputURL, atomically: true, encoding: .utf8)

        try await MainActor.run { progress(1.0, L10n.text("processing.progressFinished")) }
        return PostProcessResult(inputDir: inputDir, notesInputURL: notesInputURL)
    }
}

final class LocalTranscriber {
    private static func scriptsDirectory() throws -> URL {
        let fileManager = FileManager.default
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoScripts = sourceFile
            .deletingLastPathComponent() // EchoPilotApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("scripts", isDirectory: true)
        var candidates = [repoScripts]

        if let resourceScripts = Bundle.main.resourceURL?.appendingPathComponent("scripts", isDirectory: true) {
            candidates.insert(resourceScripts, at: 0)
        }

        for scriptsDir in candidates {
            let transcribeScript = scriptsDir.appendingPathComponent("transcribe-local-whisper.sh")
            let assembleScript = scriptsDir.appendingPathComponent("assemble-meeting-notes.sh")
            let timelineScript = scriptsDir.appendingPathComponent("build-timeline.py")
            if fileManager.fileExists(atPath: transcribeScript.path),
               fileManager.fileExists(atPath: assembleScript.path),
               fileManager.fileExists(atPath: timelineScript.path) {
                return scriptsDir
            }
        }

        let expectedPaths = candidates.map { $0.path }.joined(separator: ", ")
        throw RuntimeError("Transcription scripts not found. Expected bundled scripts at one of: \(expectedPaths)")
    }

    private static func transcriptionWorkDirectory() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let workDir = appSupport
            .appendingPathComponent("EchoPilot", isDirectory: true)
            .appendingPathComponent("TranscriptionRuntime", isDirectory: true)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        return workDir
    }

    static func transcribe(
        sessionDir: URL,
        model: String,
        language: String,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws -> URL {
        let scriptsDir = try scriptsDirectory()
        let workDir = try transcriptionWorkDirectory()
        let transcribeScript = scriptsDir.appendingPathComponent("transcribe-local-whisper.sh")
        let assembleScript = scriptsDir.appendingPathComponent("assemble-meeting-notes.sh")
        guard FileManager.default.fileExists(atPath: transcribeScript.path) else {
            throw RuntimeError("Transcription script not found: \(transcribeScript.path)")
        }
        guard FileManager.default.fileExists(atPath: assembleScript.path) else {
            throw RuntimeError("Assemble script not found: \(assembleScript.path)")
        }

        try await MainActor.run { progress(0.05, L10n.text("transcription.progressStarted")) }
        let inputDir = sessionDir.appendingPathComponent("transcription-input", isDirectory: true)
        let logURL = inputDir.appendingPathComponent("transcription.log")

        let command = """
        set -euo pipefail
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        cd \(shellQuote(workDir.path))
        mkdir -p \(shellQuote(inputDir.path))
        export WHISPER_MODEL=\(shellQuote(model))
        export WHISPER_LANGUAGE=\(shellQuote(language))
        {
          date
          \(shellQuote(transcribeScript.path)) \(shellQuote(sessionDir.path))
          \(shellQuote(assembleScript.path)) \(shellQuote(inputDir.path))
        } 2>&1 | tee \(shellQuote(logURL.path))
        """

        try await MainActor.run { progress(0.15, L10n.format("transcription.progressWhisperStart", model, language)) }
        try await runShell(command) { line in
            Task { @MainActor in
                progress(0.45, L10n.format("transcription.progressWhisperRunning", line))
            }
        }

        let notesURL = inputDir.appendingPathComponent("meeting-notes-input.md")
        guard FileManager.default.fileExists(atPath: notesURL.path) else {
            throw RuntimeError("Transcription finished but meeting-notes-input.md was not created")
        }
        try await MainActor.run { progress(1.0, L10n.text("transcription.progressFinished")) }
        return notesURL
    }

    private final class RunningProcess {
        private let lock = NSLock()
        private var process: Process?

        func set(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            let process = self.process
            lock.unlock()
            process?.terminate()
        }
    }

    private static func runShell(_ command: String, onLine: @escaping (String) -> Void) async throws {
        let runningProcess = RunningProcess()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-lc", command]
                runningProcess.set(process)

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                var output = ""
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    output += text
                    if let line = text.split(separator: "\n").last.map(String.init), !line.isEmpty {
                        onLine(line)
                    }
                }

                process.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let tail = Self.tailLines(output, limit: 36)
                        let message = tail.isEmpty
                            ? "Transcription process failed with exit \(proc.terminationStatus)"
                            : "Transcription process failed with exit \(proc.terminationStatus). Last output:\n\(tail)"
                        continuation.resume(throwing: RuntimeError(message))
                    }
                }

                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            runningProcess.terminate()
        })
    }

    private static func tailLines(_ text: String, limit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(limit).map(String.init).joined(separator: "\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct MeetingRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL
    let createdAt: Date
    let hasTranscript: Bool
    let isFullyTranscribed: Bool
    let hasSummary: Bool
    let isArchived: Bool
    let segmentCount: Int
    let pendingTranscriptCount: Int

    func subtitle(language: AppLanguage = AppSettings.currentLanguage) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = language == .german ? Locale(identifier: "de_DE") : Locale(identifier: "en_US")
        var parts = [formatter.string(from: createdAt)]
        if segmentCount > 1 {
            parts.append(L10n.format("meeting.parts", language: language, segmentCount))
        }
        if pendingTranscriptCount > 0 {
            parts.append(L10n.format("meeting.pendingTranscripts", language: language, pendingTranscriptCount))
        } else {
            parts.append(hasTranscript ? L10n.text("meeting.transcribed", language: language) : L10n.text("meeting.notTranscribed", language: language))
        }
        if hasSummary { parts.append("Summary") }
        if isArchived { parts.append(L10n.text("meeting.archived", language: language)) }
        return parts.joined(separator: " · ")
    }
}

struct MeetingArtifactTarget: Identifiable, Hashable {
    let id: String
    let title: String
    let sessionDir: URL
    let transcriptURL: URL
    let summaryURL: URL
    let kiAgentExportURL: URL
    let usesCombinedTranscript: Bool
}

struct MeetingMetadata: Codable, Equatable {
    var title: String
    var participants: String
    var customerProject: String
    var consentConfirmed: Bool
    var updatedAt: String
    var archived: Bool

    init(title: String, participants: String, customerProject: String, consentConfirmed: Bool, updatedAt: String, archived: Bool = false) {
        self.title = title
        self.participants = participants
        self.customerProject = customerProject
        self.consentConfirmed = consentConfirmed
        self.updatedAt = updatedAt
        self.archived = archived
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case participants
        case customerProject
        case consentConfirmed
        case updatedAt
        case archived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        participants = try container.decodeIfPresent(String.self, forKey: .participants) ?? ""
        customerProject = try container.decodeIfPresent(String.self, forKey: .customerProject) ?? ""
        consentConfirmed = try container.decodeIfPresent(Bool.self, forKey: .consentConfirmed) ?? false
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}

enum AppLanguage: String {
    case german = "de"
    case english = "en"
}

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case german
    case english

    var id: String { rawValue }

    var resolvedLanguage: AppLanguage {
        switch self {
        case .german:
            return .german
        case .english:
            return .english
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("de") ? .german : .english
        }
    }
}

enum AppSettings {
    private static let selectedAudioInputIDKey = "selectedAudioInputID"
    private static let whisperModelKey = "whisperModel"
    private static let whisperLanguageKey = "whisperLanguage"
    private static let dismissedUpdateVersionKey = "dismissedUpdateVersion"
    private static let batchIdleEnabledKey = "batchIdleEnabled"
    private static let batchIdleMinutesKey = "batchIdleMinutes"
    private static let batchScheduleEnabledKey = "batchScheduleEnabled"
    private static let batchScheduledMinuteOfDayKey = "batchScheduledMinuteOfDay"
    private static let lastScheduledBatchRunKey = "lastScheduledBatchRun"
    private static let transcriptPreviewExpandedKey = "transcriptPreviewExpanded"
    static let preferredUILanguageKey = "preferredUILanguage"

    static var preferredUILanguage: AppLanguagePreference {
        get { AppLanguagePreference(rawValue: UserDefaults.standard.string(forKey: preferredUILanguageKey) ?? AppLanguagePreference.system.rawValue) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferredUILanguageKey) }
    }

    static var currentLanguage: AppLanguage {
        preferredUILanguage.resolvedLanguage
    }

    static var selectedAudioInputID: String? {
        get { UserDefaults.standard.string(forKey: selectedAudioInputIDKey) }
        set {
            if let newValue, !newValue.isEmpty { UserDefaults.standard.set(newValue, forKey: selectedAudioInputIDKey) }
            else { UserDefaults.standard.removeObject(forKey: selectedAudioInputIDKey) }
        }
    }

    static var whisperModel: String {
        get { UserDefaults.standard.string(forKey: whisperModelKey) ?? "turbo" }
        set { UserDefaults.standard.set(newValue, forKey: whisperModelKey) }
    }

    static var whisperLanguage: String {
        get { UserDefaults.standard.string(forKey: whisperLanguageKey) ?? "de" }
        set { UserDefaults.standard.set(newValue, forKey: whisperLanguageKey) }
    }

    static var dismissedUpdateVersion: String? {
        get { UserDefaults.standard.string(forKey: dismissedUpdateVersionKey) }
        set {
            if let newValue, !newValue.isEmpty { UserDefaults.standard.set(newValue, forKey: dismissedUpdateVersionKey) }
            else { UserDefaults.standard.removeObject(forKey: dismissedUpdateVersionKey) }
        }
    }

    static var batchIdleEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: batchIdleEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: batchIdleEnabledKey) }
    }

    static var batchIdleMinutes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: batchIdleMinutesKey)
            return value > 0 ? value : 10
        }
        set { UserDefaults.standard.set(max(2, min(120, newValue)), forKey: batchIdleMinutesKey) }
    }

    static var batchScheduleEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: batchScheduleEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: batchScheduleEnabledKey) }
    }

    static var batchScheduledTime: Date {
        get {
            let stored = UserDefaults.standard.object(forKey: batchScheduledMinuteOfDayKey) as? Int ?? 120
            return dateForMinuteOfDay(stored)
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            UserDefaults.standard.set(minuteOfDay, forKey: batchScheduledMinuteOfDayKey)
        }
    }

    static var lastScheduledBatchRun: String? {
        get { UserDefaults.standard.string(forKey: lastScheduledBatchRunKey) }
        set {
            if let newValue, !newValue.isEmpty { UserDefaults.standard.set(newValue, forKey: lastScheduledBatchRunKey) }
            else { UserDefaults.standard.removeObject(forKey: lastScheduledBatchRunKey) }
        }
    }

    static var transcriptPreviewExpanded: Bool {
        get { UserDefaults.standard.bool(forKey: transcriptPreviewExpandedKey) }
        set { UserDefaults.standard.set(newValue, forKey: transcriptPreviewExpandedKey) }
    }

    private static func dateForMinuteOfDay(_ minuteOfDay: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = max(0, min(23, minuteOfDay / 60))
        components.minute = max(0, min(59, minuteOfDay % 60))
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage = AppSettings.currentLanguage) -> String {
        translations[key]?[language] ?? translations[key]?[.english] ?? key
    }

    static func format(_ key: String, language: AppLanguage = AppSettings.currentLanguage, _ args: CVarArg...) -> String {
        String(format: text(key, language: language), arguments: args)
    }

    private static let translations: [String: [AppLanguage: String]] = [
        "language.system": [.german: "Automatisch", .english: "Automatic"],
        "language.german": [.german: "Deutsch", .english: "German"],
        "language.english": [.german: "Englisch", .english: "English"],
        "language.effective": [.german: "Aktiv: %@", .english: "Active: %@"],

        "workflow.prepare": [.german: "Vorbereiten", .english: "Prepare"],
        "workflow.record": [.german: "Aufzeichnen", .english: "Record"],
        "workflow.transcribe": [.german: "Transkribieren", .english: "Transcribe"],
        "workflow.review": [.german: "Review", .english: "Review"],
        "workflow.export": [.german: "Export", .english: "Export"],
        "workflow.prepare.subtitle": [.german: "Kontext prüfen und die Aufnahme vorbereiten.", .english: "Confirm context and prepare the recording."],
        "workflow.record.subtitle": [.german: "Systemaudio und Mikrofon werden lokal als getrennte Spuren aufgezeichnet.", .english: "Capture system audio and microphone as separate local tracks."],
        "workflow.transcribe.subtitle": [.german: "Die Aufnahme ist bereit. Als Nächstes lokal mit Whisper transkribieren.", .english: "The recording is ready. Run local Whisper next."],
        "workflow.review.subtitle": [.german: "Transkripte, Timeline, Zusammenfassung und Handoff-Dateien prüfen.", .english: "Review transcripts, timeline, summaries, and handoff files."],
        "workflow.export.subtitle": [.german: "Meeting für Follow-up oder KI-Agenten verpacken.", .english: "Package the meeting for follow-up or AI-agent processing."],

        "command.title": [.german: "Meeting-Kommandozentrale", .english: "Meeting Command Center"],
        "command.hideInspector": [.german: "Inspector ausblenden", .english: "Hide Inspector"],
        "command.showInspector": [.german: "Inspector anzeigen", .english: "Show Inspector"],
        "command.recordingAgreementNotice": [.german: "Aufzeichnung nur nach vorheriger Absprache mit allen Teilnehmenden starten.", .english: "Recording should only be started after prior agreement with everyone in the meeting."],
        "command.next.completePermissions": [.german: "Berechtigungen vervollständigen", .english: "Complete permissions"],
        "command.next.transcribe": [.german: "Lokal transkribieren", .english: "Transcribe locally"],
        "command.next.review": [.german: "Meeting-Notizen prüfen", .english: "Review meeting notes"],
        "command.next.export": [.german: "Handoff-Dateien teilen oder sammeln", .english: "Share or collect handoff files"],
        "command.nextDetail.prepare": [.german: "Meeting-Kontext ausfüllen und Mikrofon wählen.", .english: "Fill meeting context and choose the microphone."],
        "command.nextDetail.record": [.german: "Die aktuelle Aufnahme bleibt lokal. Stoppen, um die Transkription vorzubereiten.", .english: "The current recording is local. Stop it to prepare transcription input."],
        "command.nextDetail.transcribe": [.german: "Lokales Whisper ausführen, bevor Transkripte und Handoff-Dateien geprüft werden.", .english: "Run local Whisper before reviewing transcripts and generating handoff files."],
        "command.nextDetail.review": [.german: "Zusammenfassung, Timeline, Transkripte und Quelldateien vor dem Export prüfen.", .english: "Check summary, timeline, transcripts, and source files before exporting."],
        "command.nextDetail.export": [.german: "KI-Handoff-Pakete im Dateien-Tab öffnen, teilen oder sammeln.", .english: "Open, share, or collect AI handoff packages from the Files tab."],

        "update.cardTitle": [.german: "Update verfügbar", .english: "Update available"],
        "update.subtitle": [.german: "Installiert %@, aktuell %@", .english: "Installed %@, latest %@"],
        "update.openRelease": [.german: "Release öffnen", .english: "Open release"],
        "update.dismiss": [.german: "Ausblenden", .english: "Dismiss"],

        "permissions.warning.title": [.german: "Berechtigungen brauchen Aufmerksamkeit", .english: "Permissions need attention"],
        "permissions.warning.subtitle": [.german: "EchoPilot benötigt Mikrofon und Screen/Systemaudio vor der Aufnahme.", .english: "EchoPilot needs microphone and Screen/System Audio access before recording."],
        "permissions.warning.text": [.german: "Setup prüfen oder Einstellungen öffnen, um fehlende macOS-Berechtigungen zu erteilen.", .english: "Review setup or open Settings to grant the missing macOS permissions."],
        "permissions.reviewSetup": [.german: "Setup prüfen", .english: "Review setup"],
        "setup.title": [.german: "EchoPilot Setup", .english: "EchoPilot setup"],
        "setup.subtitle": [.german: "Für zuverlässige Aufnahmen braucht EchoPilot macOS-Berechtigungen und lokale Tools.", .english: "Recording needs macOS permissions and local tools before the workflow is reliable."],
        "setup.request": [.german: "Anfragen", .english: "Request"],
        "setup.install": [.german: "Installieren", .english: "Install"],
        "setup.checkAgain": [.german: "Erneut prüfen", .english: "Check again"],
        "setup.later": [.german: "Später", .english: "Later"],
        "setup.done": [.german: "Fertig", .english: "Done"],
        "setup.done.disabled": [.german: "Erforderliche Berechtigungen und Tools zuerst abschließen.", .english: "Finish required permissions and tools first."],
        "status.ok": [.german: "OK", .english: "OK"],
        "status.readyShort": [.german: "Bereit", .english: "Ready"],
        "status.missing": [.german: "Fehlt", .english: "Missing"],
        "audio.microphone": [.german: "Mikrofon", .english: "Microphone"],
        "audio.systemAudio": [.german: "Systemaudio", .english: "System audio"],

        "sidebar.filter": [.german: "Filter", .english: "Filter"],
        "sidebar.search": [.german: "Meetings suchen", .english: "Search meetings"],
        "sidebar.shownCount": [.german: "%d angezeigt", .english: "%d shown"],
        "sidebar.filter.all": [.german: "Alle", .english: "All"],
        "sidebar.filter.needsTranscription": [.german: "Braucht Transkription", .english: "Needs transcription"],
        "sidebar.filter.transcribed": [.german: "Transkribiert", .english: "Transcribed"],
        "sidebar.filter.archived": [.german: "Archiviert", .english: "Archived"],
        "sidebar.status.ready": [.german: "Bereit", .english: "Ready"],
        "sidebar.status.open": [.german: "Offen", .english: "Open"],
        "sidebar.openCount": [.german: "%d offen", .english: "%d open"],
        "sidebar.archive": [.german: "Archivieren", .english: "Archive"],
        "sidebar.unarchive": [.german: "Aus Archiv holen", .english: "Unarchive"],
        "sidebar.delete": [.german: "Löschen", .english: "Delete"],

        "detection.title": [.german: "Smarte Meeting-Erkennung", .english: "Smart meeting detection"],
        "detection.subtitle": [.german: "Lokaler Teams/Zoom/Webex/Meet/Slack/Browser-Kontext bleibt optional und berechtigungsbewusst.", .english: "Local Teams/Zoom/Webex/Meet/Slack/browser context stays optional and permission-aware."],
        "detection.activityDetected": [.german: "Meeting-Aktivität erkannt", .english: "Meeting activity detected"],
        "detection.noneDetected": [.german: "Kein aktives Meeting erkannt", .english: "No active meeting detected"],
        "detection.participantsMissing": [.german: "Teilnehmende noch nicht erkannt", .english: "Participants not detected yet"],
        "detection.suggested": [.german: "Vorschlag", .english: "Suggested"],
        "detection.idle": [.german: "Bereit", .english: "Idle"],
        "detection.use": [.german: "Übernehmen", .english: "Use"],
        "detection.edit": [.german: "Bearbeiten", .english: "Edit"],
        "detection.ignore": [.german: "Ignorieren", .english: "Ignore"],
        "detection.status.loaded": [.german: "Vorschlag geladen. Meeting-Felder vor der Aufnahme bearbeiten.", .english: "Suggestion loaded. Edit the meeting fields before recording."],
        "detection.status.ignored": [.german: "Meeting-Vorschlag ignoriert.", .english: "Meeting suggestion ignored."],

        "recording.title": [.german: "Aufzeichnung", .english: "Recording"],
        "recording.subtitle": [.german: "Meeting einmal vorbereiten, dann die eine klare Aufnahme-Aktion nutzen.", .english: "Prepare the meeting once, then use the one obvious recording action."],
        "recording.elapsed": [.german: "Aufnahme %@", .english: "Recording %@"],
        "recording.next.transcribe": [.german: "Nächster Schritt: lokal transkribieren", .english: "Next: Transcribe locally"],
        "recording.next.prepare": [.german: "Nächster Schritt: vorbereiten und aufnehmen", .english: "Next: Prepare and record"],
        "meeting.placeholder.title": [.german: "Wöchentliches Kundengespräch", .english: "Weekly customer sync"],
        "meeting.placeholder.participants": [.german: "Namen oder Rollen", .english: "Names or roles"],
        "meeting.placeholder.customerProject": [.german: "Quartz, Synmedico, intern ...", .english: "Quartz, Synmedico, internal..."],

        "inspector.title": [.german: "Inspector", .english: "Inspector"],
        "inspector.transcription.subtitle": [.german: "Erweiterte Kontrollen bleiben hier, bis sie relevant sind.", .english: "Advanced controls stay here until they are relevant."],
        "inspector.whisperModel": [.german: "Whisper-Modell", .english: "Whisper model"],
        "inspector.models.none": [.german: "Noch keine Whisper-Modelle erkannt", .english: "No Whisper models detected yet"],
        "inspector.models.installed": [.german: "Installiert: %@", .english: "Installed: %@"],
        "inspector.cancelTranscription": [.german: "Transkription abbrechen", .english: "Cancel transcription"],
        "batch.automation": [.german: "Batch-Automation", .english: "Batch automation"],
        "batch.automation.subtitle": [.german: "Nutzen, wenn EchoPilot Aufnahmen außerhalb von Meetings abarbeiten soll.", .english: "Use when EchoPilot should clear recordings outside meeting time."],
        "batch.run": [.german: "Batch starten", .english: "Run batch"],
        "batch.idleTranscription": [.german: "Idle-Transkription", .english: "Idle transcription"],
        "batch.afterIdle": [.german: "Nach %d Min. Leerlauf", .english: "After %d min idle"],
        "batch.dailySchedule": [.german: "Täglicher Zeitplan", .english: "Daily schedule"],
        "batch.runAt": [.german: "Start um", .english: "Run at"],

        "review.subtitle": [.german: "Alles nach der Transkription landet hier.", .english: "Everything after transcription lands here."],
        "review.tabPicker": [.german: "Review-Tab", .english: "Review tab"],
        "review.tab.summary": [.german: "Zusammenfassung", .english: "Summary"],
        "review.tab.timeline": [.german: "Timeline", .english: "Timeline"],
        "review.tab.combined": [.german: "Kombiniertes Transkript", .english: "Combined transcript"],
        "review.tab.system": [.german: "System-Transkript", .english: "System transcript"],
        "review.tab.microphone": [.german: "Mikrofon-Transkript", .english: "Microphone transcript"],
        "review.tab.handoff": [.german: "KI-Handoff", .english: "AI handoff"],
        "review.tab.files": [.german: "Dateien", .english: "Files"],
        "review.summary.empty": [.german: "Noch keine Zusammenfassung erzeugt.", .english: "No summary generated yet."],
        "review.generateSummary": [.german: "Zusammenfassung erzeugen", .english: "Generate summary"],
        "review.generateHandoff": [.german: "KI-Handoff erzeugen", .english: "Generate AI handoff"],
        "review.share": [.german: "Teilen", .english: "Share"],
        "review.openFile": [.german: "Datei öffnen", .english: "Open file"],
        "review.openExportFolder": [.german: "Export-Ordner öffnen", .english: "Open export folder"],
        "review.openMeetingFolder": [.german: "Meeting-Ordner öffnen", .english: "Open meeting folder"],
        "review.openTranscriptionInput": [.german: "Transkriptions-Input öffnen", .english: "Open transcription input"],
        "review.collectExports": [.german: "KI-Exporte sammeln", .english: "Collect AI exports"],
        "review.files.localNotice": [.german: "Dateien bleiben lokal. EchoPilot lädt Aufnahmen oder Transkripte nicht selbst hoch.", .english: "Files are local. EchoPilot does not upload recordings or transcripts by itself."],
        "review.loading": [.german: "%@ wird geladen ...", .english: "Loading %@..."],
        "review.readFailed": [.german: "%@ konnte nicht gelesen werden.", .english: "Could not read %@."],
        "disabled.selectMeeting": [.german: "Zuerst ein Meeting auswählen.", .english: "Select a meeting first."],
        "disabled.selectOrRecordMeeting": [.german: "Zuerst ein Meeting auswählen oder aufnehmen.", .english: "Select or record a meeting first."],
        "disabled.stopBeforeTranscription": [.german: "Aufnahme vor der Transkription stoppen.", .english: "Stop recording before transcription."],
        "disabled.stopBeforeBatch": [.german: "Aufnahme vor der Batch-Transkription stoppen.", .english: "Stop recording before batch transcription."],
        "disabled.preparingTranscriptionInput": [.german: "Transkriptions-Input wird vorbereitet.", .english: "Preparing transcription input."],
        "disabled.transcriptionRunning": [.german: "Transkription läuft bereits.", .english: "Transcription already running."],
        "disabled.installFFmpeg": [.german: "Zuerst FFmpeg installieren.", .english: "Install FFmpeg first."],
        "disabled.busy": [.german: "EchoPilot ist beschäftigt.", .english: "EchoPilot is busy."],
        "disabled.generateSummaryFirst": [.german: "Zuerst eine Zusammenfassung erzeugen.", .english: "Generate a summary first."],
        "disabled.fileMissing": [.german: "Datei existiert noch nicht.", .english: "File does not exist yet."],
        "disabled.noTranscriptionInput": [.german: "Noch kein Transkriptions-Input-Ordner vorhanden.", .english: "No transcription input folder yet."],
        "disabled.recorderPreparing": [.german: "EchoPilot bereitet die Aufnahme vor.", .english: "EchoPilot is preparing the recorder."],
        "disabled.recordingRunning": [.german: "Aufzeichnung läuft bereits.", .english: "Recording is already running."],
        "disabled.permissionsRequired": [.german: "Mikrofon und Screen/Systemaudio sind erforderlich.", .english: "Microphone and Screen/System Audio Recording permissions are required."],

        "prefs.title": [.german: "Einstellungen", .english: "Preferences"],
        "prefs.language": [.german: "Sprache", .english: "Language"],
        "prefs.language.help": [.german: "Automatisch nutzt Deutsch bei deutscher Systemsprache, sonst Englisch.", .english: "Automatic uses German for German system language and English otherwise."],
        "prefs.maintenance": [.german: "Wartung", .english: "Maintenance"],
        "prefs.permissions": [.german: "Berechtigungen", .english: "Permissions"],
        "prefs.permissions.help": [.german: "Mikrofon und Screen/Systemaudio sind für Aufnahmen erforderlich. Accessibility verbessert nur die Meeting-Erkennung.", .english: "Microphone and Screen/System Audio are required for recording. Accessibility only improves meeting detection."],
        "prefs.checkUpdates": [.german: "Nach Updates suchen", .english: "Check for Updates"],
        "prefs.checkPermissions": [.german: "Setup prüfen", .english: "Check Setup"],
        "prefs.openMicrophone": [.german: "Mikrofon öffnen", .english: "Open Microphone"],
        "prefs.openSystemAudio": [.german: "Systemaudio öffnen", .english: "Open System Audio"],
        "prefs.openAccessibility": [.german: "Bedienungshilfen öffnen", .english: "Open Accessibility"],
        "prefs.checkUpdates.help": [.german: "Prüft GitHub Releases und zeigt einen Hinweis im Hauptfenster.", .english: "Checks GitHub Releases and shows a notice in the main window."],
        "prefs.checkPermissions.help": [.german: "Öffnet EchoPilot und prüft Mikrofon, Screen/Systemaudio, Homebrew und FFmpeg.", .english: "Opens EchoPilot and checks microphone, screen/system audio, Homebrew, and FFmpeg."],

        "menu.show": [.german: "EchoPilot anzeigen", .english: "Show EchoPilot"],
        "menu.preferences": [.german: "Einstellungen…", .english: "Preferences…"],
        "menu.startRecording": [.german: "Aufnahme starten", .english: "Start Recording"],
        "menu.stopRecording": [.german: "Aufnahme stoppen", .english: "Stop Recording"],
        "menu.quit": [.german: "Beenden", .english: "Quit"],
        "tooltip.idle": [.german: "EchoPilot", .english: "EchoPilot"],
        "tooltip.recording": [.german: "EchoPilot nimmt auf", .english: "EchoPilot is recording"],

        "app.subtitle": [.german: "Native macOS Meeting Capture: Systemaudio + Mikrofon, lokal, ohne Bot.", .english: "Native macOS meeting capture: system audio + microphone, local, no bot."],
        "sidebar.meetings": [.german: "Meetings", .english: "Meetings"],
        "sidebar.new.help": [.german: "Neue Aufnahme vorbereiten", .english: "Prepare new recording"],
        "sidebar.empty.title": [.german: "Noch keine Meetings", .english: "No meetings yet"],
        "sidebar.empty.subtitle": [.german: "Aufnahmen erscheinen hier automatisch.", .english: "Recordings appear here automatically."],
        "sidebar.showArchived": [.german: "Archiv anzeigen", .english: "Show archive"],
        "sidebar.emptyArchiveHidden": [.german: "Keine aktiven Meetings. Archiv anzeigen, um ausgeblendete Meetings zu sehen.", .english: "No active meetings. Show archive to view hidden meetings."],
        "meeting.transcribed": [.german: "Transkribiert", .english: "Transcribed"],
        "meeting.notTranscribed": [.german: "Nicht transkribiert", .english: "Not transcribed"],
        "meeting.parts": [.german: "%d Teile", .english: "%d parts"],
        "meeting.pendingTranscripts": [.german: "%d offen", .english: "%d pending"],
        "meeting.archived": [.german: "Archiviert", .english: "Archived"],
        "meeting.archive": [.german: "Archivieren", .english: "Archive"],
        "meeting.unarchive": [.german: "Aus Archiv zurückholen", .english: "Unarchive"],
        "status.archived": [.german: "Meeting archiviert: %@", .english: "Meeting archived: %@"],
        "status.unarchived": [.german: "Meeting aus Archiv zurückgeholt: %@", .english: "Meeting unarchived: %@"],
        "status.archiveFailed": [.german: "Archivierung fehlgeschlagen: %@", .english: "Archive update failed: %@"],

        "permissions.title": [.german: "EchoPilot Setup", .english: "EchoPilot Setup"],
        "permissions.intro": [.german: "Bitte einmal vor der Nutzung prüfen. So merken wir fehlende Berechtigungen oder Tools direkt beim Start – nicht erst, wenn du ein Meeting aufzeichnen willst.", .english: "Please check these once before using EchoPilot. This catches missing permissions or tools at startup instead of during a meeting."],
        "permissions.microphone": [.german: "Mikrofon", .english: "Microphone"],
        "permissions.microphone.explanation": [.german: "Benötigt für deine lokale Spur.", .english: "Required for your local track."],
        "permissions.microphone.request": [.german: "Mikrofon freigeben", .english: "Allow Microphone"],
        "permissions.screen": [.german: "Screen & System Audio Recording", .english: "Screen & System Audio Recording"],
        "permissions.screen.explanation": [.german: "Benötigt für Systemaudio und Meeting-Fenster-Erkennung.", .english: "Required for system audio and meeting-window detection."],
        "permissions.screen.request": [.german: "Systemaudio freigeben", .english: "Allow System Audio"],
        "permissions.recheck": [.german: "Erneut prüfen", .english: "Check Again"],
        "permissions.microphoneSettings": [.german: "Systemeinstellungen: Mikrofon", .english: "System Settings: Microphone"],
        "permissions.systemAudioSettings": [.german: "Systemeinstellungen: Systemaudio", .english: "System Settings: System Audio"],
        "permissions.later": [.german: "Später", .english: "Later"],
        "permissions.done": [.german: "Fertig", .english: "Done"],
        "permissions.note": [.german: "Hinweis: Nach Screen/Systemaudio-Freigabe oder Tool-Installation verlangt macOS bzw. Terminal manchmal einen Neustart der App. Danach hier auf „Erneut prüfen“ klicken.", .english: "Note: After granting screen/system audio access or installing tools, macOS/Terminal may require restarting the app. Then click “Check Again”."],
        "permissions.settings": [.german: "Einstellungen", .english: "Settings"],
        "dependencies.homebrew": [.german: "Homebrew", .english: "Homebrew"],
        "dependencies.homebrew.explanation": [.german: "Benötigt, um FFmpeg direkt aus EchoPilot heraus installieren zu können.", .english: "Required to install FFmpeg directly from EchoPilot."],
        "dependencies.homebrew.install": [.german: "Homebrew installieren", .english: "Install Homebrew"],
        "dependencies.ffmpeg": [.german: "FFmpeg", .english: "FFmpeg"],
        "dependencies.ffmpeg.explanation": [.german: "Benötigt für lokale Transkription und Audio-Verarbeitung.", .english: "Required for local transcription and audio processing."],
        "dependencies.ffmpeg.install": [.german: "FFmpeg installieren", .english: "Install FFmpeg"],
        "dependencyStatus.installedAt": [.german: "Installiert: %@", .english: "Installed: %@"],
        "dependencyStatus.missing": [.german: "Fehlt", .english: "Missing"],
        "permissionStatus.granted": [.german: "Freigegeben", .english: "Granted"],
        "permissionStatus.notRequested": [.german: "Noch nicht angefragt", .english: "Not requested yet"],
        "permissionStatus.denied": [.german: "Abgelehnt", .english: "Denied"],
        "permissionStatus.restricted": [.german: "Eingeschränkt", .english: "Restricted"],
        "permissionStatus.unknown": [.german: "Unbekannt", .english: "Unknown"],
        "permissionStatus.notGranted": [.german: "Nicht freigegeben", .english: "Not granted"],

        "meeting.title": [.german: "Meeting", .english: "Meeting"],
        "meeting.field.title": [.german: "Titel", .english: "Title"],
        "meeting.field.participants": [.german: "Teilnehmer", .english: "Participants"],
        "meeting.field.customerProject": [.german: "Kunde / Projekt", .english: "Customer / Project"],
        "meeting.consent": [.german: "Teilnehmer wurden über Transkript/Meeting Notes informiert", .english: "Participants were informed about transcript/meeting notes"],
        "meeting.newHint": [.german: "Neue Aufnahme: Titel/Metadaten jetzt vorbereiten; gespeichert wird beim Start der Aufnahme.", .english: "New recording: prepare title/metadata now; it will be saved when recording starts."],
        "meeting.updateTitle": [.german: "Update zu %@", .english: "Update for %@"],
        "meeting.delete": [.german: "Meeting löschen", .english: "Delete Meeting"],

        "input.title": [.german: "Mikrofon/Input", .english: "Microphone/Input"],
        "input.microphone": [.german: "Mikrofon", .english: "Microphone"],
        "transcription.title": [.german: "Transkription", .english: "Transcription"],
        "transcription.model": [.german: "Modell", .english: "Model"],
        "transcription.language": [.german: "Sprache", .english: "Language"],
        "transcription.german": [.german: "Deutsch", .english: "German"],
        "transcription.english": [.german: "Englisch", .english: "English"],
        "transcription.auto": [.german: "Auto", .english: "Auto"],
        "transcription.models.none": [.german: "Installiert: keine erkannt · Modelle werden beim ersten Transkribieren geladen.", .english: "Installed: none detected · models are downloaded on first transcription."],
        "transcription.models.installed": [.german: "Installiert: %@", .english: "Installed: %@"],
        "batch.title": [.german: "Batch-Transkription", .english: "Batch Transcription"],
        "batch.transcribeAll": [.german: "Alle offenen transkribieren", .english: "Transcribe All Open"],
        "batch.cancel": [.german: "Batch abbrechen", .english: "Cancel Batch"],
        "batch.autoIdle": [.german: "Automatisch bei Leerlauf", .english: "Auto-run when idle"],
        "batch.idleMinutes": [.german: "nach %d Min.", .english: "after %d min."],
        "batch.schedule": [.german: "Täglich um", .english: "Daily at"],
        "batch.openCount": [.german: "%d offen", .english: "%d open"],
        "modelHint.turbo": [.german: "Apple Silicon schnell", .english: "fast on Apple Silicon"],
        "modelHint.small": [.german: "Standard/leicht", .english: "standard/lightweight"],
        "modelHint.large": [.german: "Qualität/langsam", .english: "quality/slow"],
        "modelState.installed": [.german: "installiert", .english: "installed"],
        "modelState.download": [.german: "wird beim ersten Lauf geladen", .english: "downloads on first run"],

        "button.startRecording": [.german: "Aufnahme starten", .english: "Start Recording"],
        "button.stopRecording": [.german: "Aufnahme stoppen", .english: "Stop Recording"],
        "button.starting": [.german: "Starte…", .english: "Starting…"],
        "button.newRecording": [.german: "Neue Aufnahme", .english: "New Recording"],
        "button.appendUpdate": [.german: "Update anhängen", .english: "Append Update"],
        "button.transcribe": [.german: "Transkribieren", .english: "Transcribe"],
        "button.cancel": [.german: "Abbrechen", .english: "Cancel"],
        "actions.more": [.german: "Weitere Aktionen", .english: "More Actions"],
        "actions.checkPermissions": [.german: "Setup prüfen", .english: "Check Setup"],
        "actions.reloadMicrophones": [.german: "Mikrofone neu laden", .english: "Reload Microphones"],
        "actions.checkWhisperModels": [.german: "Whisper-Modelle prüfen", .english: "Check Whisper Models"],
        "actions.checkUpdates": [.german: "Nach Updates suchen", .english: "Check for Updates"],
        "actions.openOutput": [.german: "Output öffnen", .english: "Open Output"],
        "actions.openTranscriptionInput": [.german: "Transcription-Input öffnen", .english: "Open Transcription Input"],
        "actions.saveMetadata": [.german: "Metadaten speichern", .english: "Save Metadata"],

        "suggestion.prepare": [.german: "Aufnahme vorbereiten", .english: "Prepare Recording"],
        "meetingDetection.title": [.german: "Meeting-Erkennung", .english: "Meeting Detection"],
        "meetingDetection.inMeeting": [.german: "Meeting/Call wahrscheinlich aktiv", .english: "Meeting/call likely active"],
        "meetingDetection.notInMeeting": [.german: "Kein aktiver Call erkannt", .english: "No active call detected"],
        "meetingDetection.micActive": [.german: "Mikrofon aktiv", .english: "Microphone active"],
        "meetingDetection.cameraActive": [.german: "Kamera aktiv", .english: "Camera active"],
        "meetingDetection.unknownMic": [.german: "Unbekanntes Mikrofon", .english: "Unknown microphone"],
        "meetingDetection.notification.title": [.german: "Meeting erkannt", .english: "Meeting detected"],
        "meetingDetection.notification.body": [.german: "Soll EchoPilot dieses Meeting aufzeichnen? Klicken zum Öffnen.", .english: "Should EchoPilot record this meeting? Click to open."],
        "button.dismiss": [.german: "Ausblenden", .english: "Dismiss"],

        "update.title": [.german: "Neue EchoPilot-Version verfügbar", .english: "New EchoPilot Version Available"],
        "update.versions": [.german: "Installiert: %@ · Neu: %@", .english: "Installed: %@ · New: %@"],
        "update.open": [.german: "Release öffnen", .english: "Open Release"],

        "levels.title": [.german: "Live Pegel", .english: "Live Levels"],
        "levels.system": [.german: "Systemaudio", .english: "System Audio"],
        "levels.microphone": [.german: "Mikrofon", .english: "Microphone"],
        "status.recording": [.german: "REC %@", .english: "REC %@"],
        "status.idle": [.german: "Idle", .english: "Idle"],
        "status.title": [.german: "Status", .english: "Status"],

        "transcript.statusTitle": [.german: "Transkriptionsstatus", .english: "Transcription Status"],
        "transcripts.title": [.german: "Transkripte", .english: "Transcripts"],
        "transcripts.view": [.german: "Ansicht", .english: "View"],
        "transcripts.show": [.german: "Transkripte anzeigen", .english: "Show transcripts"],
        "transcripts.hide": [.german: "Transkripte einklappen", .english: "Collapse transcripts"],
        "transcripts.collapsed": [.german: "%@ ausgeblendet", .english: "%@ hidden"],
        "transcripts.openFile": [.german: "Datei öffnen", .english: "Open File"],
        "transcripts.share": [.german: "Teilen…", .english: "Share…"],
        "artifacts.title": [.german: "Meeting Notes & Export", .english: "Meeting Notes & Export"],
        "artifacts.summary": [.german: "Zusammenfassung erstellen", .english: "Create Summary"],
        "artifacts.shareSummary": [.german: "Summary teilen…", .english: "Share Summary…"],
        "artifacts.kiExport": [.german: "Für KI-Agent exportieren", .english: "Export for AI Agent"],
        "artifacts.shareKI": [.german: "KI-Export teilen…", .english: "Share AI Export…"],
        "artifacts.collectKI": [.german: "KI-Exports sammeln", .english: "Collect AI Exports"],
        "artifacts.openExportFolder": [.german: "Export-Ordner öffnen", .english: "Open Export Folder"],
        "artifacts.exportFolder": [.german: "Sammelordner: %@", .english: "Collection folder: %@"],
        "artifacts.target": [.german: "Quelle", .english: "Source"],
        "artifacts.targetAll": [.german: "Alle Transkripte", .english: "All Transcripts"],
        "artifacts.targetOriginal": [.german: "Originalaufnahme", .english: "Original Recording"],
        "artifacts.targetUpdate": [.german: "Update %d", .english: "Update %d"],
        "consent.title": [.german: "Consent Reminder", .english: "Consent Reminder"],
        "consent.text": [.german: "Vor echten Meetings klar ansagen: „Ich lasse zur Nachbereitung ein Transkript/Meeting Notes erstellen.“ Keine heimlichen Aufnahmen.", .english: "Before real meetings, clearly say: “I use EchoPilot to create a transcript/meeting notes for follow-up.” No secret recordings."],

        "preview.combinedTimeline": [.german: "Kombinierte Timeline", .english: "Combined Timeline"],
        "preview.combinedHandover": [.german: "Kombinierter KI-Handover", .english: "Combined AI Handover"],
        "preview.timeline": [.german: "Timeline", .english: "Timeline"],
        "preview.kiHandover": [.german: "KI-Handover", .english: "AI Handover"],
        "preview.system": [.german: "Systemaudio", .english: "System Audio"],
        "preview.microphone": [.german: "Mikrofon", .english: "Microphone"],

        "status.ready": [.german: "Bereit. Vor echten Meetings Consent/Ansage nicht vergessen.", .english: "Ready. Remember consent/announcement before real meetings."],
        "status.notChecked": [.german: "Nicht geprüft", .english: "Not checked"],
        "processing.waiting": [.german: "Vorbereitung wartet auf Aufnahme.", .english: "Preparation is waiting for a recording."],
        "transcription.notStarted": [.german: "Transkription noch nicht gestartet.", .english: "Transcription not started yet."],
        "artifact.none": [.german: "Noch keine Meeting-Artefakte erstellt.", .english: "No meeting artifacts created yet."],
        "update.searching": [.german: "Suche nach Updates…", .english: "Checking for updates…"],
        "update.available": [.german: "Neue Version verfügbar: %@", .english: "New version available: %@"],
        "update.current": [.german: "EchoPilot ist aktuell (%@).", .english: "EchoPilot is up to date (%@)."],
        "update.failed": [.german: "Update-Check fehlgeschlagen: %@", .english: "Update check failed: %@"],

        "status.permissionsRequired": [.german: "Bitte zuerst Mikrofon und Screen/Systemaudio freigeben.", .english: "Please grant microphone and screen/system audio permissions first."],
        "status.dependenciesRequired": [.german: "Bitte zuerst FFmpeg installieren, dann erneut transkribieren.", .english: "Please install FFmpeg first, then transcribe again."],
        "status.homebrewInstallOpened": [.german: "Homebrew-Installation im Terminal geöffnet. Danach erneut prüfen.", .english: "Homebrew installer opened in Terminal. Check again afterwards."],
        "status.ffmpegInstallOpened": [.german: "FFmpeg-Installation im Terminal geöffnet. Danach erneut prüfen.", .english: "FFmpeg installer opened in Terminal. Check again afterwards."],
        "status.recordingStarted": [.german: "Recording läuft… Systemaudio + Mikrofon werden getrennt gespeichert.", .english: "Recording… system audio and microphone are saved as separate tracks."],
        "status.appendRecordingStarted": [.german: "Update-Aufnahme läuft für: %@", .english: "Update recording is running for: %@"],
        "status.startFailed": [.german: "Start fehlgeschlagen: %@", .english: "Start failed: %@"],
        "recording.errorStart": [.german: "Recording konnte nicht starten: %@. Prüfe zusätzlich zu Mikrofon auch Datenschutz → Screen & System Audio Recording für EchoPilot/Xcode.", .english: "Recording could not start: %@. In addition to microphone access, check Privacy & Security → Screen & System Audio Recording for EchoPilot/Xcode."],
        "recording.errorEmpty": [.german: "Aufnahme hatte keine Audio-Buffer und wurde verworfen. Prüfe Screen & System Audio Recording sowie Mikrofon-Berechtigung für genau die App, die du startest.", .english: "Recording had no audio buffers and was discarded. Check Screen & System Audio Recording and microphone permissions for the exact app you start."],
        "status.recordingSaved": [.german: "Recording gespeichert: %@", .english: "Recording saved: %@"],
        "status.noActiveRecording": [.german: "Keine aktive Aufnahme.", .english: "No active recording."],
        "status.stopFailed": [.german: "Stop fehlgeschlagen: %@", .english: "Stop failed: %@"],
        "status.newPrepared": [.german: "Neue Aufnahme vorbereitet.", .english: "New recording prepared."],
        "status.newArtifactHint": [.german: "Neue Aufnahme vorbereitet. Titel eintragen und Start Recording klicken.", .english: "New recording prepared. Enter a title and click Start Recording."],
        "status.appendPrepared": [.german: "Update-Aufnahme vorbereitet für: %@", .english: "Update recording prepared for: %@"],
        "status.appended": [.german: "Update %@ an %@ angehängt. Danach transkribieren, um die kombinierte Timeline zu aktualisieren.", .english: "Update %@ appended to %@. Transcribe afterwards to refresh the combined timeline."],
        "status.appendBusy": [.german: "Anhängen nicht möglich während Aufnahme/Verarbeitung/Transkription läuft.", .english: "Cannot append while recording, processing, or transcription is running."],
        "status.appendNoTarget": [.german: "Bitte zuerst ein bestehendes Meeting auswählen.", .english: "Select an existing meeting first."],
        "status.appendTargetMissing": [.german: "Ziel-Meeting für das Update wurde nicht gefunden.", .english: "The target meeting for this update was not found."],
        "status.appendFailed": [.german: "Update konnte nicht angehängt werden: %@", .english: "Update could not be appended: %@"],
        "status.deleteBusy": [.german: "Löschen nicht möglich während Aufnahme/Verarbeitung läuft.", .english: "Cannot delete while recording/processing is running."],
        "status.deleteNone": [.german: "Kein Meeting zum Löschen ausgewählt.", .english: "No meeting selected for deletion."],
        "status.deleted": [.german: "Meeting in den Papierkorb verschoben: %@", .english: "Meeting moved to Trash: %@"],
        "status.deleteFailed": [.german: "Meeting konnte nicht gelöscht werden: %@", .english: "Meeting could not be deleted: %@"],
        "status.meetingSelected": [.german: "Meeting ausgewählt: %@", .english: "Meeting selected: %@"],
        "status.metadataSaved": [.german: "Metadaten gespeichert.", .english: "Metadata saved."],
        "status.metadataFailed": [.german: "Metadaten konnten nicht gespeichert werden: %@", .english: "Metadata could not be saved: %@"],
        "status.suggestionPrepared": [.german: "Aufnahme für erkannten Call vorbereitet. Bitte Consent prüfen und Start Recording klicken.", .english: "Recording prepared for detected call. Please verify consent and click Start Recording."],
        "transcription.noRecording": [.german: "Keine Aufnahme vorhanden.", .english: "No recording available."],
        "transcription.started": [.german: "Transkription gestartet…", .english: "Transcription started…"],
        "transcription.finished": [.german: "Fertig: meeting-notes-input.md enthält jetzt Transkripte.", .english: "Done: meeting-notes-input.md now contains transcripts."],
        "transcription.cancelled": [.german: "Transkription abgebrochen.", .english: "Transcription cancelled."],
        "transcription.failed": [.german: "Transkription fehlgeschlagen: %@", .english: "Transcription failed: %@"],
        "transcription.cancelling": [.german: "Transkription wird abgebrochen…", .english: "Cancelling transcription…"],
        "transcription.previewEmpty": [.german: "Noch kein Transkript geladen. Nach der Transkription erscheint hier die Timeline.", .english: "No transcript loaded yet. The timeline will appear here after transcription."],
        "transcription.previewMissing": [.german: "Datei noch nicht vorhanden: %@", .english: "File does not exist yet: %@"],
        "transcription.previewTruncated": [.german: "… gekürzt für die Vorschau. Datei öffnen/teilen für den vollständigen Inhalt.", .english: "… truncated for preview. Open/share the file for the full content."],
        "transcription.progressStarted": [.german: "Transkription gestartet…", .english: "Transcription started…"],
        "transcription.part": [.german: "Transkribiere Teil %d/%d: %@", .english: "Transcribing part %d/%d: %@"],
        "transcription.progressWhisperStart": [.german: "Starte lokales Whisper (%@, Sprache: %@). Erster Lauf kann wegen Installation/Modelldownload dauern…", .english: "Starting local Whisper (%@, language: %@). First run can take a while because of setup/model download…"],
        "transcription.progressWhisperRunning": [.german: "Whisper läuft… %@", .english: "Whisper running… %@"],
        "transcription.progressFinished": [.german: "Transkription fertig: meeting-notes-input.md aktualisiert.", .english: "Transcription finished: meeting-notes-input.md updated."],
        "batch.none": [.german: "Keine nicht transkribierten Meetings gefunden.", .english: "No untranscribed meetings found."],
        "batch.started": [.german: "Batch-Transkription gestartet: %d Meetings.", .english: "Batch transcription started: %d meetings."],
        "batch.item": [.german: "Transkribiere %d/%d: %@", .english: "Transcribing %d/%d: %@"],
        "batch.finished": [.german: "Batch fertig: %d transkribiert, %d übersprungen.", .english: "Batch finished: %d transcribed, %d skipped."],
        "batch.failed": [.german: "Batch-Transkription fehlgeschlagen: %@", .english: "Batch transcription failed: %@"],
        "batch.cancelled": [.german: "Batch-Transkription abgebrochen.", .english: "Batch transcription cancelled."],
        "batch.busy": [.german: "Batch wartet: Aufnahme, Verarbeitung oder Transkription läuft.", .english: "Batch waiting: recording, processing, or transcription is running."],
        "batch.idleWaiting": [.german: "Idle-Autopilot aktiv: wartet auf %d Min. Leerlauf.", .english: "Idle autopilot active: waiting for %d min. idle."],
        "artifact.noMeeting": [.german: "Kein Meeting ausgewählt.", .english: "No meeting selected."],
        "artifact.summaryCreated": [.german: "Summary-Entwurf erstellt: %@", .english: "Summary draft created: %@"],
        "artifact.summaryFailed": [.german: "Summary fehlgeschlagen: %@", .english: "Summary failed: %@"],
        "artifact.exportCreated": [.german: "KI-Agent-Export erstellt: %@", .english: "AI-agent export created: %@"],
        "artifact.exportFailed": [.german: "Export fehlgeschlagen: %@", .english: "Export failed: %@"],
        "artifact.exportsCollected": [.german: "%d KI-Exports gesammelt in %@", .english: "%d AI exports collected in %@"],
        "artifact.exportsCollectFailed": [.german: "KI-Exports konnten nicht gesammelt werden: %@", .english: "AI exports could not be collected: %@"],
        "processing.started": [.german: "Vorbereitung gestartet…", .english: "Preparation started…"],
        "processing.finished": [.german: "Fertig: transcription-input vorbereitet. Transkription ist noch ausstehend.", .english: "Done: transcription-input prepared. Transcription is still pending."],
        "processing.readyForTranscription": [.german: "Vorbereitung fertig. Bereit für Transkription.", .english: "Preparation complete. Ready for transcription."],
        "processing.failed": [.german: "Vorbereitung fehlgeschlagen: %@", .english: "Preparation failed: %@"],
        "processing.copySystem": [.german: "Kopiere Systemaudio…", .english: "Copying system audio…"],
        "processing.copyMic": [.german: "Kopiere Mikrofonspur…", .english: "Copying microphone track…"],
        "processing.copyManifest": [.german: "Kopiere Manifest…", .english: "Copying manifest…"],
        "processing.writeHandoff": [.german: "Schreibe Handoff-Dateien…", .english: "Writing handoff files…"],
        "processing.progressFinished": [.german: "Vorbereitung fertig: transcription-input erstellt. Transkription separat starten.", .english: "Preparation complete: transcription-input created. Start transcription separately."],
        "permissionStatus.microphoneGrantedMessage": [.german: "Mikrofon freigegeben.", .english: "Microphone granted."],
        "permissionStatus.microphoneDeniedMessage": [.german: "Mikrofon nicht freigegeben. Bitte in den Systemeinstellungen prüfen.", .english: "Microphone not granted. Please check System Settings."],
        "permissionStatus.screenGrantedMessage": [.german: "Screen & System Audio Recording freigegeben.", .english: "Screen & System Audio Recording granted."],
        "permissionStatus.screenDeniedMessage": [.german: "Screen & System Audio Recording nicht freigegeben. Bitte in den Systemeinstellungen prüfen und EchoPilot neu starten, falls macOS das verlangt.", .english: "Screen & System Audio Recording not granted. Please check System Settings and restart EchoPilot if macOS requires it."],
    ]
}

struct UpdateInfo: Equatable {
    let version: String
    let name: String
    let releaseURL: URL
    let publishedAt: Date?
}

enum GitHubUpdateChecker {
    private struct LatestReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }

    static let releasesURL = URL(string: "https://github.com/csmo-it/echopilot/releases")!
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/csmo-it/echopilot/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func checkForUpdate() async throws -> UpdateInfo? {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.httpMethod = "GET"
        request.setValue("EchoPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            // No public release exists yet. That is fine for local/dev builds.
            return nil
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RuntimeError("GitHub update check failed.")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let latest = try decoder.decode(LatestReleaseResponse.self, from: data)
        let latestVersion = normalizedVersion(latest.tagName)
        guard isVersion(latestVersion, newerThan: currentVersion) else { return nil }

        return UpdateInfo(
            version: latestVersion,
            name: latest.name ?? "EchoPilot \(latestVersion)",
            releaseURL: latest.htmlURL,
            publishedAt: latest.publishedAt
        )
    }

    static func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(
            of: #"[0-9]+(\.[0-9]+){1,3}([-+][A-Za-z0-9.-]+)?"#,
            options: .regularExpression
        ) {
            return String(trimmed[range])
        }
        return trimmed.replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = versionComponents(candidate)
        let rhs = versionComponents(current)
        let maxCount = max(lhs.count, rhs.count)
        for index in 0..<maxCount {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left > right { return true }
            if left < right { return false }
        }
        return false
    }

    private static func versionComponents(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split(separator: ".")
            .map { part in
                let numericPrefix = part.prefix { $0.isNumber }
                return Int(numericPrefix) ?? 0
            }
    }
}

enum MeetingLibrary {
    private static let transcriptPreviewProbeBytes = 32 * 1024

    static var rootURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("EchoPilot", isDirectory: true)
    }

    static func loadMeetings(includeArchived: Bool = false) -> [MeetingRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("meeting-") }
            .compactMap { url -> MeetingRecord? in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
                let metadata = try? loadMetadata(from: url)
                let isArchived = metadata?.archived ?? false
                if isArchived && !includeArchived { return nil }
                let title = metadata?.title.isEmpty == false ? metadata!.title : url.lastPathComponent
                let inputDir = url.appendingPathComponent("transcription-input", isDirectory: true)
                let hasTranscript = transcriptLooksPresent(at: inputDir.appendingPathComponent("meeting-notes-input.md"))
                    || transcriptLooksPresent(at: inputDir.appendingPathComponent("combined-meeting-notes-input.md"))
                let segments = segmentDirectories(for: url)
                let pendingTranscriptCount = (hasTranscript ? 0 : 1) + segments.filter { !transcriptLooksPresent(at: $0.appendingPathComponent("transcription-input/meeting-notes-input.md")) }.count
                let hasSummary = fm.fileExists(atPath: url.appendingPathComponent("summary.md").path)
                return MeetingRecord(
                    id: url.path,
                    title: title,
                    url: url,
                    createdAt: createdAt,
                    hasTranscript: hasTranscript,
                    isFullyTranscribed: hasTranscript && pendingTranscriptCount == 0,
                    hasSummary: hasSummary,
                    isArchived: isArchived,
                    segmentCount: 1 + segments.count,
                    pendingTranscriptCount: pendingTranscriptCount
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func transcriptLooksPresent(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) > 0 else {
            return false
        }

        // Older builds used a content scan here, but reading every large
        // meeting-notes-input.md on every sidebar refresh makes the app feel
        // sticky after long meetings. Keep this probe intentionally tiny: the
        // exact badge is less important than a responsive meeting list.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: transcriptPreviewProbeBytes), !data.isEmpty else { return true }
        let prefix = String(decoding: data, as: UTF8.self)
        return prefix.contains("## Mic transcript")
            || prefix.contains("## System transcript")
            || prefix.contains("## Plain mic transcript")
            || prefix.contains("## Timestamped mic transcript")
            || prefix.contains("## Combined transcript source")
            || prefix.contains("# EchoPilot")
            || (values.fileSize ?? 0) > transcriptPreviewProbeBytes
    }

    static func segmentRoot(for sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("segments", isDirectory: true)
    }

    static func segmentDirectories(for sessionDir: URL) -> [URL] {
        let root = segmentRoot(for: sessionDir)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { $0.hasDirectoryPath }
            .sorted { left, right in
                let leftValues = try? left.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let rightValues = try? right.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let leftDate = leftValues?.creationDate ?? leftValues?.contentModificationDate ?? Date.distantPast
                let rightDate = rightValues?.creationDate ?? rightValues?.contentModificationDate ?? Date.distantPast
                if leftDate == rightDate { return left.lastPathComponent < right.lastPathComponent }
                return leftDate < rightDate
            }
    }

    static func untranscribedSessionDirectories(for meetingDir: URL) -> [URL] {
        let rootInput = meetingDir.appendingPathComponent("transcription-input/meeting-notes-input.md")
        var dirs: [URL] = transcriptLooksPresent(at: rootInput) ? [] : [meetingDir]
        dirs.append(contentsOf: segmentDirectories(for: meetingDir).filter { segmentDir in
            !transcriptLooksPresent(at: segmentDir.appendingPathComponent("transcription-input/meeting-notes-input.md"))
        })
        return dirs
    }

    static func appendSegment(from sessionDir: URL, to meetingDir: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: meetingDir.path) else {
            throw RuntimeError("Ziel-Meeting existiert nicht mehr: \(meetingDir.path)")
        }
        guard sessionDir.standardizedFileURL != meetingDir.standardizedFileURL else {
            throw RuntimeError("Dieses Meeting kann nicht an sich selbst angehängt werden.")
        }
        let root = segmentRoot(for: meetingDir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var destination = root.appendingPathComponent(sessionDir.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent("\(sessionDir.lastPathComponent)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        }
        try FileManager.default.moveItem(at: sessionDir, to: destination)
        return destination
    }

    static func rebuildCombinedTranscripts(for meetingDir: URL) throws -> (timeline: URL, handover: URL)? {
        let segments = segmentDirectories(for: meetingDir)
        guard !segments.isEmpty else { return nil }

        let sources = [meetingDir] + segments
        var timelineSections: [String] = []
        var handoverSections: [String] = []
        for (index, sourceDir) in sources.enumerated() {
            let label = index == 0 ? "Original" : "Update \(index)"
            let sourceName = sourceDir.lastPathComponent
            let inputDir = sourceDir.appendingPathComponent("transcription-input", isDirectory: true)
            let timelineURL = inputDir.appendingPathComponent("timeline.md")
            let notesURL = inputDir.appendingPathComponent("meeting-notes-input.md")
            let timeline = readExistingText(at: timelineURL) ?? "_Noch keine Timeline fuer diesen Teil vorhanden._"
            let notes = readExistingText(at: notesURL) ?? "_Noch kein KI-Handover fuer diesen Teil vorhanden._"
            timelineSections.append("""
            ## \(label) — \(sourceName)

            \(timeline)
            """)
            handoverSections.append("""
            ## \(label) — \(sourceName)

            \(notes)
            """)
        }

        let inputDir = meetingDir.appendingPathComponent("transcription-input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let timelineOut = inputDir.appendingPathComponent("combined-timeline.md")
        let handoverOut = inputDir.appendingPathComponent("combined-meeting-notes-input.md")
        let combinedTimeline = """
        # EchoPilot Combined Timeline

        Dieses Meeting besteht aus \(sources.count) Teilen. Die Originalaufnahmen und Einzeltranskripte bleiben in ihren jeweiligen Ordnern erhalten; diese Datei fuehrt sie als Update-Timeline zusammen.

        \(timelineSections.joined(separator: "\n\n---\n\n"))
        """
        let combinedHandover = """
        # Meeting Notes Input — Combined

        ## KI-agent output contract

        Werte alle folgenden Meeting-Teile als einen gemeinsamen Verlauf aus. Markiere Entscheidungen, offene Fragen und Action Items mit Evidenz aus dem jeweiligen Teil. Erfinde nichts; Unsicherheit ausdruecklich kennzeichnen.

        1. **Kurzfassung** — 5–10 concise German bullet points
        2. **Entscheidungen** — decision, context, source/speaker, evidence quote or timestamp
        3. **Offene Fragen** — question, context, source/speaker, evidence quote or timestamp
        4. **Action Items** — task, owner, due date, status, evidence quote or timestamp
        5. **Task-Vorschläge** — task title, risk, automation mode, next step
        6. **Approval Gates** — anything external/customer-facing/destructive that needs approval
        7. **Unklar / Daten fehlen** — contradictions, missing names, bad transcript spots

        ## Combined transcript source

        \(handoverSections.joined(separator: "\n\n---\n\n"))
        """
        try combinedTimeline.write(to: timelineOut, atomically: true, encoding: .utf8)
        try combinedHandover.write(to: handoverOut, atomically: true, encoding: .utf8)
        return (timelineOut, handoverOut)
    }

    private static func readExistingText(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url)
    }

    static func loadMetadata(from sessionDir: URL) throws -> MeetingMetadata? {
        let url = sessionDir.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MeetingMetadata.self, from: data)
    }

    static func saveMetadata(_ metadata: MeetingMetadata, to sessionDir: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: sessionDir.appendingPathComponent("metadata.json"), options: [.atomic])
    }

    static func trashMeeting(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimeError("Meeting-Ordner existiert nicht mehr: \(url.path)")
        }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
    }
}

enum MeetingArtifactGenerator {
    static var sharedExportFolder: URL {
        MeetingLibrary.rootURL.appendingPathComponent("AI Agent Exports", isDirectory: true)
    }

    private static func preferredTranscriptURL(for sessionDir: URL) -> URL {
        let combined = sessionDir.appendingPathComponent("transcription-input/combined-meeting-notes-input.md")
        if FileManager.default.fileExists(atPath: combined.path) {
            return combined
        }
        return sessionDir.appendingPathComponent("transcription-input/meeting-notes-input.md")
    }

    static func generateSummary(sessionDir: URL, metadata: MeetingMetadata) throws -> URL {
        return try generateSummary(
            sessionDir: sessionDir,
            metadata: metadata,
            transcriptURL: preferredTranscriptURL(for: sessionDir),
            outputURL: sessionDir.appendingPathComponent("summary.md")
        )
    }

    static func generateSummary(
        sessionDir: URL,
        metadata: MeetingMetadata,
        transcriptURL inputURL: URL,
        outputURL out: URL
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw RuntimeError("meeting-notes-input.md fehlt. Bitte erst transkribieren.")
        }
        let transcript = try String(contentsOf: inputURL)
        let excerpt = transcript
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(80)
            .joined(separator: "\n")

        let summary = """
        # Meeting Summary — \(metadata.title.isEmpty ? sessionDir.lastPathComponent : metadata.title)

        ## Metadata

        - **Titel:** \(metadata.title.isEmpty ? "—" : metadata.title)
        - **Teilnehmer:** \(metadata.participants.isEmpty ? "—" : metadata.participants)
        - **Kunde/Projekt:** \(metadata.customerProject.isEmpty ? "—" : metadata.customerProject)
        - **Aufzeichnungs-Hinweis:** EchoPilot-Aufnahmen sollen nur nach vorheriger Absprache mit den Teilnehmenden gestartet werden.

        ## Kurzüberblick

        _Lokaler Entwurf. Für die finale inhaltliche Zusammenfassung an einen KI-Agenten exportieren._

        ## Entscheidungen

        - [ ] Aus Transkript prüfen/ergänzen

        ## Action Items

        - [ ] Owner/Due Date aus Transkript prüfen/ergänzen

        ## Offene Fragen

        - [ ] Aus Transkript prüfen/ergänzen

        ## Transcript Preview

        ```text
        \(excerpt)
        ```
        """
        try summary.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func generateKIAgentExport(sessionDir: URL, metadata: MeetingMetadata) throws -> URL {
        return try generateKIAgentExport(
            sessionDir: sessionDir,
            metadata: metadata,
            transcriptURL: preferredTranscriptURL(for: sessionDir),
            outputURL: sessionDir.appendingPathComponent("ki-agent-export.md")
        )
    }

    static func generateKIAgentExport(
        sessionDir: URL,
        metadata: MeetingMetadata,
        transcriptURL inputURL: URL,
        outputURL out: URL
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw RuntimeError("meeting-notes-input.md fehlt. Bitte erst transkribieren.")
        }
        let transcript = try String(contentsOf: inputURL)
        let export = """
        # EchoPilot Export for KI-Agent

        ## Request / Output Contract

        Bitte werte dieses EchoPilot-Meeting aus und gib **alle** folgenden Abschnitte aus. Wenn keine belastbare Evidenz vorhanden ist, schreibe ausdrücklich `Keine im Transkript erkennbar` — Abschnitte nicht weglassen.

        1. **Kurzfassung** — 5–10 Bullet Points auf Deutsch
        2. **Entscheidungen** — Entscheidung, Kontext, wer/Quelle, Evidenz-Zitat oder Timestamp
        3. **Offene Fragen** — Frage, Kontext, wer/Quelle, Evidenz-Zitat oder Timestamp
        4. **Action Items** — Aufgabe, Owner, Due Date, Status, Evidenz-Zitat oder Timestamp
        5. **Task-Vorschläge** — Task-Titel, Risiko, Automation Mode, nächster Schritt
        6. **Approval Gates** — alles externe/customer-facing/destructive mit benötigter Freigabe
        7. **Unklar / Daten fehlen** — Widersprüche, fehlende Namen, schlechte Audio-/Transkriptstellen

        Wichtig: Keine Entscheidungen, offenen Fragen oder Action Items erfinden. Nur aus Transkript/Metadaten ableiten und Unsicherheit markieren.

        ## Metadata

        - **Titel:** \(metadata.title.isEmpty ? "—" : metadata.title)
        - **Teilnehmer:** \(metadata.participants.isEmpty ? "—" : metadata.participants)
        - **Kunde/Projekt:** \(metadata.customerProject.isEmpty ? "—" : metadata.customerProject)
        - **Aufzeichnungs-Hinweis:** EchoPilot-Aufnahmen sollen nur nach vorheriger Absprache mit den Teilnehmenden gestartet werden.
        - **Session:** \(sessionDir.lastPathComponent)

        ## Transcript / Source Material

        `timeline.md` is generated from timestamped `system.vtt` + `mic.vtt` and should be used as the primary source when available. It labels turns by track (`mic/Local speaker`, `system/Andere`) and sorts by timestamp. This is two-source timeline alignment, not full multi-speaker diarization.

        \(transcript)
        """
        try export.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func collectKIAgentExports(for meetings: [MeetingRecord]) throws -> (folder: URL, copied: Int) {
        let folder = sharedExportFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied = 0
        for meeting in meetings where meeting.hasTranscript {
            let metadata = (try? MeetingLibrary.loadMetadata(from: meeting.url)) ?? MeetingMetadata(
                title: meeting.title,
                participants: "",
                customerProject: "",
                consentConfirmed: false,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                archived: meeting.isArchived
            )
            let source = try generateKIAgentExport(sessionDir: meeting.url, metadata: metadata)
            let baseName = sanitizedFileName(
                metadata.title.isEmpty ? meeting.title : metadata.title,
                fallback: meeting.url.lastPathComponent
            )
            let sessionName = sanitizedFileName(meeting.url.lastPathComponent, fallback: UUID().uuidString)
            let destination = folder.appendingPathComponent("\(datePrefix(for: meeting.createdAt))-\(baseName)-\(sessionName)-ki-agent-export.md")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            copied += 1
        }
        return (folder, copied)
    }

    private static func datePrefix(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    private static func sanitizedFileName(_ value: String, fallback: String) -> String {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(filtered)
            .replacingOccurrences(of: #"[-\s]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return collapsed.isEmpty ? fallback : String(collapsed.prefix(80))
    }
}

@MainActor
final class MeetingCaptureViewModel: ObservableObject {
    @Published var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            EchoPilotRecordingState.isRecording = isRecording
            NSApp.dockTile.badgeLabel = isRecording ? "REC" : nil
            NSApp.dockTile.display()
            NotificationCenter.default.post(
                name: EchoPilotNotifications.recordingStateChanged,
                object: nil,
                userInfo: ["isRecording": isRecording]
            )
        }
    }
    @Published var isStarting = false
    @Published var status = L10n.text("status.ready")
    @Published var outputDir: URL?
    @Published var elapsed: TimeInterval = 0
    @Published var audioInputDevices: [AudioInputDevice] = AudioInputDevice.available()
    @Published var selectedAudioInputID: String? = nil {
        didSet { AppSettings.selectedAudioInputID = selectedAudioInputID }
    }
    @Published var isProcessing = false
    @Published var processingProgress = 0.0
    @Published var processingStatus = L10n.text("processing.waiting")
    @Published var transcriptionInputDir: URL?
    @Published var isTranscribing = false
    @Published var isBatchTranscribing = false
    @Published var transcriptionProgress = 0.0
    @Published var transcriptionStatus = L10n.text("transcription.notStarted")
    @Published var batchOpenCount = 0
    @Published var batchIdleEnabled = AppSettings.batchIdleEnabled {
        didSet { AppSettings.batchIdleEnabled = batchIdleEnabled }
    }
    @Published var batchIdleMinutes = AppSettings.batchIdleMinutes {
        didSet { AppSettings.batchIdleMinutes = batchIdleMinutes }
    }
    @Published var batchScheduleEnabled = AppSettings.batchScheduleEnabled {
        didSet { AppSettings.batchScheduleEnabled = batchScheduleEnabled }
    }
    @Published var batchScheduledTime = AppSettings.batchScheduledTime {
        didSet { AppSettings.batchScheduledTime = batchScheduledTime }
    }
    @Published var notesInputURL: URL?
    @Published var meetings: [MeetingRecord] = []
    @Published var showArchivedMeetings = false {
        didSet { refreshMeetings() }
    }
    @Published var selectedMeetingID: String?
    @Published var appendTargetMeetingID: String?
    @Published var appendTargetMeetingTitle: String?
    @Published var meetingTitle = ""
    @Published var participants = ""
    @Published var customerProject = ""
    @Published var consentConfirmed = false
    @Published var selectedMeetingArchived = false
    @Published var whisperModel = AppSettings.whisperModel {
        didSet { AppSettings.whisperModel = whisperModel }
    }
    @Published var whisperLanguage = AppSettings.whisperLanguage {
        didSet { AppSettings.whisperLanguage = whisperLanguage }
    }
    @Published var whisperModels: [WhisperModelInfo] = WhisperModelInfo.available()
    @Published var artifactStatus = L10n.text("artifact.none")
    @Published var artifactTargetID: String?
    @Published var summaryURL: URL?
    @Published var kiAgentExportURL: URL?
    @Published var transcriptPreviewKind: TranscriptPreviewKind = .timeline
    @Published var transcriptPreviewTitle = "Timeline"
    @Published var transcriptPreviewText = L10n.text("transcription.previewEmpty")
    @Published var transcriptPreviewExpanded = AppSettings.transcriptPreviewExpanded {
        didSet { AppSettings.transcriptPreviewExpanded = transcriptPreviewExpanded }
    }
    @Published var meetingSuggestion: MeetingSuggestion?
    @Published var meetingDeviceStatus = MeetingDeviceStatus()
    @Published var showPermissionsOverlay = false
    @Published var microphonePermissionGranted = false
    @Published var microphonePermissionStatus = L10n.text("status.notChecked")
    @Published var screenCapturePermissionGranted = false
    @Published var screenCapturePermissionStatus = L10n.text("status.notChecked")
    @Published var accessibilityPermissionGranted = false
    @Published var accessibilityPermissionStatus = L10n.text("status.notChecked")
    @Published var homebrewInstalled = false
    @Published var homebrewStatus = L10n.text("status.notChecked")
    @Published var ffmpegInstalled = false
    @Published var ffmpegStatus = L10n.text("status.notChecked")
    @Published var updateInfo: UpdateInfo?
    @Published var isCheckingForUpdates = false
    @Published var updateCheckStatus = ""

    var permissionsReady: Bool {
        microphonePermissionGranted && screenCapturePermissionGranted
    }

    var dependenciesReady: Bool {
        homebrewInstalled && ffmpegInstalled
    }

    var canStartRecording: Bool {
        permissionsReady && !isStarting && !isRecording
    }

    var startRecordingDisabledReason: String? {
        if isStarting { return L10n.text("disabled.recorderPreparing") }
        if isRecording { return L10n.text("disabled.recordingRunning") }
        if !permissionsReady { return L10n.text("disabled.permissionsRequired") }
        return nil
    }

    private let service = MeetingCaptureService()
    private var timer: Timer?
    private var detectorTimer: Timer?
    private var batchSchedulerTimer: Timer?
    private var startedAt: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var didNotifyForCurrentDetectedMeeting = false
    private let transcriptPreviewMaxBytes = 64 * 1024
    private var lastDisplayedElapsedSecond = -1
    private var lastIdleBatchAttempt: Date?

    var isAppendingRecording: Bool {
        appendTargetMeetingID != nil
    }

    var artifactTargets: [MeetingArtifactTarget] {
        guard let outputDir else { return [] }
        let segments = MeetingLibrary.segmentDirectories(for: outputDir)
        if segments.isEmpty {
            return [
                MeetingArtifactTarget(
                    id: "session:\(outputDir.path)",
                    title: L10n.text("artifacts.targetOriginal"),
                    sessionDir: outputDir,
                    transcriptURL: outputDir.appendingPathComponent("transcription-input/meeting-notes-input.md"),
                    summaryURL: outputDir.appendingPathComponent("summary.md"),
                    kiAgentExportURL: outputDir.appendingPathComponent("ki-agent-export.md"),
                    usesCombinedTranscript: false
                )
            ]
        }

        var targets = [
            MeetingArtifactTarget(
                id: "all:\(outputDir.path)",
                title: L10n.text("artifacts.targetAll"),
                sessionDir: outputDir,
                transcriptURL: outputDir.appendingPathComponent("transcription-input/combined-meeting-notes-input.md"),
                summaryURL: outputDir.appendingPathComponent("summary.md"),
                kiAgentExportURL: outputDir.appendingPathComponent("ki-agent-export.md"),
                usesCombinedTranscript: true
            ),
            MeetingArtifactTarget(
                id: "session:\(outputDir.path)",
                title: L10n.text("artifacts.targetOriginal"),
                sessionDir: outputDir,
                transcriptURL: outputDir.appendingPathComponent("transcription-input/meeting-notes-input.md"),
                summaryURL: outputDir.appendingPathComponent("summary-original.md"),
                kiAgentExportURL: outputDir.appendingPathComponent("ki-agent-export-original.md"),
                usesCombinedTranscript: false
            )
        ]
        targets.append(contentsOf: segments.enumerated().map { index, segment in
            MeetingArtifactTarget(
                id: "session:\(segment.path)",
                title: L10n.format("artifacts.targetUpdate", index + 1),
                sessionDir: segment,
                transcriptURL: segment.appendingPathComponent("transcription-input/meeting-notes-input.md"),
                summaryURL: segment.appendingPathComponent("summary.md"),
                kiAgentExportURL: segment.appendingPathComponent("ki-agent-export.md"),
                usesCombinedTranscript: false
            )
        })
        return targets
    }

    var selectedArtifactTarget: MeetingArtifactTarget? {
        let targets = artifactTargets
        guard !targets.isEmpty else { return nil }
        if let artifactTargetID, let selected = targets.first(where: { $0.id == artifactTargetID }) {
            return selected
        }
        return targets.first
    }

    var selectedArtifactSummaryURL: URL? {
        selectedArtifactTarget?.summaryURL
    }

    var selectedArtifactKIAgentExportURL: URL? {
        selectedArtifactTarget?.kiAgentExportURL
    }

    init() {
        refreshAudioInputs()
        refreshWhisperModels()
        refreshMeetings()
        prepareNewRecording()
        refreshPermissions(showOverlayIfNeeded: true)
        refreshDependencies(showOverlayIfNeeded: true)
        startMeetingDetector()
        startBatchScheduler()
        checkForUpdatesOnStartup()
    }

    func checkForUpdatesOnStartup() {
        checkForUpdates(showStatus: false)
    }

    func checkForUpdates(showStatus: Bool = true) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        if showStatus { updateCheckStatus = L10n.text("update.searching") }
        Task {
            do {
                let latest = try await GitHubUpdateChecker.checkForUpdate()
                if let latest, AppSettings.dismissedUpdateVersion != latest.version {
                    updateInfo = latest
                    updateCheckStatus = L10n.format("update.available", latest.version)
                } else if showStatus {
                    updateCheckStatus = L10n.format("update.current", GitHubUpdateChecker.currentVersion)
                }
            } catch {
                if showStatus {
                    updateCheckStatus = L10n.format("update.failed", error.localizedDescription)
                }
            }
            isCheckingForUpdates = false
        }
    }

    func openLatestRelease() {
        let url = updateInfo?.releaseURL ?? GitHubUpdateChecker.releasesURL
        NSWorkspace.shared.open(url)
    }

    func dismissUpdateInfo() {
        if let updateInfo {
            AppSettings.dismissedUpdateVersion = updateInfo.version
        }
        self.updateInfo = nil
    }

    func refreshPermissions(showOverlayIfNeeded: Bool = true) {
        microphonePermissionGranted = AppPermissions.isMicrophoneGranted
        microphonePermissionStatus = AppPermissions.microphoneStatusText
        screenCapturePermissionGranted = AppPermissions.isScreenCaptureGranted
        screenCapturePermissionStatus = AppPermissions.screenCaptureStatusText
        accessibilityPermissionGranted = AppPermissions.isAccessibilityTrusted
        accessibilityPermissionStatus = AppPermissions.accessibilityStatusText
        if permissionsReady && dependenciesReady {
            showPermissionsOverlay = false
        } else if showOverlayIfNeeded {
            showPermissionsOverlay = true
        }
    }

    func refreshDependencies(showOverlayIfNeeded: Bool = true) {
        if let path = AppDependencies.homebrewPath {
            homebrewInstalled = true
            homebrewStatus = L10n.format("dependencyStatus.installedAt", path)
        } else {
            homebrewInstalled = false
            homebrewStatus = L10n.text("dependencyStatus.missing")
        }
        if let path = AppDependencies.ffmpegPath {
            ffmpegInstalled = true
            ffmpegStatus = L10n.format("dependencyStatus.installedAt", path)
        } else {
            ffmpegInstalled = false
            ffmpegStatus = L10n.text("dependencyStatus.missing")
        }
        if permissionsReady && dependenciesReady {
            showPermissionsOverlay = false
        } else if showOverlayIfNeeded {
            showPermissionsOverlay = true
        }
    }

    func refreshLocalizedText() {
        refreshPermissions(showOverlayIfNeeded: false)
        refreshDependencies(showOverlayIfNeeded: false)
        if selectedMeetingID == nil && outputDir == nil && !isRecording && !isStarting {
            status = L10n.text("status.ready")
        }
        if !isProcessing && processingProgress == 0 {
            processingStatus = L10n.text("processing.waiting")
        }
        if !isTranscribing && transcriptionProgress == 0 {
            transcriptionStatus = L10n.text("transcription.notStarted")
        }
        if outputDir == nil && summaryURL == nil && kiAgentExportURL == nil {
            artifactStatus = L10n.text("artifact.none")
        }
        syncArtifactTargetSelection()
        if transcriptPreviewText == L10n.text("transcription.previewEmpty", language: .german) || transcriptPreviewText == L10n.text("transcription.previewEmpty", language: .english) {
            transcriptPreviewText = L10n.text("transcription.previewEmpty")
        } else if let outputDir, FileManager.default.fileExists(atPath: outputDir.path) {
            loadTranscriptPreview(transcriptPreviewKind)
        }
    }

    func requestMicrophonePermission() {
        let granted = AppPermissions.requestMicrophone()
        refreshPermissions(showOverlayIfNeeded: true)
        status = granted ? L10n.text("permissionStatus.microphoneGrantedMessage") : L10n.text("permissionStatus.microphoneDeniedMessage")
    }

    func requestScreenCapturePermission() {
        let granted = AppPermissions.requestScreenCapture()
        refreshPermissions(showOverlayIfNeeded: true)
        status = granted ? L10n.text("permissionStatus.screenGrantedMessage") : L10n.text("permissionStatus.screenDeniedMessage")
    }

    func openMicrophoneSettings() {
        AppPermissions.openMicrophoneSettings()
    }

    func openScreenCaptureSettings() {
        AppPermissions.openScreenCaptureSettings()
    }

    func openAccessibilitySettings() {
        AppPermissions.openAccessibilitySettings()
    }

    func installHomebrew() {
        AppDependencies.openHomebrewInstallTerminal()
        status = L10n.text("status.homebrewInstallOpened")
    }

    func installFFmpeg() {
        AppDependencies.openFFmpegInstallTerminal()
        status = L10n.text("status.ffmpegInstallOpened")
    }

    func start() {
        guard !isStarting, !isRecording else { return }
        refreshPermissions(showOverlayIfNeeded: false)
        guard permissionsReady else {
            showPermissionsOverlay = true
            status = L10n.text("status.permissionsRequired")
            return
        }
        isStarting = true
        Task {
            do {
                let session = try await service.start(microphoneDeviceID: selectedAudioInputID)
                startedAt = session.startedAt
                outputDir = session.outputDir
                selectedMeetingID = session.outputDir.path
                if let appendTargetMeetingTitle {
                    meetingTitle = L10n.format("meeting.updateTitle", appendTargetMeetingTitle)
                }
                saveCurrentMetadata()
                isRecording = true
                if let appendTargetMeetingTitle {
                    status = L10n.format("status.appendRecordingStarted", appendTargetMeetingTitle)
                } else {
                    status = L10n.text("status.recordingStarted")
                }
                meetingSuggestion = nil
                startTimer()
            } catch {
                status = L10n.format("status.startFailed", error.localizedDescription)
                appendTargetMeetingID = nil
                appendTargetMeetingTitle = nil
            }
            isStarting = false
        }
    }

    func stop() {
        Task {
            do {
                stopTimer()
                let session = try await service.stop()
                isRecording = false
                if let session {
                    outputDir = session.outputDir
                    status = L10n.format("status.recordingSaved", session.outputDir.path)
                    saveCurrentMetadata()
                    await postProcess(session: session)
                    do {
                        try finishAppendIfNeeded(session: session)
                    } catch {
                        appendTargetMeetingID = nil
                        appendTargetMeetingTitle = nil
                        status = L10n.format("status.appendFailed", error.localizedDescription)
                    }
                    refreshMeetings()
                } else {
                    status = L10n.text("status.noActiveRecording")
                }
            } catch {
                isRecording = false
                appendTargetMeetingID = nil
                appendTargetMeetingTitle = nil
                status = L10n.format("status.stopFailed", error.localizedDescription)
            }
        }
    }

    func appendRecordingToSelectedMeeting() {
        guard !isRecording, !isStarting, !isProcessing, !isTranscribing else {
            status = L10n.text("status.appendBusy")
            return
        }
        guard let selectedMeetingID, let meeting = meetings.first(where: { $0.id == selectedMeetingID }) else {
            status = L10n.text("status.appendNoTarget")
            return
        }
        appendTargetMeetingID = selectedMeetingID
        appendTargetMeetingTitle = meeting.title
        status = L10n.format("status.appendPrepared", meeting.title)
        start()
    }

    private func finishAppendIfNeeded(session: RecordingSession) throws {
        guard let targetID = appendTargetMeetingID else { return }
        let allMeetings = MeetingLibrary.loadMeetings(includeArchived: true)
        guard let target = allMeetings.first(where: { $0.id == targetID }) else {
            appendTargetMeetingID = nil
            appendTargetMeetingTitle = nil
            throw RuntimeError(L10n.text("status.appendTargetMissing"))
        }

        let movedSegment = try MeetingLibrary.appendSegment(from: session.outputDir, to: target.url)
        _ = try? MeetingLibrary.rebuildCombinedTranscripts(for: target.url)
        appendTargetMeetingID = nil
        appendTargetMeetingTitle = nil
        refreshMeetings()
        if let updated = MeetingLibrary.loadMeetings(includeArchived: true).first(where: { $0.id == target.id }) {
            selectMeeting(updated)
        } else {
            selectedMeetingID = target.id
            outputDir = target.url
        }
        status = L10n.format("status.appended", movedSegment.lastPathComponent, target.title)
        transcriptionStatus = L10n.text("transcription.notStarted")
    }

    func openOutputFolder() {
        guard let outputDir else { return }
        NSWorkspace.shared.open(outputDir)
    }

    func refreshAudioInputs() {
        let devices = AudioInputDevice.available()
        audioInputDevices = devices
        let persisted = AppSettings.selectedAudioInputID
        if let persisted, devices.contains(where: { $0.id == persisted }) {
            selectedAudioInputID = persisted
        } else if selectedAudioInputID == nil || !devices.contains(where: { $0.id == selectedAudioInputID }) {
            selectedAudioInputID = devices.first?.id
        }
    }

    func refreshWhisperModels() {
        whisperModels = WhisperModelInfo.available()
        let persisted = AppSettings.whisperModel
        if whisperModels.contains(where: { $0.id == persisted }) {
            whisperModel = persisted
        } else if !whisperModels.contains(where: { $0.id == whisperModel }) {
            whisperModel = whisperModels.first?.id ?? "turbo"
        }
        let persistedLanguage = AppSettings.whisperLanguage
        if ["de", "en", "auto"].contains(persistedLanguage) {
            whisperLanguage = persistedLanguage
        }
    }

    func openTranscriptionInputFolder() {
        guard let transcriptionInputDir else { return }
        NSWorkspace.shared.open(transcriptionInputDir)
    }

    func refreshMeetings() {
        meetings = MeetingLibrary.loadMeetings(includeArchived: showArchivedMeetings)
        batchOpenCount = untranscribedMeetings().count
        if let selectedMeetingID, !meetings.contains(where: { $0.id == selectedMeetingID }) {
            prepareNewRecording()
        }
    }

    func prepareNewRecording() {
        selectedMeetingID = nil
        appendTargetMeetingID = nil
        appendTargetMeetingTitle = nil
        outputDir = nil
        transcriptionInputDir = nil
        notesInputURL = nil
        summaryURL = nil
        kiAgentExportURL = nil
        artifactTargetID = nil
        transcriptPreviewKind = .timeline
        transcriptPreviewTitle = "Timeline"
        transcriptPreviewText = L10n.text("transcription.previewEmpty")
        meetingTitle = ""
        participants = ""
        customerProject = ""
        consentConfirmed = false
        selectedMeetingArchived = false
        transcriptionStatus = L10n.text("transcription.notStarted")
        artifactStatus = L10n.text("status.newArtifactHint")
        status = L10n.text("status.newPrepared")
        elapsed = 0
    }

    func deleteSelectedMeeting() {
        guard !isRecording, !isStarting, !isProcessing, !isTranscribing else {
            status = L10n.text("status.deleteBusy")
            return
        }
        guard let selectedMeetingID, let meeting = meetings.first(where: { $0.id == selectedMeetingID }) else {
            status = L10n.text("status.deleteNone")
            return
        }
        do {
            try MeetingLibrary.trashMeeting(at: meeting.url)
            prepareNewRecording()
            refreshMeetings()
            status = L10n.format("status.deleted", meeting.title)
        } catch {
            status = L10n.format("status.deleteFailed", error.localizedDescription)
        }
    }

    func selectMeeting(_ meeting: MeetingRecord) {
        selectedMeetingID = meeting.id
        appendTargetMeetingID = nil
        appendTargetMeetingTitle = nil
        outputDir = meeting.url
        transcriptionInputDir = meeting.url.appendingPathComponent("transcription-input", isDirectory: true)
        notesInputURL = transcriptionInputDir?.appendingPathComponent("meeting-notes-input.md")
        summaryURL = meeting.url.appendingPathComponent("summary.md")
        kiAgentExportURL = meeting.url.appendingPathComponent("ki-agent-export.md")
        artifactTargetID = nil
        syncArtifactTargetSelection()
        if let metadata = try? MeetingLibrary.loadMetadata(from: meeting.url) {
            meetingTitle = metadata.title
            participants = metadata.participants
            customerProject = metadata.customerProject
            consentConfirmed = metadata.consentConfirmed
            selectedMeetingArchived = metadata.archived
        } else {
            meetingTitle = ""
            participants = ""
            customerProject = ""
            consentConfirmed = false
            selectedMeetingArchived = false
        }
        let combinedTimeline = meeting.url.appendingPathComponent("transcription-input/combined-timeline.md")
        loadTranscriptPreview(FileManager.default.fileExists(atPath: combinedTimeline.path) ? .combinedTimeline : .timeline)
        status = L10n.format("status.meetingSelected", meeting.title)
    }

    func selectArtifactTarget(_ target: MeetingArtifactTarget) {
        artifactTargetID = target.id
        summaryURL = target.summaryURL
        kiAgentExportURL = target.kiAgentExportURL
    }

    private func syncArtifactTargetSelection() {
        let targets = artifactTargets
        guard !targets.isEmpty else {
            artifactTargetID = nil
            summaryURL = nil
            kiAgentExportURL = nil
            return
        }
        let selected = targets.first(where: { $0.id == artifactTargetID }) ?? targets.first!
        artifactTargetID = selected.id
        summaryURL = selected.summaryURL
        kiAgentExportURL = selected.kiAgentExportURL
    }

    func setArchiveForSelectedMeeting(_ archived: Bool) {
        guard let selectedMeetingID, let meeting = meetings.first(where: { $0.id == selectedMeetingID }) else { return }
        setArchive(archived, for: meeting)
    }

    func setArchive(_ archived: Bool, for meeting: MeetingRecord) {
        do {
            var metadata = (try? MeetingLibrary.loadMetadata(from: meeting.url)) ?? MeetingMetadata(
                title: meeting.title,
                participants: "",
                customerProject: "",
                consentConfirmed: false,
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            metadata.archived = archived
            metadata.updatedAt = ISO8601DateFormatter().string(from: Date())
            try MeetingLibrary.saveMetadata(metadata, to: meeting.url)
            if selectedMeetingID == meeting.id {
                selectedMeetingArchived = archived
            }
            let archiveStatus = L10n.format(archived ? "status.archived" : "status.unarchived", meeting.title)
            status = archiveStatus
            refreshMeetings()
            status = archiveStatus
        } catch {
            status = L10n.format("status.archiveFailed", error.localizedDescription)
        }
    }

    func transcriptURL(for kind: TranscriptPreviewKind) -> URL? {
        outputDir?.appendingPathComponent(kind.relativePath)
    }

    func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func loadTranscriptPreview(_ kind: TranscriptPreviewKind) {
        transcriptPreviewKind = kind
        transcriptPreviewTitle = kind.title(language: AppSettings.currentLanguage)
        guard let url = transcriptURL(for: kind), FileManager.default.fileExists(atPath: url.path) else {
            transcriptPreviewText = L10n.format("transcription.previewMissing", kind.title(language: AppSettings.currentLanguage))
            return
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = values.fileSize ?? 0
            let data = try readPrefix(url: url, maxBytes: transcriptPreviewMaxBytes)
            let text = String(decoding: data, as: UTF8.self)
            if fileSize > transcriptPreviewMaxBytes {
                transcriptPreviewText = text + "\n\n" + L10n.text("transcription.previewTruncated")
            } else {
                transcriptPreviewText = text
            }
        } catch {
            transcriptPreviewText = "Konnte \(kind.title) nicht laden: \(error.localizedDescription)"
        }
    }

    private func readPrefix(url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    func shareableURL(_ url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func saveCurrentMetadata(showStatus: Bool = true) {
        guard let outputDir else { return }
        let metadata = currentMetadata()
        do {
            try MeetingLibrary.saveMetadata(metadata, to: outputDir)
            refreshMeetings()
            if showStatus {
                status = L10n.text("status.metadataSaved")
            }
        } catch {
            status = L10n.format("status.metadataFailed", error.localizedDescription)
        }
    }

    func prepareSuggestedRecording() {
        let suggestion = meetingSuggestion
        prepareNewRecording()
        if let title = suggestedMeetingTitle(from: suggestion) {
            meetingTitle = title
            status = L10n.text("status.suggestionPrepared")
        }
        if let participantList = suggestion?.participants, !participantList.isEmpty {
            participants = participantList.joined(separator: ", ")
        }
        meetingSuggestion = nil
    }

    private func suggestedMeetingTitle(from suggestion: MeetingSuggestion?) -> String? {
        guard let suggestion else { return nil }
        if let title = suggestion.title, !title.isEmpty { return title }
        if suggestion.detail.contains(":") { return suggestion.detail }
        if suggestion.appName != "Meeting", suggestion.appName != "Meeting-App" { return suggestion.appName }
        return nil
    }


    func transcribeCurrentRecording() {
        refreshDependencies(showOverlayIfNeeded: false)
        guard ffmpegInstalled else {
            showPermissionsOverlay = true
            status = L10n.text("status.dependenciesRequired")
            return
        }
        guard let outputDir else {
            transcriptionStatus = L10n.text("transcription.noRecording")
            return
        }
        guard !isBatchTranscribing else {
            transcriptionStatus = L10n.text("batch.busy")
            return
        }
        transcriptionTask?.cancel()
        transcriptionTask = Task {
            isTranscribing = true
            transcriptionProgress = 0
            transcriptionStatus = L10n.text("transcription.started")
            do {
                saveCurrentMetadata()
                let notesURL = try await transcribeMeeting(at: outputDir, title: meetingTitle.isEmpty ? outputDir.lastPathComponent : meetingTitle)
                notesInputURL = notesURL
                transcriptionInputDir = notesURL.deletingLastPathComponent()
                transcriptionStatus = L10n.text("transcription.finished")
                loadTranscriptPreview(fileExists(outputDir.appendingPathComponent("transcription-input/combined-timeline.md")) ? .combinedTimeline : .timeline)
                refreshMeetings()
            } catch {
                if Task.isCancelled {
                    transcriptionStatus = L10n.text("transcription.cancelled")
                } else {
                    transcriptionStatus = L10n.format("transcription.failed", error.localizedDescription)
                }
            }
            isTranscribing = false
            transcriptionTask = nil
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionStatus = isBatchTranscribing ? L10n.text("batch.cancelled") : L10n.text("transcription.cancelling")
    }

    func startBatchTranscriptionManually() {
        startBatchTranscription(reason: "manual")
    }

    private func startBatchTranscription(reason: String) {
        refreshDependencies(showOverlayIfNeeded: false)
        guard ffmpegInstalled else {
            showPermissionsOverlay = true
            status = L10n.text("status.dependenciesRequired")
            return
        }
        guard !isRecording, !isStarting, !isProcessing, !isTranscribing else {
            transcriptionStatus = L10n.text("batch.busy")
            return
        }
        let queue = untranscribedMeetings()
        batchOpenCount = queue.count
        guard !queue.isEmpty else {
            transcriptionStatus = L10n.text("batch.none")
            return
        }

        transcriptionTask?.cancel()
        transcriptionTask = Task {
            isTranscribing = true
            isBatchTranscribing = true
            transcriptionProgress = 0
            transcriptionStatus = L10n.format("batch.started", queue.count)
            var completed = 0
            var skipped = 0

            for (index, meeting) in queue.enumerated() {
                if Task.isCancelled { break }
                if isRecording || isStarting {
                    skipped += queue.count - index
                    break
                }
                let current = index + 1
                transcriptionStatus = L10n.format("batch.item", current, queue.count, meeting.title)
                do {
                    let notesURL = try await transcribeMeeting(at: meeting.url, title: meeting.title) { [weak self] progress, status in
                        guard let self else { return }
                        let overall = (Double(index) + progress) / Double(queue.count)
                        self.transcriptionProgress = overall
                        self.transcriptionStatus = "\(L10n.format("batch.item", current, queue.count, meeting.title))\n\(status)"
                    }
                    completed += 1
                    if selectedMeetingID == meeting.id {
                        notesInputURL = notesURL
                        transcriptionInputDir = notesURL.deletingLastPathComponent()
                        loadTranscriptPreview(fileExists(meeting.url.appendingPathComponent("transcription-input/combined-timeline.md")) ? .combinedTimeline : .timeline)
                    }
                } catch {
                    if Task.isCancelled { break }
                    skipped += 1
                    transcriptionStatus = L10n.format("batch.failed", error.localizedDescription)
                }
                refreshMeetings()
            }

            if Task.isCancelled {
                transcriptionStatus = L10n.text("batch.cancelled")
            } else {
                transcriptionProgress = 1
                transcriptionStatus = L10n.format("batch.finished", completed, skipped)
            }
            isBatchTranscribing = false
            isTranscribing = false
            transcriptionTask = nil
            refreshMeetings()
            if reason != "manual", completed > 0 {
                status = transcriptionStatus
            }
        }
    }

    private func untranscribedMeetings() -> [MeetingRecord] {
        MeetingLibrary.loadMeetings(includeArchived: true)
            .filter { !$0.isFullyTranscribed }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func transcribeMeeting(
        at meetingDir: URL,
        title: String,
        progress: (@MainActor (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let pending = MeetingLibrary.untranscribedSessionDirectories(for: meetingDir)
        let sessionsToTranscribe = pending.isEmpty ? [meetingDir] : pending
        var latestNotesURL: URL?

        for (index, sessionDir) in sessionsToTranscribe.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let segmentLabel = sessionsToTranscribe.count > 1
                ? L10n.format("transcription.part", index + 1, sessionsToTranscribe.count, title)
                : title
            let notesURL = try await LocalTranscriber.transcribe(sessionDir: sessionDir, model: whisperModel, language: whisperLanguage) { [weak self] itemProgress, status in
                let overall = (Double(index) + itemProgress) / Double(sessionsToTranscribe.count)
                let combinedStatus = sessionsToTranscribe.count > 1 ? "\(segmentLabel)\n\(status)" : status
                if let progress {
                    progress(overall, combinedStatus)
                } else {
                    self?.transcriptionProgress = overall
                    self?.transcriptionStatus = combinedStatus
                }
            }
            latestNotesURL = notesURL
        }

        if let combined = try MeetingLibrary.rebuildCombinedTranscripts(for: meetingDir) {
            return combined.handover
        }
        guard let latestNotesURL else {
            throw RuntimeError("Transcription finished but no notes file was produced")
        }
        return latestNotesURL
    }

    private func startBatchScheduler() {
        batchSchedulerTimer?.invalidate()
        batchSchedulerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkBatchAutomation()
            }
        }
        Task { @MainActor in
            checkBatchAutomation()
        }
    }

    private func checkBatchAutomation() {
        batchOpenCount = untranscribedMeetings().count
        guard batchOpenCount > 0 else { return }
        guard !isRecording, !isStarting, !isProcessing, !isTranscribing else { return }
        guard !MeetingCallDetector.deviceStatus().inMeeting else { return }

        if batchIdleEnabled {
            let idleSeconds = SystemIdleMonitor.idleSeconds
            if idleSeconds >= TimeInterval(batchIdleMinutes * 60), shouldAttemptIdleBatch() {
                lastIdleBatchAttempt = Date()
                startBatchTranscription(reason: "idle")
                return
            }
            if idleSeconds < TimeInterval(batchIdleMinutes * 60) {
                transcriptionStatus = L10n.format("batch.idleWaiting", batchIdleMinutes)
            }
        }

        if batchScheduleEnabled, shouldRunScheduledBatchNow() {
            AppSettings.lastScheduledBatchRun = scheduledRunKey(for: Date())
            startBatchTranscription(reason: "schedule")
        }
    }

    private func shouldAttemptIdleBatch() -> Bool {
        guard let lastIdleBatchAttempt else { return true }
        return Date().timeIntervalSince(lastIdleBatchAttempt) > 1800
    }

    private func shouldRunScheduledBatchNow() -> Bool {
        let now = Date()
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute], from: now)
        let scheduleComponents = calendar.dateComponents([.hour, .minute], from: batchScheduledTime)
        let nowMinute = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
        let scheduleMinute = (scheduleComponents.hour ?? 0) * 60 + (scheduleComponents.minute ?? 0)
        return nowMinute >= scheduleMinute && AppSettings.lastScheduledBatchRun != scheduledRunKey(for: now)
    }

    private func scheduledRunKey(for date: Date) -> String {
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        let components = Calendar.current.dateComponents([.hour, .minute], from: batchScheduledTime)
        return "\(day.string(from: date))-\(components.hour ?? 0)-\(components.minute ?? 0)"
    }

    func generateSummary() {
        guard outputDir != nil else {
            artifactStatus = L10n.text("artifact.noMeeting")
            return
        }
        syncArtifactTargetSelection()
        guard let target = selectedArtifactTarget else {
            artifactStatus = L10n.text("artifact.noMeeting")
            return
        }
        saveCurrentMetadata()
        do {
            if target.usesCombinedTranscript, let outputDir {
                _ = try MeetingLibrary.rebuildCombinedTranscripts(for: outputDir)
            }
            let out = try MeetingArtifactGenerator.generateSummary(
                sessionDir: target.sessionDir,
                metadata: currentMetadata(),
                transcriptURL: target.transcriptURL,
                outputURL: target.summaryURL
            )
            summaryURL = out
            artifactStatus = L10n.format("artifact.summaryCreated", out.lastPathComponent)
            refreshMeetings()
        } catch {
            artifactStatus = L10n.format("artifact.summaryFailed", error.localizedDescription)
        }
    }

    func generateKIAgentExport() {
        guard outputDir != nil else {
            artifactStatus = L10n.text("artifact.noMeeting")
            return
        }
        syncArtifactTargetSelection()
        guard let target = selectedArtifactTarget else {
            artifactStatus = L10n.text("artifact.noMeeting")
            return
        }
        saveCurrentMetadata()
        do {
            if target.usesCombinedTranscript, let outputDir {
                _ = try MeetingLibrary.rebuildCombinedTranscripts(for: outputDir)
            }
            let out = try MeetingArtifactGenerator.generateKIAgentExport(
                sessionDir: target.sessionDir,
                metadata: currentMetadata(),
                transcriptURL: target.transcriptURL,
                outputURL: target.kiAgentExportURL
            )
            kiAgentExportURL = out
            artifactStatus = L10n.format("artifact.exportCreated", out.lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            refreshMeetings()
        } catch {
            artifactStatus = L10n.format("artifact.exportFailed", error.localizedDescription)
        }
    }

    func collectKIAgentExports() {
        do {
            let result = try MeetingArtifactGenerator.collectKIAgentExports(for: MeetingLibrary.loadMeetings(includeArchived: true))
            artifactStatus = L10n.format("artifact.exportsCollected", result.copied, result.folder.path)
            NSWorkspace.shared.open(result.folder)
        } catch {
            artifactStatus = L10n.format("artifact.exportsCollectFailed", error.localizedDescription)
        }
    }

    func openKIAgentExportFolder() {
        let folder = MeetingArtifactGenerator.sharedExportFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func postProcess(session: RecordingSession) async {
        isProcessing = true
        processingProgress = 0
        processingStatus = L10n.text("processing.started")
        do {
            let result = try await PostProcessor.prepareTranscriptionInput(for: session) { [weak self] progress, status in
                self?.processingProgress = progress
                self?.processingStatus = status
                self?.status = status
            }
            transcriptionInputDir = result.inputDir
            processingStatus = L10n.text("processing.finished")
            status = L10n.text("processing.readyForTranscription")
            notesInputURL = result.notesInputURL
        } catch {
            processingStatus = L10n.format("processing.failed", error.localizedDescription)
            status = processingStatus
        }
        isProcessing = false
    }

    private func currentMetadata() -> MeetingMetadata {
        MeetingMetadata(
            title: meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            participants: participants.trimmingCharacters(in: .whitespacesAndNewlines),
            customerProject: customerProject.trimmingCharacters(in: .whitespacesAndNewlines),
            consentConfirmed: consentConfirmed,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            archived: selectedMeetingArchived
        )
    }

    private func startTimer() {
        timer?.invalidate()
        lastDisplayedElapsedSecond = -1
        refreshElapsed()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshElapsed()
            }
        }
    }

    private func startMeetingDetector() {
        detectorTimer?.invalidate()
        Task { @MainActor in
            await checkMeetingSuggestion()
        }
        detectorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkMeetingSuggestion()
            }
        }
    }

    private func checkMeetingSuggestion() async {
        guard !isRecording, !isStarting else {
            meetingDeviceStatus = MeetingDeviceStatus()
            didNotifyForCurrentDetectedMeeting = false
            return
        }
        let deviceStatus = MeetingCallDetector.deviceStatus()
        if meetingDeviceStatus != deviceStatus {
            meetingDeviceStatus = deviceStatus
        }
        if !deviceStatus.inMeeting {
            meetingSuggestion = nil
            didNotifyForCurrentDetectedMeeting = false
            return
        }
        if meetingSuggestion != nil {
            maybeNotifyMeetingDetected(detail: meetingSuggestion?.detail ?? deviceStatus.summary())
            return
        }
        if let suggestion = await MeetingCallDetector.detectMeetingContext() {
            meetingSuggestion = suggestion
            maybeNotifyMeetingDetected(detail: suggestion.detail)
        } else {
            maybeNotifyMeetingDetected(detail: deviceStatus.summary())
        }
    }

    private func maybeNotifyMeetingDetected(detail: String) {
        guard !didNotifyForCurrentDetectedMeeting, isAppMinimizedOrHidden() else { return }
        didNotifyForCurrentDetectedMeeting = true
        EchoPilotUserNotifier.notifyMeetingDetected(detail: detail)
    }

    private func isAppMinimizedOrHidden() -> Bool {
        if NSApp.isHidden { return true }
        let appWindows = NSApp.windows.filter { $0.canBecomeKey || $0.title.contains("EchoPilot") }
        guard !appWindows.isEmpty else { return true }
        return !appWindows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshElapsed() {
        if let startedAt {
            let currentElapsed = Date().timeIntervalSince(startedAt)
            let elapsedSecond = Int(currentElapsed)
            if elapsedSecond != lastDisplayedElapsedSecond {
                lastDisplayedElapsedSecond = elapsedSecond
                elapsed = TimeInterval(elapsedSecond)
            }
        }
    }

    func liveLevel(for track: RecordingTrackKind) -> Float {
        let stats = service.stats()
        switch track {
        case .system: return stats.system.level
        case .microphone: return stats.mic.level
        }
    }
}

enum RecordingTrackKind {
    case system
    case microphone
}

struct LevelMeterView: View {
    let title: String
    let isActive: Bool
    let levelProvider: () -> Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(isActive ? "live" : "idle")
                    .font(.caption2.monospaced())
                    .foregroundStyle(isActive ? .green : .secondary)
            }
            AppKitLevelMeterView(isActive: isActive, levelProvider: levelProvider)
            .frame(height: 14)
        }
    }
}

struct AppKitLevelMeterView: NSViewRepresentable {
    let isActive: Bool
    let levelProvider: () -> Float

    func makeNSView(context: Context) -> LevelMeterNSView {
        let view = LevelMeterNSView()
        view.levelProvider = levelProvider
        view.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: LevelMeterNSView, context: Context) {
        nsView.levelProvider = levelProvider
        nsView.setActive(isActive)
    }
}

final class LevelMeterNSView: NSView {
    var levelProvider: (() -> Float)?

    private let backgroundLayer = CALayer()
    private let fillLayer = CALayer()
    private var timer: Timer?
    private var currentLevel: Float = 0
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        backgroundLayer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.14).cgColor
        fillLayer.backgroundColor = NSColor.systemGreen.cgColor
        layer?.addSublayer(backgroundLayer)
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopTimer()
    }

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = 6
        fillLayer.cornerRadius = 6
        render(level: currentLevel)
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            startTimer()
        } else {
            stopTimer()
            render(level: 0)
        }
    }

    private func startTimer() {
        stopTimer()
        refreshLevel()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.refreshLevel()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshLevel() {
        let rawLevel = levelProvider?() ?? 0
        let clamped = max(0, min(1, rawLevel))
        guard abs(clamped - currentLevel) >= 0.003 else { return }
        render(level: clamped)
    }

    private func render(level: Float) {
        currentLevel = level
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = color(for: level).cgColor
        fillLayer.frame = NSRect(
            x: 0,
            y: 0,
            width: level > 0 ? max(2, bounds.width * CGFloat(level)) : 0,
            height: bounds.height
        )
        CATransaction.commit()
    }

    private func color(for level: Float) -> NSColor {
        switch level {
        case 0..<0.68: return .systemGreen
        case 0.68..<0.92: return .systemYellow
        default: return .systemRed
        }
    }
}

struct LegacyDashboardView: View {
    @StateObject private var vm = MeetingCaptureViewModel()
    @AppStorage(AppSettings.preferredUILanguageKey) private var preferredUILanguage = AppLanguagePreference.system.rawValue

    private var language: AppLanguage {
        AppLanguagePreference(rawValue: preferredUILanguage)?.resolvedLanguage ?? .english
    }

    private func text(_ key: String) -> String {
        L10n.text(key, language: language)
    }

    private func formatted(_ key: String, _ args: CVarArg...) -> String {
        String(format: L10n.text(key, language: language), arguments: args)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                meetingsSidebar
                Divider()
                mainPanel
            }
            .frame(minWidth: 1040, minHeight: 720)
            .blur(radius: vm.showPermissionsOverlay ? 2 : 0)
            .disabled(vm.showPermissionsOverlay)

            if vm.showPermissionsOverlay {
                permissionsOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onAppear {
            EchoPilotWindowController.shared.attachToExistingWindows()
            vm.refreshPermissions(showOverlayIfNeeded: true)
            vm.refreshDependencies(showOverlayIfNeeded: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.startRecordingRequested)) { _ in
            vm.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.stopRecordingRequested)) { _ in
            vm.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.checkUpdatesRequested)) { _ in
            EchoPilotWindowController.shared.showApp()
            vm.checkForUpdates(showStatus: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.checkPermissionsRequested)) { _ in
            EchoPilotWindowController.shared.showApp()
            vm.refreshPermissions(showOverlayIfNeeded: true)
            vm.refreshDependencies(showOverlayIfNeeded: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.languageChanged)) { _ in
            vm.refreshLocalizedText()
        }
    }

    private var permissionsOverlay: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text("permissions.title"))
                            .font(.title2.bold())
                        Text(text("permissions.intro"))
                            .foregroundStyle(.secondary)
                    }
                }

                permissionRow(
                    title: text("permissions.microphone"),
                    status: vm.microphonePermissionStatus,
                    granted: vm.microphonePermissionGranted,
                    explanation: text("permissions.microphone.explanation"),
                    requestTitle: text("permissions.microphone.request"),
                    requestAction: vm.requestMicrophonePermission,
                    settingsAction: vm.openMicrophoneSettings
                )

                permissionRow(
                    title: text("permissions.screen"),
                    status: vm.screenCapturePermissionStatus,
                    granted: vm.screenCapturePermissionGranted,
                    explanation: text("permissions.screen.explanation"),
                    requestTitle: text("permissions.screen.request"),
                    requestAction: vm.requestScreenCapturePermission,
                    settingsAction: vm.openScreenCaptureSettings
                )

                dependencyRow(
                    title: text("dependencies.homebrew"),
                    status: vm.homebrewStatus,
                    installed: vm.homebrewInstalled,
                    explanation: text("dependencies.homebrew.explanation"),
                    installTitle: text("dependencies.homebrew.install"),
                    installAction: vm.installHomebrew
                )

                dependencyRow(
                    title: text("dependencies.ffmpeg"),
                    status: vm.ffmpegStatus,
                    installed: vm.ffmpegInstalled,
                    explanation: text("dependencies.ffmpeg.explanation"),
                    installTitle: text("dependencies.ffmpeg.install"),
                    installAction: vm.installFFmpeg
                )

                Divider()

                HStack {
                    Button(text("permissions.recheck")) {
                        vm.refreshPermissions(showOverlayIfNeeded: true)
                        vm.refreshDependencies(showOverlayIfNeeded: true)
                    }
                    Button(text("permissions.microphoneSettings")) { vm.openMicrophoneSettings() }
                    Button(text("permissions.systemAudioSettings")) { vm.openScreenCaptureSettings() }
                    Spacer()
                    Button(text("permissions.later")) { vm.showPermissionsOverlay = false }
                    Button(text("permissions.done")) {
                        vm.refreshPermissions(showOverlayIfNeeded: true)
                        vm.refreshDependencies(showOverlayIfNeeded: true)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!vm.permissionsReady || !vm.dependenciesReady)
                }

                if !vm.permissionsReady || !vm.dependenciesReady {
                    Text(text("permissions.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(width: 720)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 24)
        }
    }

    private func permissionRow(
        title: String,
        status: String,
        granted: Bool,
        explanation: String,
        requestTitle: String,
        requestAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(granted ? Color.green.opacity(0.16) : Color.orange.opacity(0.16), in: Capsule())
                }
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(requestTitle, action: requestAction)
                .disabled(granted)
            Button(text("permissions.settings"), action: settingsAction)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func dependencyRow(
        title: String,
        status: String,
        installed: Bool,
        explanation: String,
        installTitle: String,
        installAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: installed ? "checkmark.circle.fill" : "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(installed ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(installed ? Color.green.opacity(0.16) : Color.orange.opacity(0.16), in: Capsule())
                }
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button(installTitle, action: installAction)
                .disabled(installed || (title == text("dependencies.ffmpeg") && !vm.homebrewInstalled))
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var meetingsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(text("sidebar.meetings"), systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Button { vm.prepareNewRecording() } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .help(text("sidebar.new.help"))
                .buttonStyle(.borderless)
                Button { vm.refreshMeetings() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Toggle(text("sidebar.showArchived"), isOn: $vm.showArchivedMeetings)
                .toggleStyle(.checkbox)
                .font(.caption)

            List(selection: Binding(
                get: { vm.selectedMeetingID },
                set: { id in
                    guard let id else {
                        vm.prepareNewRecording()
                        return
                    }
                    guard let meeting = vm.meetings.first(where: { $0.id == id }) else { return }
                    vm.selectMeeting(meeting)
                }
            )) {
                ForEach(vm.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(meeting.title)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            meetingTranscriptBadge(meeting)
                        }
                        Text(meeting.subtitle(language: language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(Optional(meeting.id))
                    .contextMenu {
                        Button(role: .destructive) {
                            vm.selectedMeetingID = meeting.id
                            vm.deleteSelectedMeeting()
                        } label: {
                            Label(text("meeting.delete"), systemImage: "trash")
                        }
                        Divider()
                        Button {
                            vm.setArchive(!meeting.isArchived, for: meeting)
                        } label: {
                            Label(text(meeting.isArchived ? "meeting.unarchive" : "meeting.archive"), systemImage: meeting.isArchived ? "tray.and.arrow.up" : "archivebox")
                        }
                    }
                }
            }
            .overlay {
                if vm.meetings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(text("sidebar.empty.title"))
                            .font(.headline)
                        Text(text("sidebar.empty.subtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !vm.showArchivedMeetings {
                            Text(text("sidebar.emptyArchiveHidden"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding()
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func meetingTranscriptBadge(_ meeting: MeetingRecord) -> some View {
        let isPending = meeting.pendingTranscriptCount > 0
        let systemName = meeting.isFullyTranscribed ? "checkmark.circle.fill" : (isPending ? "exclamationmark.circle.fill" : "circle.dashed")
        let color: Color = meeting.isFullyTranscribed ? .green : (isPending ? .orange : .secondary)
        let help = meeting.isFullyTranscribed
            ? text("meeting.transcribed")
            : (isPending ? formatted("meeting.pendingTranscripts", meeting.pendingTranscriptCount) : text("meeting.notTranscribed"))
        return Image(systemName: systemName)
            .foregroundStyle(color)
            .help(help)
    }

    private var mainPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                updateBanner
                meetingDetectionBox
                controlsBox
                metadataBox
                levelMeters
                inputAndBackendBox
                transcriptionProgressBox
                transcriptPreviewBox
                artifactBox
                statusBox
                consentBox
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("EchoPilot")
                    .font(.largeTitle.bold())
                Text(text("app.subtitle"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            recordingBadge
        }
    }

    private var metadataBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text("meeting.title"), systemImage: "text.badge.checkmark")
                .font(.headline)
            TextField(text("meeting.field.title"), text: $vm.meetingTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { vm.saveCurrentMetadata() }
                .onChange(of: vm.meetingTitle) { _ in vm.saveCurrentMetadata(showStatus: false) }
            TextField(text("meeting.field.participants"), text: $vm.participants)
                .textFieldStyle(.roundedBorder)
                .onSubmit { vm.saveCurrentMetadata() }
                .onChange(of: vm.participants) { _ in vm.saveCurrentMetadata(showStatus: false) }
            TextField(text("meeting.field.customerProject"), text: $vm.customerProject)
                .textFieldStyle(.roundedBorder)
                .onSubmit { vm.saveCurrentMetadata() }
                .onChange(of: vm.customerProject) { _ in vm.saveCurrentMetadata(showStatus: false) }
            Label("Aufzeichnung nur nach vorheriger Absprache starten.", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)
            if vm.outputDir == nil {
                Text(text("meeting.newHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var inputAndBackendBox: some View {
        HStack(alignment: .top, spacing: 14) {
            inputDevicePicker
            transcriptionSettings
        }
    }

    private var inputDevicePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text("input.title"), systemImage: "mic")
                .font(.headline)
            Picker(text("input.microphone"), selection: Binding(
                get: { vm.selectedAudioInputID ?? "" },
                set: { vm.selectedAudioInputID = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(vm.audioInputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(vm.isRecording)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptionSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text("transcription.title"), systemImage: "gearshape")
                .font(.headline)
            Picker(text("transcription.model"), selection: $vm.whisperModel) {
                ForEach(vm.whisperModels) { model in
                    Text(model.label(language: language)).tag(model.id)
                }
            }
            Picker(text("transcription.language"), selection: $vm.whisperLanguage) {
                Text(text("transcription.german")).tag("de")
                Text(text("transcription.english")).tag("en")
                Text(text("transcription.auto")).tag("auto")
            }
            Text(installedModelSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 10) {
                Button(text("batch.transcribeAll")) { vm.startBatchTranscriptionManually() }
                    .disabled(vm.batchOpenCount == 0 || vm.isRecording || vm.isProcessing || vm.isTranscribing)
                if vm.isBatchTranscribing {
                    Button(text("batch.cancel")) { vm.cancelTranscription() }
                }
                Text(formatted("batch.openCount", vm.batchOpenCount))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Toggle(text("batch.autoIdle"), isOn: $vm.batchIdleEnabled)
                .toggleStyle(.checkbox)
            Stepper(
                formatted("batch.idleMinutes", vm.batchIdleMinutes),
                value: $vm.batchIdleMinutes,
                in: 2...120,
                step: 5
            )
            .disabled(!vm.batchIdleEnabled)
            HStack {
                Toggle(text("batch.schedule"), isOn: $vm.batchScheduleEnabled)
                    .toggleStyle(.checkbox)
                DatePicker("", selection: $vm.batchScheduledTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .disabled(!vm.batchScheduleEnabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var controlsBox: some View {
        HStack(spacing: 12) {
            Button(action: vm.isRecording ? vm.stop : vm.start) {
                Label(recordButtonTitle, systemImage: vm.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(minWidth: 180)
            }
            .keyboardShortcut(.space, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(vm.isRecording ? .red : .accentColor)
            .disabled(vm.isStarting)

            Button(text("button.newRecording")) { vm.prepareNewRecording() }
                .disabled(vm.isRecording || vm.isStarting)

            Button(text("button.appendUpdate")) { vm.appendRecordingToSelectedMeeting() }
                .disabled(vm.selectedMeetingID == nil || vm.isRecording || vm.isStarting || vm.isProcessing || vm.isTranscribing)

            Button(text("button.transcribe")) { vm.transcribeCurrentRecording() }
                .disabled(vm.outputDir == nil || vm.isRecording || vm.isProcessing || vm.isTranscribing)

            if vm.isTranscribing {
                Button(text("button.cancel")) { vm.cancelTranscription() }
            }

            Spacer()
            secondaryActionsMenu
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var secondaryActionsMenu: some View {
        Menu {
            Button(text("actions.checkPermissions")) {
                vm.refreshPermissions(showOverlayIfNeeded: true)
                vm.refreshDependencies(showOverlayIfNeeded: true)
            }
                .disabled(vm.isRecording || vm.isStarting)
            Button(text("actions.reloadMicrophones")) { vm.refreshAudioInputs() }
                .disabled(vm.isRecording)
            Button(text("actions.checkWhisperModels")) { vm.refreshWhisperModels() }
            Button(text("actions.checkUpdates")) { vm.checkForUpdates(showStatus: true) }
                .disabled(vm.isCheckingForUpdates)
            Divider()
            Button(text("actions.openOutput")) { vm.openOutputFolder() }
                .disabled(vm.outputDir == nil)
            Button(text("actions.openTranscriptionInput")) { vm.openTranscriptionInputFolder() }
                .disabled(vm.transcriptionInputDir == nil)
            Divider()
            Button(text("actions.saveMetadata")) { vm.saveCurrentMetadata() }
                .disabled(vm.outputDir == nil)
            Button(text("button.appendUpdate")) { vm.appendRecordingToSelectedMeeting() }
                .disabled(vm.selectedMeetingID == nil || vm.isRecording || vm.isStarting || vm.isProcessing || vm.isTranscribing)
            Button(text(vm.selectedMeetingArchived ? "meeting.unarchive" : "meeting.archive")) {
                vm.setArchiveForSelectedMeeting(!vm.selectedMeetingArchived)
            }
            .disabled(vm.selectedMeetingID == nil || vm.isRecording || vm.isStarting)
            Button(text("meeting.delete"), role: .destructive) { vm.deleteSelectedMeeting() }
                .disabled(vm.selectedMeetingID == nil || vm.isRecording || vm.isStarting || vm.isProcessing || vm.isTranscribing)
        } label: {
            Label(text("actions.more"), systemImage: "ellipsis.circle")
        }
        .buttonStyle(.bordered)
    }

    private var meetingDetectionBox: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(text("meetingDetection.title"), systemImage: vm.meetingDeviceStatus.inMeeting ? "video.badge.checkmark" : "video.slash")
                .font(.headline)
                .foregroundStyle(vm.meetingDeviceStatus.inMeeting ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.meetingDeviceStatus.inMeeting ? text("meetingDetection.inMeeting") : text("meetingDetection.notInMeeting"))
                    .font(.subheadline.weight(.semibold))
                Text(vm.meetingDeviceStatus.summary(language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if vm.meetingDeviceStatus.inMeeting && !vm.isRecording && !vm.isStarting {
                Button(text("suggestion.prepare")) { vm.prepareSuggestedRecording() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background((vm.meetingDeviceStatus.inMeeting ? Color.green : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var updateBanner: some View {
        Group {
            if let updateInfo = vm.updateInfo {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(text("update.title"))
                            .font(.headline)
                        Text(formatted("update.versions", GitHubUpdateChecker.currentVersion, updateInfo.version))
                            .foregroundStyle(.secondary)
                        Text(updateInfo.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(text("update.open")) { vm.openLatestRelease() }
                        .buttonStyle(.borderedProminent)
                    Button(text("button.dismiss")) { vm.dismissUpdateInfo() }
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            } else if !vm.updateCheckStatus.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: vm.isCheckingForUpdates ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text(vm.updateCheckStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private var recordButtonTitle: String {
        if vm.isRecording { return text("button.stopRecording") }
        if vm.isStarting { return text("button.starting") }
        return text("button.startRecording")
    }

    private var installedModelSummary: String {
        let installed = vm.whisperModels.filter(\.installed).map(\.id)
        if installed.isEmpty { return text("transcription.models.none") }
        return formatted("transcription.models.installed", installed.joined(separator: ", "))
    }

    private var levelMeters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text("levels.title"), systemImage: "waveform")
                .font(.headline)
            LevelMeterView(title: text("levels.system"), isActive: vm.isRecording) {
                vm.liveLevel(for: .system)
            }
            LevelMeterView(title: text("levels.microphone"), isActive: vm.isRecording) {
                vm.liveLevel(for: .microphone)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptionProgressBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text("transcript.statusTitle"), systemImage: "text.bubble")
                .font(.headline)
            if vm.isTranscribing {
                ProgressView(value: vm.transcriptionProgress)
                    .progressViewStyle(.linear)
            }
            Text(vm.transcriptionStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptPreviewBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    vm.transcriptPreviewExpanded.toggle()
                } label: {
                    Label(
                        text("transcripts.title"),
                        systemImage: vm.transcriptPreviewExpanded ? "chevron.down" : "chevron.right"
                    )
                    .font(.headline)
                }
                .buttonStyle(.plain)
                .help(text(vm.transcriptPreviewExpanded ? "transcripts.hide" : "transcripts.show"))
                Image(systemName: "text.alignleft")
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.transcriptPreviewExpanded {
                    transcriptPreviewSelector
                }
            }

            if vm.transcriptPreviewExpanded {
                ScrollView {
                    Text(vm.transcriptPreviewText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(minHeight: 180, maxHeight: 320)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(formatted("transcripts.collapsed", vm.transcriptPreviewKind.title(language: language)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if vm.transcriptPreviewExpanded {
                HStack {
                    if let url = vm.transcriptURL(for: vm.transcriptPreviewKind) {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(text("transcripts.openFile")) { NSWorkspace.shared.open(url) }
                            .disabled(!vm.fileExists(url))
                        Button(text("transcripts.share")) { shareFile(url) }
                            .disabled(!vm.fileExists(url))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptPreviewSelector: some View {
        Menu {
            ForEach(TranscriptPreviewKind.allCases) { kind in
                Button {
                    vm.loadTranscriptPreview(kind)
                } label: {
                    if kind == vm.transcriptPreviewKind {
                        Label(kind.title(language: language), systemImage: "checkmark")
                    } else {
                        Text(kind.title(language: language))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(vm.transcriptPreviewKind.title(language: language))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: 210, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help(text("transcripts.view"))
    }

    private var artifactBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text("artifacts.title"), systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            HStack(spacing: 10) {
                Label(text("artifacts.target"), systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                artifactTargetSelector
                Spacer()
            }
            HStack(spacing: 12) {
                Button(text("artifacts.summary")) { vm.generateSummary() }
                    .disabled(vm.outputDir == nil || vm.isRecording || vm.isTranscribing)
                Button(text("artifacts.shareSummary")) {
                    if let url = vm.shareableURL(vm.selectedArtifactSummaryURL) { shareFile(url) }
                }
                .disabled(vm.shareableURL(vm.selectedArtifactSummaryURL) == nil)

                Divider()
                    .frame(height: 18)

                Button(text("artifacts.kiExport")) { vm.generateKIAgentExport() }
                    .disabled(vm.outputDir == nil || vm.isRecording || vm.isTranscribing)
                Button(text("artifacts.shareKI")) {
                    if let url = vm.shareableURL(vm.selectedArtifactKIAgentExportURL) { shareFile(url) }
                }
                .disabled(vm.shareableURL(vm.selectedArtifactKIAgentExportURL) == nil)
                Button(text("artifacts.collectKI")) { vm.collectKIAgentExports() }
                    .disabled(vm.isRecording || vm.isTranscribing)
                Button(text("artifacts.openExportFolder")) { vm.openKIAgentExportFolder() }
            }
            Text(formatted("artifacts.exportFolder", MeetingArtifactGenerator.sharedExportFolder.path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(vm.artifactStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var artifactTargetSelector: some View {
        Menu {
            ForEach(vm.artifactTargets) { target in
                Button {
                    vm.selectArtifactTarget(target)
                } label: {
                    if target.id == vm.selectedArtifactTarget?.id {
                        Label(target.title, systemImage: "checkmark")
                    } else {
                        Text(target.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(vm.selectedArtifactTarget?.title ?? text("artifacts.targetOriginal"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: 190, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(vm.artifactTargets.isEmpty)
        .help(text("artifacts.target"))
    }

    private var statusBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text("status.title"))
                .font(.headline)
            Text(vm.status)
                .font(.callout)
                .textSelection(.enabled)
            if let outputDir = vm.outputDir {
                Text(outputDir.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.isRecording ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(vm.isRecording ? formatted("status.recording", formatDuration(vm.elapsed)) : text("status.idle"))
                .font(.headline.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
    }

    private var consentBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text("consent.title"), systemImage: "exclamationmark.shield")
                .font(.headline)
            Text(text("consent.text"))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func shareFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct PreferencesView: View {
    @AppStorage(AppSettings.preferredUILanguageKey) private var preferredUILanguage = AppLanguagePreference.system.rawValue

    private var languagePreference: AppLanguagePreference {
        AppLanguagePreference(rawValue: preferredUILanguage) ?? .system
    }

    private var language: AppLanguage {
        languagePreference.resolvedLanguage
    }

    private func text(_ key: String) -> String {
        L10n.text(key, language: language)
    }

    private func languageLabel(_ preference: AppLanguagePreference) -> String {
        switch preference {
        case .system: return text("language.system")
        case .german: return text("language.german")
        case .english: return text("language.english")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(text("prefs.title"))
                .font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(text("prefs.language"), selection: $preferredUILanguage) {
                        ForEach(AppLanguagePreference.allCases) { preference in
                            Text(languageLabel(preference)).tag(preference.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: preferredUILanguage) { newValue in
                        AppSettings.preferredUILanguage = AppLanguagePreference(rawValue: newValue) ?? .system
                        NotificationCenter.default.post(name: EchoPilotNotifications.languageChanged, object: nil)
                    }

                    Text(text("prefs.language.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: text("language.effective"), languageLabel(languagePreference.resolvedLanguage == .german ? .german : .english)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(text("prefs.language"), systemImage: "globe")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Button(text("prefs.checkUpdates")) {
                            NotificationCenter.default.post(name: EchoPilotNotifications.checkUpdatesRequested, object: nil)
                        }
                        Text(text("prefs.checkUpdates.help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Button(text("prefs.checkPermissions")) {
                            NotificationCenter.default.post(name: EchoPilotNotifications.checkPermissionsRequested, object: nil)
                        }
                        Text(text("prefs.checkPermissions.help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(text("prefs.maintenance"), systemImage: "wrench.and.screwdriver")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text("prefs.permissions.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    settingsPermissionRow(
                        "Microphone",
                        status: AppPermissions.microphoneStatusText,
                        granted: AppPermissions.isMicrophoneGranted,
                        button: text("prefs.openMicrophone"),
                        action: AppPermissions.openMicrophoneSettings
                    )
                    settingsPermissionRow(
                        "Screen/System audio",
                        status: AppPermissions.screenCaptureStatusText,
                        granted: AppPermissions.isScreenCaptureGranted,
                        button: text("prefs.openSystemAudio"),
                        action: AppPermissions.openScreenCaptureSettings
                    )
                    settingsPermissionRow(
                        "Accessibility",
                        status: AppPermissions.accessibilityStatusText,
                        granted: AppPermissions.isAccessibilityTrusted,
                        button: text("prefs.openAccessibility"),
                        action: AppPermissions.openAccessibilitySettings
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(text("prefs.permissions"), systemImage: "lock.shield")
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func settingsPermissionRow(_ title: String, status: String, granted: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Label(granted ? L10n.text("status.ok", language: language) : L10n.text("status.missing", language: language), systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 86, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
        }
    }
}

final class EchoPilotPreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = EchoPilotPreferencesWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged(_:)),
            name: EchoPilotNotifications.languageChanged,
            object: nil
        )
    }

    func show() {
        if window == nil {
            let preferencesWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            preferencesWindow.isReleasedWhenClosed = false
            preferencesWindow.delegate = self
            window = preferencesWindow
        }

        rebuildContent()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func languageChanged(_ notification: Notification) {
        rebuildContent()
    }

    @objc private func selectLanguage(_ sender: NSButton) {
        let preference: AppLanguagePreference
        switch sender.tag {
        case 1: preference = .german
        case 2: preference = .english
        default: preference = .system
        }
        AppSettings.preferredUILanguage = preference
        NotificationCenter.default.post(name: EchoPilotNotifications.languageChanged, object: nil)
    }

    @objc private func checkUpdates() {
        NotificationCenter.default.post(name: EchoPilotNotifications.checkUpdatesRequested, object: nil)
    }

    @objc private func checkPermissions() {
        EchoPilotWindowController.shared.showApp()
        NotificationCenter.default.post(name: EchoPilotNotifications.checkPermissionsRequested, object: nil)
    }

    @objc private func openMicrophoneSettings() {
        AppPermissions.openMicrophoneSettings()
    }

    @objc private func openScreenCaptureSettings() {
        AppPermissions.openScreenCaptureSettings()
    }

    @objc private func openAccessibilitySettings() {
        AppPermissions.openAccessibilitySettings()
    }

    private func rebuildContent() {
        guard let window else { return }
        let language = AppSettings.currentLanguage
        window.title = L10n.text("prefs.title", language: language)

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 470))
        contentView.autoresizingMask = [.width, .height]

        let title = label(L10n.text("prefs.title", language: language), frame: NSRect(x: 24, y: 424, width: 492, height: 28), font: .boldSystemFont(ofSize: 20))
        contentView.addSubview(title)

        let languageTitle = label(L10n.text("prefs.language", language: language), frame: NSRect(x: 24, y: 386, width: 492, height: 22), font: .boldSystemFont(ofSize: 14))
        contentView.addSubview(languageTitle)

        let selected = AppSettings.preferredUILanguage
        let systemButton = radioButton(title: L10n.text("language.system", language: language), tag: 0, selected: selected == .system, frame: NSRect(x: 24, y: 358, width: 220, height: 22))
        let germanButton = radioButton(title: L10n.text("language.german", language: language), tag: 1, selected: selected == .german, frame: NSRect(x: 24, y: 331, width: 220, height: 22))
        let englishButton = radioButton(title: L10n.text("language.english", language: language), tag: 2, selected: selected == .english, frame: NSRect(x: 24, y: 304, width: 220, height: 22))
        contentView.addSubview(systemButton)
        contentView.addSubview(germanButton)
        contentView.addSubview(englishButton)

        let help = label(L10n.text("prefs.language.help", language: language), frame: NSRect(x: 280, y: 340, width: 236, height: 46), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 3
        contentView.addSubview(help)

        let activePreference: AppLanguagePreference = AppSettings.currentLanguage == .german ? .german : .english
        let active = label(String(format: L10n.text("language.effective", language: language), L10n.text(activePreference == .german ? "language.german" : "language.english", language: language)), frame: NSRect(x: 280, y: 308, width: 236, height: 22), font: .boldSystemFont(ofSize: 11), color: .secondaryLabelColor)
        contentView.addSubview(active)

        let divider = NSBox(frame: NSRect(x: 24, y: 286, width: 492, height: 1))
        divider.boxType = .separator
        contentView.addSubview(divider)

        let maintenanceTitle = label(L10n.text("prefs.maintenance", language: language), frame: NSRect(x: 24, y: 253, width: 492, height: 22), font: .boldSystemFont(ofSize: 14))
        contentView.addSubview(maintenanceTitle)

        let updateButton = pushButton(title: L10n.text("prefs.checkUpdates", language: language), action: #selector(checkUpdates), frame: NSRect(x: 24, y: 215, width: 180, height: 30))
        contentView.addSubview(updateButton)
        let updateHelp = label(L10n.text("prefs.checkUpdates.help", language: language), frame: NSRect(x: 220, y: 212, width: 296, height: 36), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        updateHelp.lineBreakMode = .byWordWrapping
        updateHelp.maximumNumberOfLines = 2
        contentView.addSubview(updateHelp)

        let permissionsButton = pushButton(title: L10n.text("prefs.checkPermissions", language: language), action: #selector(checkPermissions), frame: NSRect(x: 24, y: 175, width: 180, height: 30))
        contentView.addSubview(permissionsButton)
        let permissionsHelp = label(L10n.text("prefs.checkPermissions.help", language: language), frame: NSRect(x: 220, y: 172, width: 296, height: 36), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        permissionsHelp.lineBreakMode = .byWordWrapping
        permissionsHelp.maximumNumberOfLines = 2
        contentView.addSubview(permissionsHelp)

        let permissionDivider = NSBox(frame: NSRect(x: 24, y: 154, width: 492, height: 1))
        permissionDivider.boxType = .separator
        contentView.addSubview(permissionDivider)

        let permissionTitle = label(L10n.text("prefs.permissions", language: language), frame: NSRect(x: 24, y: 121, width: 492, height: 22), font: .boldSystemFont(ofSize: 14))
        contentView.addSubview(permissionTitle)
        let permissionHelp = label(L10n.text("prefs.permissions.help", language: language), frame: NSRect(x: 24, y: 92, width: 492, height: 24), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        permissionHelp.lineBreakMode = .byWordWrapping
        permissionHelp.maximumNumberOfLines = 2
        contentView.addSubview(permissionHelp)
        addPermissionRow(
            to: contentView,
            y: 62,
            title: "Microphone",
            status: AppPermissions.microphoneStatusText,
            granted: AppPermissions.isMicrophoneGranted,
            buttonTitle: L10n.text("prefs.openMicrophone", language: language),
            action: #selector(openMicrophoneSettings)
        )
        addPermissionRow(
            to: contentView,
            y: 35,
            title: "Screen/System audio",
            status: AppPermissions.screenCaptureStatusText,
            granted: AppPermissions.isScreenCaptureGranted,
            buttonTitle: L10n.text("prefs.openSystemAudio", language: language),
            action: #selector(openScreenCaptureSettings)
        )
        addPermissionRow(
            to: contentView,
            y: 8,
            title: "Accessibility",
            status: AppPermissions.accessibilityStatusText,
            granted: AppPermissions.isAccessibilityTrusted,
            buttonTitle: L10n.text("prefs.openAccessibility", language: language),
            action: #selector(openAccessibilitySettings)
        )

        window.contentView = contentView
    }

    private func addPermissionRow(to contentView: NSView, y: CGFloat, title: String, status: String, granted: Bool, buttonTitle: String, action: Selector) {
        let language = AppSettings.currentLanguage
        let state = label(granted ? L10n.text("status.ok", language: language) : L10n.text("status.missing", language: language), frame: NSRect(x: 24, y: y + 2, width: 72, height: 18), font: .boldSystemFont(ofSize: 11), color: granted ? .systemGreen : .systemOrange)
        contentView.addSubview(state)
        let titleLabel = label(title, frame: NSRect(x: 102, y: y + 9, width: 170, height: 16), font: .boldSystemFont(ofSize: 11))
        contentView.addSubview(titleLabel)
        let statusLabel = label(status, frame: NSRect(x: 102, y: y - 5, width: 250, height: 16), font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
        statusLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(statusLabel)
        let button = pushButton(title: buttonTitle, action: action, frame: NSRect(x: 372, y: y - 1, width: 144, height: 24))
        contentView.addSubview(button)
    }

    private func label(_ text: String, frame: NSRect, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = font
        field.textColor = color
        return field
    }

    private func radioButton(title: String, tag: Int, selected: Bool, frame: NSRect) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(selectLanguage(_:)))
        button.frame = frame
        button.tag = tag
        button.state = selected ? .on : .off
        return button
    }

    private func pushButton(title: String, action: Selector, frame: NSRect) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = frame
        button.bezelStyle = .rounded
        return button
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct EchoPilotCommands: Commands {
    @AppStorage(AppSettings.preferredUILanguageKey) private var preferredUILanguage = AppLanguagePreference.system.rawValue

    private var language: AppLanguage {
        AppLanguagePreference(rawValue: preferredUILanguage)?.resolvedLanguage ?? .english
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.text("menu.preferences", language: language)) {
                EchoPilotPreferencesWindowController.shared.show()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

final class EchoPilotWindowController: NSObject, NSWindowDelegate {
    static let shared = EchoPilotWindowController()

    private override init() {
        super.init()
    }

    func attachToExistingWindows() {
        for window in NSApp.windows {
            window.delegate = self
        }
    }

    func showApp() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        attachToExistingWindows()

        let restorableWindows = NSApp.windows.filter { window in
            window.canBecomeKey || window.isMiniaturized || window.isVisible
        }
        for window in restorableWindows where window.isMiniaturized {
            window.deminiaturize(nil)
        }

        if let window = restorableWindows.first(where: { $0.canBecomeKey }) ?? restorableWindows.first {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the SwiftUI window alive so the menu-bar item can bring it back.
        // This mirrors the yellow minimize button behavior, but without leaving
        // AppKit with a destroyed SwiftUI window scene.
        sender.orderOut(nil)
        return false
    }
}

final class EchoPilotStatusBarController: NSObject {
    static let shared = EchoPilotStatusBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let showItem = NSMenuItem(title: "", action: #selector(showApp), keyEquivalent: "")
    private let preferencesItem = NSMenuItem(title: "", action: #selector(openPreferences), keyEquivalent: ",")
    private let recordingItem = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")
    private var blinkTimer: Timer?
    private var isRecording = false
    private var blinkOn = true

    private lazy var normalImage: NSImage = makeStatusImage(named: "StatusIcon", fallbackSymbol: "waveform.circle.fill")
    private lazy var recordingImage: NSImage = makeStatusImage(named: "StatusIconRecording", fallbackSymbol: "record.circle.fill")

    private override init() {
        super.init()
        configureStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingStateChanged(_:)),
            name: EchoPilotNotifications.recordingStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged(_:)),
            name: EchoPilotNotifications.languageChanged,
            object: nil
        )
    }

    func start() {
        configureStatusItem()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = normalImage
        button.imagePosition = .imageOnly
        button.toolTip = "EchoPilot"

        let menu = NSMenu()
        menu.addItem(showItem)
        menu.addItem(preferencesItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(recordingItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        updateLocalizedMenuItems()
        updateRecordingMenuItem()
    }

    @objc private func recordingStateChanged(_ notification: Notification) {
        isRecording = notification.userInfo?["isRecording"] as? Bool ?? false
        updateRecordingMenuItem()
        if isRecording {
            startBlinking()
        } else {
            stopBlinking()
        }
    }

    @objc private func languageChanged(_ notification: Notification) {
        updateLocalizedMenuItems()
        updateRecordingMenuItem()
        updateIcon()
    }

    private func updateLocalizedMenuItems() {
        let language = AppSettings.currentLanguage
        showItem.title = L10n.text("menu.show", language: language)
        preferencesItem.title = L10n.text("menu.preferences", language: language)
        quitItem.title = L10n.text("menu.quit", language: language)
    }

    private func startBlinking() {
        blinkOn = true
        updateIcon()
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.blinkOn.toggle()
            self.updateIcon()
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
        updateIcon()
    }

    private func updateIcon() {
        statusItem.button?.image = isRecording && blinkOn ? recordingImage : normalImage
        let language = AppSettings.currentLanguage
        statusItem.button?.toolTip = isRecording ? L10n.text("tooltip.recording", language: language) : L10n.text("tooltip.idle", language: language)
    }

    private func updateRecordingMenuItem() {
        let language = AppSettings.currentLanguage
        recordingItem.title = isRecording ? L10n.text("menu.stopRecording", language: language) : L10n.text("menu.startRecording", language: language)
        recordingItem.image = NSImage(systemSymbolName: isRecording ? "stop.circle.fill" : "record.circle", accessibilityDescription: recordingItem.title)
    }

    private func makeStatusImage(named name: String, fallbackSymbol: String) -> NSImage {
        let image = NSImage(named: NSImage.Name(name))
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: name)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }

    @objc func showApp() {
        EchoPilotWindowController.shared.showApp()
    }

    @objc private func openPreferences() {
        EchoPilotPreferencesWindowController.shared.show()
    }

    @objc private func toggleRecording() {
        if isRecording {
            NotificationCenter.default.post(name: EchoPilotNotifications.stopRecordingRequested, object: nil)
        } else {
            showApp()
            NotificationCenter.default.post(name: EchoPilotNotifications.startRecordingRequested, object: nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

final class EchoPilotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        EchoPilotUserNotifier.requestAuthorization()
        EchoPilotStatusBarController.shared.start()
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            EchoPilotWindowController.shared.attachToExistingWindows()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        EchoPilotWindowController.shared.showApp()
        // `showApp()` restores the hidden SwiftUI window itself. Returning true lets
        // AppKit/SwiftUI perform the default WindowGroup reopen as well, which can
        // create a duplicate window after closing via the red traffic-light button
        // and reopening from the Dock. The status-bar item never hit that default
        // reopen path, which is why it only restored one window.
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard EchoPilotRecordingState.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Recording is still running"
        alert.informativeText = "Stop the EchoPilot recording before quitting so the local tracks and manifest are written correctly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Recording")
        alert.runModal()
        return .terminateCancel
    }
}

@main
struct EchoPilotApp: App {
    @NSApplicationDelegateAdaptor(EchoPilotAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    EchoPilotWindowController.shared.attachToExistingWindows()
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 820)

        Settings {
            PreferencesView()
        }
        .commands {
            EchoPilotCommands()
        }
    }
}

struct RuntimeError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}
