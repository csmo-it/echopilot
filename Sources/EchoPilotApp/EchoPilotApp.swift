import SwiftUI
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AppKit
import AudioToolbox
import Foundation

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
            return previous * 0.25 + measured * 0.75
        }
        return previous * 0.72 + measured * 0.28
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
        let hint: String
        switch id {
        case "turbo": hint = "Apple Silicon schnell"
        case "small": hint = "Standard/leicht"
        case "large-v3": hint = "Qualität/langsam"
        default: hint = ""
        }
        let suffix = hint.isEmpty ? "" : " · \(hint)"
        return installed ? "\(id) · installiert\(suffix)" : "\(id) · wird beim ersten Lauf geladen\(suffix)"
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
}

enum TranscriptPreviewKind: String, CaseIterable, Identifiable, Hashable {
    case timeline
    case kiHandover
    case system
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "Timeline"
        case .kiHandover: return "KI-Handover"
        case .system: return "Systemaudio"
        case .microphone: return "Mikrofon"
        }
    }

    var relativePath: String {
        switch self {
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
}

enum MeetingCallDetector {
    static func detect() async -> MeetingSuggestion? {
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
        case .authorized: return "Freigegeben"
        case .notDetermined: return "Noch nicht angefragt"
        case .denied: return "Abgelehnt"
        case .restricted: return "Eingeschränkt"
        @unknown default: return "Unbekannt"
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
        isScreenCaptureGranted ? "Freigegeben" : "Nicht freigegeben"
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

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
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
            throw RuntimeError("Recording konnte nicht starten: \(error.localizedDescription). Prüfe zusätzlich zu Mikrofon auch Datenschutz → Screen & System Audio Recording für EchoPilot/Xcode.")
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
            throw RuntimeError("Aufnahme hatte keine Audio-Buffer und wurde verworfen. Prüfe Screen & System Audio Recording sowie Mikrofon-Berechtigung für genau die App, die du startest.")
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
        try await MainActor.run { progress(0.05, "Vorbereitung gestartet…") }
        let inputDir = session.outputDir.appendingPathComponent("transcription-input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)

        let systemDest = inputDir.appendingPathComponent("system.m4a")
        let micDest = inputDir.appendingPathComponent("mic.m4a")
        let manifestDest = inputDir.appendingPathComponent("manifest.json")
        for url in [systemDest, micDest, manifestDest] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        try await MainActor.run { progress(0.25, "Kopiere Systemaudio…") }
        try FileManager.default.copyItem(at: session.systemURL, to: systemDest)
        try await MainActor.run { progress(0.45, "Kopiere Mikrofonspur…") }
        try FileManager.default.copyItem(at: session.micURL, to: micDest)
        try await MainActor.run { progress(0.60, "Kopiere Manifest…") }
        try FileManager.default.copyItem(at: session.manifestURL, to: manifestDest)

        try await MainActor.run { progress(0.75, "Schreibe Handoff-Dateien…") }
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

        try await MainActor.run { progress(1.0, "Vorbereitung fertig: transcription-input erstellt. Transkription separat starten.") }
        return PostProcessResult(inputDir: inputDir, notesInputURL: notesInputURL)
    }
}

final class LocalTranscriber {
    static func transcribe(
        sessionDir: URL,
        model: String,
        language: String,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EchoPilotApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root

        let transcribeScript = repoRoot.appendingPathComponent("scripts/transcribe-local-whisper.sh")
        let assembleScript = repoRoot.appendingPathComponent("scripts/assemble-meeting-notes.sh")
        guard FileManager.default.fileExists(atPath: transcribeScript.path) else {
            throw RuntimeError("Transcription script not found: \(transcribeScript.path)")
        }
        guard FileManager.default.fileExists(atPath: assembleScript.path) else {
            throw RuntimeError("Assemble script not found: \(assembleScript.path)")
        }

        try await MainActor.run { progress(0.05, "Transkription gestartet…") }
        let inputDir = sessionDir.appendingPathComponent("transcription-input", isDirectory: true)
        let logURL = inputDir.appendingPathComponent("transcription.log")

        let command = """
        set -euo pipefail
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        cd \(shellQuote(repoRoot.path))
        mkdir -p \(shellQuote(inputDir.path))
        export WHISPER_MODEL=\(shellQuote(model))
        export WHISPER_LANGUAGE=\(shellQuote(language))
        {
          date
          scripts/transcribe-local-whisper.sh \(shellQuote(sessionDir.path))
          scripts/assemble-meeting-notes.sh \(shellQuote(inputDir.path))
        } 2>&1 | tee \(shellQuote(logURL.path))
        """

        try await MainActor.run { progress(0.15, "Starte lokales Whisper (\(model), Sprache: \(language)). Erster Lauf kann wegen Installation/Modelldownload dauern…") }
        try await runShell(command) { line in
            Task { @MainActor in
                progress(0.45, "Whisper läuft… \(line)")
            }
        }

        let notesURL = inputDir.appendingPathComponent("meeting-notes-input.md")
        guard FileManager.default.fileExists(atPath: notesURL.path) else {
            throw RuntimeError("Transcription finished but meeting-notes-input.md was not created")
        }
        try await MainActor.run { progress(1.0, "Transkription fertig: meeting-notes-input.md aktualisiert.") }
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
    let hasSummary: Bool

    var subtitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        var parts = [formatter.string(from: createdAt)]
        if hasTranscript { parts.append("Transkript") }
        if hasSummary { parts.append("Summary") }
        return parts.joined(separator: " · ")
    }
}

struct MeetingMetadata: Codable, Equatable {
    var title: String
    var participants: String
    var customerProject: String
    var consentConfirmed: Bool
    var updatedAt: String
}

enum AppSettings {
    private static let selectedAudioInputIDKey = "selectedAudioInputID"
    private static let whisperModelKey = "whisperModel"
    private static let whisperLanguageKey = "whisperLanguage"
    private static let dismissedUpdateVersionKey = "dismissedUpdateVersion"

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
    static var rootURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("EchoPilot", isDirectory: true)
    }

    static func loadMeetings() -> [MeetingRecord] {
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
                let title = metadata?.title.isEmpty == false ? metadata!.title : url.lastPathComponent
                let inputDir = url.appendingPathComponent("transcription-input", isDirectory: true)
                let hasTranscript = fm.fileExists(atPath: inputDir.appendingPathComponent("meeting-notes-input.md").path)
                    && ((try? String(contentsOf: inputDir.appendingPathComponent("meeting-notes-input.md")))?.contains("## Mic transcript") == true)
                let hasSummary = fm.fileExists(atPath: url.appendingPathComponent("summary.md").path)
                return MeetingRecord(id: url.path, title: title, url: url, createdAt: createdAt, hasTranscript: hasTranscript, hasSummary: hasSummary)
            }
            .sorted { $0.createdAt > $1.createdAt }
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
    static func generateSummary(sessionDir: URL, metadata: MeetingMetadata) throws -> URL {
        let inputURL = sessionDir.appendingPathComponent("transcription-input/meeting-notes-input.md")
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
        - **Consent bestätigt:** \(metadata.consentConfirmed ? "Ja" : "Nein / offen")

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
        let out = sessionDir.appendingPathComponent("summary.md")
        try summary.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func generateKIAgentExport(sessionDir: URL, metadata: MeetingMetadata) throws -> URL {
        let inputURL = sessionDir.appendingPathComponent("transcription-input/meeting-notes-input.md")
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
        - **Consent bestätigt:** \(metadata.consentConfirmed ? "Ja" : "Nein / offen")
        - **Session:** \(sessionDir.lastPathComponent)

        ## Transcript / Source Material

        `timeline.md` is generated from timestamped `system.vtt` + `mic.vtt` and should be used as the primary source when available. It labels turns by track (`mic/Local speaker`, `system/Andere`) and sorts by timestamp. This is two-source timeline alignment, not full multi-speaker diarization.

        \(transcript)
        """
        let out = sessionDir.appendingPathComponent("ki-agent-export.md")
        try export.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

@MainActor
final class MeetingCaptureViewModel: ObservableObject {
    @Published var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            NotificationCenter.default.post(
                name: EchoPilotNotifications.recordingStateChanged,
                object: nil,
                userInfo: ["isRecording": isRecording]
            )
        }
    }
    @Published var isStarting = false
    @Published var status = "Bereit. Vor echten Meetings Consent/Ansage nicht vergessen."
    @Published var outputDir: URL?
    @Published var systemStats = TrackStats()
    @Published var micStats = TrackStats()
    @Published var elapsed: TimeInterval = 0
    @Published var audioInputDevices: [AudioInputDevice] = AudioInputDevice.available()
    @Published var selectedAudioInputID: String? = nil {
        didSet { AppSettings.selectedAudioInputID = selectedAudioInputID }
    }
    @Published var isProcessing = false
    @Published var processingProgress = 0.0
    @Published var processingStatus = "Vorbereitung wartet auf Aufnahme."
    @Published var transcriptionInputDir: URL?
    @Published var isTranscribing = false
    @Published var transcriptionProgress = 0.0
    @Published var transcriptionStatus = "Transkription noch nicht gestartet."
    @Published var notesInputURL: URL?
    @Published var meetings: [MeetingRecord] = []
    @Published var selectedMeetingID: String?
    @Published var meetingTitle = ""
    @Published var participants = ""
    @Published var customerProject = ""
    @Published var consentConfirmed = false
    @Published var whisperModel = AppSettings.whisperModel {
        didSet { AppSettings.whisperModel = whisperModel }
    }
    @Published var whisperLanguage = AppSettings.whisperLanguage {
        didSet { AppSettings.whisperLanguage = whisperLanguage }
    }
    @Published var whisperModels: [WhisperModelInfo] = WhisperModelInfo.available()
    @Published var artifactStatus = "Noch keine Meeting-Artefakte erstellt."
    @Published var summaryURL: URL?
    @Published var kiAgentExportURL: URL?
    @Published var transcriptPreviewKind: TranscriptPreviewKind = .timeline
    @Published var transcriptPreviewTitle = "Timeline"
    @Published var transcriptPreviewText = "Noch kein Transkript geladen. Nach der Transkription erscheint hier die Timeline."
    @Published var meetingSuggestion: MeetingSuggestion?
    @Published var showPermissionsOverlay = false
    @Published var microphonePermissionGranted = false
    @Published var microphonePermissionStatus = "Nicht geprüft"
    @Published var screenCapturePermissionGranted = false
    @Published var screenCapturePermissionStatus = "Nicht geprüft"
    @Published var updateInfo: UpdateInfo?
    @Published var isCheckingForUpdates = false
    @Published var updateCheckStatus = ""

    var permissionsReady: Bool {
        microphonePermissionGranted && screenCapturePermissionGranted
    }

    private let service = MeetingCaptureService()
    private var timer: Timer?
    private var detectorTimer: Timer?
    private var startedAt: Date?
    private var transcriptionTask: Task<Void, Never>?
    private var suggestionSnoozedUntil: Date?

    init() {
        refreshAudioInputs()
        refreshWhisperModels()
        refreshMeetings()
        prepareNewRecording()
        refreshPermissions(showOverlayIfNeeded: true)
        startMeetingDetector()
        checkForUpdatesOnStartup()
    }

    func checkForUpdatesOnStartup() {
        checkForUpdates(showStatus: false)
    }

    func checkForUpdates(showStatus: Bool = true) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        if showStatus { updateCheckStatus = "Suche nach Updates…" }
        Task {
            do {
                let latest = try await GitHubUpdateChecker.checkForUpdate()
                if let latest, AppSettings.dismissedUpdateVersion != latest.version {
                    updateInfo = latest
                    updateCheckStatus = "Neue Version verfügbar: \(latest.version)"
                } else if showStatus {
                    updateCheckStatus = "EchoPilot ist aktuell (\(GitHubUpdateChecker.currentVersion))."
                }
            } catch {
                if showStatus {
                    updateCheckStatus = "Update-Check fehlgeschlagen: \(error.localizedDescription)"
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
        if permissionsReady {
            showPermissionsOverlay = false
        } else if showOverlayIfNeeded {
            showPermissionsOverlay = true
        }
    }

    func requestMicrophonePermission() {
        let granted = AppPermissions.requestMicrophone()
        refreshPermissions(showOverlayIfNeeded: true)
        status = granted ? "Mikrofon freigegeben." : "Mikrofon nicht freigegeben. Bitte in den Systemeinstellungen prüfen."
    }

    func requestScreenCapturePermission() {
        let granted = AppPermissions.requestScreenCapture()
        refreshPermissions(showOverlayIfNeeded: true)
        status = granted ? "Screen & System Audio Recording freigegeben." : "Screen & System Audio Recording nicht freigegeben. Bitte in den Systemeinstellungen prüfen und EchoPilot neu starten, falls macOS das verlangt."
    }

    func openMicrophoneSettings() {
        AppPermissions.openMicrophoneSettings()
    }

    func openScreenCaptureSettings() {
        AppPermissions.openScreenCaptureSettings()
    }

    func start() {
        guard !isStarting, !isRecording else { return }
        refreshPermissions(showOverlayIfNeeded: false)
        guard permissionsReady else {
            showPermissionsOverlay = true
            status = "Bitte zuerst Mikrofon und Screen/Systemaudio freigeben."
            return
        }
        isStarting = true
        Task {
            do {
                let session = try await service.start(microphoneDeviceID: selectedAudioInputID)
                startedAt = session.startedAt
                outputDir = session.outputDir
                selectedMeetingID = session.outputDir.path
                saveCurrentMetadata()
                isRecording = true
                status = "Recording läuft… Systemaudio + Mikrofon werden getrennt gespeichert."
                meetingSuggestion = nil
                startTimer()
            } catch {
                status = "Start fehlgeschlagen: \(error.localizedDescription)"
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
                refreshStats()
                if let session {
                    outputDir = session.outputDir
                    status = "Recording gespeichert: \(session.outputDir.path)"
                    saveCurrentMetadata()
                    await postProcess(session: session)
                    refreshMeetings()
                } else {
                    status = "Keine aktive Aufnahme."
                }
            } catch {
                isRecording = false
                status = "Stop fehlgeschlagen: \(error.localizedDescription)"
            }
        }
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
        meetings = MeetingLibrary.loadMeetings()
        if let selectedMeetingID, !meetings.contains(where: { $0.id == selectedMeetingID }) {
            prepareNewRecording()
        }
    }

    func prepareNewRecording() {
        selectedMeetingID = nil
        outputDir = nil
        transcriptionInputDir = nil
        notesInputURL = nil
        summaryURL = nil
        kiAgentExportURL = nil
        transcriptPreviewKind = .timeline
        transcriptPreviewTitle = "Timeline"
        transcriptPreviewText = "Noch kein Transkript geladen. Nach der Transkription erscheint hier die Timeline."
        meetingTitle = ""
        participants = ""
        customerProject = ""
        consentConfirmed = false
        transcriptionStatus = "Transkription noch nicht gestartet."
        artifactStatus = "Neue Aufnahme vorbereitet. Titel eintragen und Start Recording klicken."
        status = "Neue Aufnahme vorbereitet."
        elapsed = 0
        systemStats = TrackStats()
        micStats = TrackStats()
    }

    func deleteSelectedMeeting() {
        guard !isRecording, !isStarting, !isProcessing, !isTranscribing else {
            status = "Löschen nicht möglich während Aufnahme/Verarbeitung läuft."
            return
        }
        guard let selectedMeetingID, let meeting = meetings.first(where: { $0.id == selectedMeetingID }) else {
            status = "Kein Meeting zum Löschen ausgewählt."
            return
        }
        do {
            try MeetingLibrary.trashMeeting(at: meeting.url)
            prepareNewRecording()
            refreshMeetings()
            status = "Meeting in den Papierkorb verschoben: \(meeting.title)"
        } catch {
            status = "Meeting konnte nicht gelöscht werden: \(error.localizedDescription)"
        }
    }

    func selectMeeting(_ meeting: MeetingRecord) {
        selectedMeetingID = meeting.id
        outputDir = meeting.url
        transcriptionInputDir = meeting.url.appendingPathComponent("transcription-input", isDirectory: true)
        notesInputURL = transcriptionInputDir?.appendingPathComponent("meeting-notes-input.md")
        summaryURL = meeting.url.appendingPathComponent("summary.md")
        kiAgentExportURL = meeting.url.appendingPathComponent("ki-agent-export.md")
        if let metadata = try? MeetingLibrary.loadMetadata(from: meeting.url) {
            meetingTitle = metadata.title
            participants = metadata.participants
            customerProject = metadata.customerProject
            consentConfirmed = metadata.consentConfirmed
        } else {
            meetingTitle = ""
            participants = ""
            customerProject = ""
            consentConfirmed = false
        }
        loadTranscriptPreview(.timeline)
        status = "Meeting ausgewählt: \(meeting.title)"
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
        transcriptPreviewTitle = kind.title
        guard let url = transcriptURL(for: kind), FileManager.default.fileExists(atPath: url.path) else {
            transcriptPreviewText = "\(kind.title) ist noch nicht vorhanden. Bitte erst transkribieren oder Artefakt erzeugen."
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let limit = 220_000
            if text.count > limit {
                transcriptPreviewText = String(text.prefix(limit)) + "\n\n… gekürzt für die Vorschau. Datei öffnen/teilen für den vollständigen Inhalt."
            } else {
                transcriptPreviewText = text
            }
        } catch {
            transcriptPreviewText = "Konnte \(kind.title) nicht laden: \(error.localizedDescription)"
        }
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
                status = "Metadaten gespeichert."
            }
        } catch {
            status = "Metadaten konnten nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    func dismissMeetingSuggestion() {
        meetingSuggestion = nil
        suggestionSnoozedUntil = Date().addingTimeInterval(5 * 60)
    }

    func prepareSuggestedRecording() {
        let suggestion = meetingSuggestion
        prepareNewRecording()
        if let suggestion {
            meetingTitle = suggestion.detail
            status = "Aufnahme für erkannten Call vorbereitet. Bitte Consent prüfen und Start Recording klicken."
        }
        meetingSuggestion = nil
    }


    func transcribeCurrentRecording() {
        guard let outputDir else {
            transcriptionStatus = "Keine Aufnahme vorhanden."
            return
        }
        transcriptionTask?.cancel()
        transcriptionTask = Task {
            isTranscribing = true
            transcriptionProgress = 0
            transcriptionStatus = "Transkription gestartet…"
            do {
                saveCurrentMetadata()
                let notesURL = try await LocalTranscriber.transcribe(sessionDir: outputDir, model: whisperModel, language: whisperLanguage) { [weak self] progress, status in
                    self?.transcriptionProgress = progress
                    self?.transcriptionStatus = status
                }
                notesInputURL = notesURL
                transcriptionInputDir = notesURL.deletingLastPathComponent()
                transcriptionStatus = "Fertig: meeting-notes-input.md enthält jetzt Transkripte."
                loadTranscriptPreview(.timeline)
                refreshMeetings()
            } catch {
                if Task.isCancelled {
                    transcriptionStatus = "Transkription abgebrochen."
                } else {
                    transcriptionStatus = "Transkription fehlgeschlagen: \(error.localizedDescription)"
                }
            }
            isTranscribing = false
            transcriptionTask = nil
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionStatus = "Transkription wird abgebrochen…"
    }

    func generateSummary() {
        guard let outputDir else {
            artifactStatus = "Kein Meeting ausgewählt."
            return
        }
        saveCurrentMetadata()
        do {
            let out = try MeetingArtifactGenerator.generateSummary(sessionDir: outputDir, metadata: currentMetadata())
            summaryURL = out
            artifactStatus = "Summary-Entwurf erstellt: \(out.lastPathComponent)"
            refreshMeetings()
        } catch {
            artifactStatus = "Summary fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func generateKIAgentExport() {
        guard let outputDir else {
            artifactStatus = "Kein Meeting ausgewählt."
            return
        }
        saveCurrentMetadata()
        do {
            let out = try MeetingArtifactGenerator.generateKIAgentExport(sessionDir: outputDir, metadata: currentMetadata())
            kiAgentExportURL = out
            artifactStatus = "KI-Agent-Export erstellt: \(out.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([out])
            refreshMeetings()
        } catch {
            artifactStatus = "Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func postProcess(session: RecordingSession) async {
        isProcessing = true
        processingProgress = 0
        processingStatus = "Vorbereitung gestartet…"
        do {
            let result = try await PostProcessor.prepareTranscriptionInput(for: session) { [weak self] progress, status in
                self?.processingProgress = progress
                self?.processingStatus = status
                self?.status = status
            }
            transcriptionInputDir = result.inputDir
            processingStatus = "Fertig: transcription-input vorbereitet. Transkription ist noch ausstehend."
            status = "Vorbereitung fertig. Bereit für Transkription."
            notesInputURL = result.notesInputURL
        } catch {
            processingStatus = "Vorbereitung fehlgeschlagen: \(error.localizedDescription)"
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
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStats()
            }
        }
    }

    private func startMeetingDetector() {
        detectorTimer?.invalidate()
        Task { @MainActor in
            await checkMeetingSuggestion()
        }
        detectorTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkMeetingSuggestion()
            }
        }
    }

    private func checkMeetingSuggestion() async {
        guard !isRecording, !isStarting else { return }
        if let snoozed = suggestionSnoozedUntil, snoozed > Date() { return }
        if meetingSuggestion != nil { return }
        if let suggestion = await MeetingCallDetector.detect() {
            meetingSuggestion = suggestion
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshStats() {
        let stats = service.stats()
        systemStats = stats.system
        micStats = stats.mic
        if let startedAt {
            elapsed = Date().timeIntervalSince(startedAt)
        }
    }
}

struct LevelMeterView: View {
    let title: String
    let level: Float
    let isActive: Bool

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
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.14))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(levelColor)
                        .frame(width: max(4, proxy.size.width * CGFloat(max(0, min(1, level)))))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(height: 14)
        }
    }

    private var levelColor: Color {
        switch level {
        case 0..<0.68: return .green
        case 0.68..<0.92: return .yellow
        default: return .red
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = MeetingCaptureViewModel()

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
        }
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.startRecordingRequested)) { _ in
            vm.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.stopRecordingRequested)) { _ in
            vm.stop()
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
                        Text("EchoPilot Berechtigungen")
                            .font(.title2.bold())
                        Text("Bitte einmal vor der Aufnahme freigeben. So merken wir Probleme direkt beim Start – nicht erst, wenn du ein Meeting aufzeichnen willst.")
                            .foregroundStyle(.secondary)
                    }
                }

                permissionRow(
                    title: "Mikrofon",
                    status: vm.microphonePermissionStatus,
                    granted: vm.microphonePermissionGranted,
                    explanation: "Benötigt für deine lokale Spur.",
                    requestTitle: "Mikrofon freigeben",
                    requestAction: vm.requestMicrophonePermission,
                    settingsAction: vm.openMicrophoneSettings
                )

                permissionRow(
                    title: "Screen & System Audio Recording",
                    status: vm.screenCapturePermissionStatus,
                    granted: vm.screenCapturePermissionGranted,
                    explanation: "Benötigt für Systemaudio und Meeting-Fenster-Erkennung.",
                    requestTitle: "Systemaudio freigeben",
                    requestAction: vm.requestScreenCapturePermission,
                    settingsAction: vm.openScreenCaptureSettings
                )

                Divider()

                HStack {
                    Button("Erneut prüfen") { vm.refreshPermissions(showOverlayIfNeeded: true) }
                    Button("Systemeinstellungen: Mikrofon") { vm.openMicrophoneSettings() }
                    Button("Systemeinstellungen: Systemaudio") { vm.openScreenCaptureSettings() }
                    Spacer()
                    Button("Später") { vm.showPermissionsOverlay = false }
                    Button("Fertig") { vm.refreshPermissions(showOverlayIfNeeded: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!vm.permissionsReady)
                }

                if !vm.permissionsReady {
                    Text("Hinweis: Nach Screen/Systemaudio-Freigabe verlangt macOS manchmal einen Neustart der App. Danach hier auf „Erneut prüfen“ klicken.")
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
            Button("Einstellungen", action: settingsAction)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var meetingsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Meetings", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Button { vm.prepareNewRecording() } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .help("Neue Aufnahme vorbereiten")
                .buttonStyle(.borderless)
                Button { vm.refreshMeetings() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

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
                        Text(meeting.title)
                            .lineLimit(1)
                        Text(meeting.subtitle)
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
                            Label("Meeting löschen", systemImage: "trash")
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
                        Text("Noch keine Meetings")
                            .font(.headline)
                        Text("Aufnahmen erscheinen hier automatisch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var mainPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                updateBanner
                suggestionBanner
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
                Text("Native macOS Meeting Capture: Systemaudio + Mikrofon, lokal, ohne Bot.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            recordingBadge
        }
    }

    private var metadataBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Meeting", systemImage: "text.badge.checkmark")
                .font(.headline)
            TextField("Titel", text: $vm.meetingTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { vm.saveCurrentMetadata() }
                .onChange(of: vm.meetingTitle) { _ in vm.saveCurrentMetadata(showStatus: false) }
            TextField("Teilnehmer", text: $vm.participants)
                .textFieldStyle(.roundedBorder)
                .onSubmit { vm.saveCurrentMetadata() }
                .onChange(of: vm.participants) { _ in vm.saveCurrentMetadata(showStatus: false) }
            TextField("Kunde / Projekt", text: $vm.customerProject)
                .textFieldStyle(.roundedBorder)
                .onSubmit { vm.saveCurrentMetadata() }
                .onChange(of: vm.customerProject) { _ in vm.saveCurrentMetadata(showStatus: false) }
            Toggle("Teilnehmer wurden über Transkript/Meeting Notes informiert", isOn: $vm.consentConfirmed)
                .onChange(of: vm.consentConfirmed) { _ in vm.saveCurrentMetadata(showStatus: false) }
            if vm.outputDir == nil {
                Text("Neue Aufnahme: Titel/Metadaten jetzt vorbereiten; gespeichert wird beim Start der Aufnahme.")
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
            Label("Mikrofon/Input", systemImage: "mic")
                .font(.headline)
            Picker("Mikrofon", selection: Binding(
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
            Label("Transkription", systemImage: "gearshape")
                .font(.headline)
            Picker("Modell", selection: $vm.whisperModel) {
                ForEach(vm.whisperModels) { model in
                    Text(model.label).tag(model.id)
                }
            }
            Picker("Sprache", selection: $vm.whisperLanguage) {
                Text("Deutsch").tag("de")
                Text("Englisch").tag("en")
                Text("Auto").tag("auto")
            }
            Text(installedModelSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
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

            Button("Neue Aufnahme") { vm.prepareNewRecording() }
                .disabled(vm.isRecording || vm.isStarting)

            Button("Transkribieren") { vm.transcribeCurrentRecording() }
                .disabled(vm.outputDir == nil || vm.isRecording || vm.isProcessing || vm.isTranscribing)

            if vm.isTranscribing {
                Button("Abbrechen") { vm.cancelTranscription() }
            }

            Spacer()
            secondaryActionsMenu
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var secondaryActionsMenu: some View {
        Menu {
            Button("Berechtigungen prüfen") { vm.refreshPermissions(showOverlayIfNeeded: true) }
                .disabled(vm.isRecording || vm.isStarting)
            Button("Mikrofone neu laden") { vm.refreshAudioInputs() }
                .disabled(vm.isRecording)
            Button("Whisper-Modelle prüfen") { vm.refreshWhisperModels() }
            Button("Nach Updates suchen") { vm.checkForUpdates(showStatus: true) }
                .disabled(vm.isCheckingForUpdates)
            Divider()
            Button("Output öffnen") { vm.openOutputFolder() }
                .disabled(vm.outputDir == nil)
            Button("Transcription-Input öffnen") { vm.openTranscriptionInputFolder() }
                .disabled(vm.transcriptionInputDir == nil)
            Divider()
            Button("Metadaten speichern") { vm.saveCurrentMetadata() }
                .disabled(vm.outputDir == nil)
            Button("Meeting löschen", role: .destructive) { vm.deleteSelectedMeeting() }
                .disabled(vm.selectedMeetingID == nil || vm.isRecording || vm.isStarting || vm.isProcessing || vm.isTranscribing)
        } label: {
            Label("Weitere Aktionen", systemImage: "ellipsis.circle")
        }
        .buttonStyle(.bordered)
    }

    private var suggestionBanner: some View {
        Group {
            if let suggestion = vm.meetingSuggestion {
                HStack(alignment: .center, spacing: 12) {
                    Label("Möglicher Call erkannt", systemImage: "video.badge.waveform")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.detail)
                            .lineLimit(1)
                        Text("EchoPilot schlägt nur vor — keine automatische Aufnahme.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Aufnahme vorbereiten") { vm.prepareSuggestedRecording() }
                    Button("Ausblenden") { vm.dismissMeetingSuggestion() }
                }
                .padding(14)
                .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var updateBanner: some View {
        Group {
            if let updateInfo = vm.updateInfo {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Neue EchoPilot-Version verfügbar")
                            .font(.headline)
                        Text("Installiert: \(GitHubUpdateChecker.currentVersion) · Neu: \(updateInfo.version)")
                            .foregroundStyle(.secondary)
                        Text(updateInfo.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Release öffnen") { vm.openLatestRelease() }
                        .buttonStyle(.borderedProminent)
                    Button("Ausblenden") { vm.dismissUpdateInfo() }
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
        if vm.isRecording { return "Stop Recording" }
        if vm.isStarting { return "Starte…" }
        return "Start Recording"
    }

    private var installedModelSummary: String {
        let installed = vm.whisperModels.filter(\.installed).map(\.id)
        if installed.isEmpty { return "Installiert: keine erkannt · Modelle werden beim ersten Transkribieren geladen." }
        return "Installiert: \(installed.joined(separator: ", "))"
    }

    private var levelMeters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live Pegel", systemImage: "waveform")
                .font(.headline)
            LevelMeterView(title: "Systemaudio", level: vm.systemStats.level, isActive: vm.isRecording)
            LevelMeterView(title: "Mikrofon", level: vm.micStats.level, isActive: vm.isRecording)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptionProgressBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Transkriptionsstatus", systemImage: "text.bubble")
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
                Label("Transkripte", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Picker("Ansicht", selection: Binding(
                    get: { vm.transcriptPreviewKind },
                    set: { vm.loadTranscriptPreview($0) }
                )) {
                    ForEach(TranscriptPreviewKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
            }

            ScrollView {
                Text(vm.transcriptPreviewText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                if let url = vm.transcriptURL(for: vm.transcriptPreviewKind) {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Datei öffnen") { NSWorkspace.shared.open(url) }
                        .disabled(!vm.fileExists(url))
                    Button("Teilen…") { shareFile(url) }
                        .disabled(!vm.fileExists(url))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var artifactBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Meeting Notes & Export", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            HStack(spacing: 12) {
                Button("Zusammenfassung erstellen") { vm.generateSummary() }
                    .disabled(vm.outputDir == nil || vm.isRecording || vm.isTranscribing)
                Button("Summary teilen…") {
                    if let url = vm.shareableURL(vm.summaryURL) { shareFile(url) }
                }
                .disabled(vm.shareableURL(vm.summaryURL) == nil)

                Divider()
                    .frame(height: 18)

                Button("Für KI-Agent exportieren") { vm.generateKIAgentExport() }
                    .disabled(vm.outputDir == nil || vm.isRecording || vm.isTranscribing)
                Button("KI-Export teilen…") {
                    if let url = vm.shareableURL(vm.kiAgentExportURL) { shareFile(url) }
                }
                .disabled(vm.shareableURL(vm.kiAgentExportURL) == nil)
            }
            Text(vm.artifactStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status")
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
            Text(vm.isRecording ? "REC \(formatDuration(vm.elapsed))" : "Idle")
                .font(.headline.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
    }

    private var consentBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Consent Reminder", systemImage: "exclamationmark.shield")
                .font(.headline)
            Text("Vor echten Meetings klar ansagen: „Ich lasse zur Nachbereitung ein Transkript/Meeting Notes erstellen.“ Keine heimlichen Aufnahmen.")
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
    private let showItem = NSMenuItem(title: "EchoPilot anzeigen", action: #selector(showApp), keyEquivalent: "")
    private let recordingItem = NSMenuItem(title: "Aufnahme starten", action: #selector(toggleRecording), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Beenden", action: #selector(quitApp), keyEquivalent: "q")
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
        menu.addItem(recordingItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
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
        statusItem.button?.toolTip = isRecording ? "EchoPilot nimmt auf" : "EchoPilot"
    }

    private func updateRecordingMenuItem() {
        recordingItem.title = isRecording ? "Aufnahme stoppen" : "Aufnahme starten"
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
        return true
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
    }
}

struct RuntimeError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}
