import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

struct CLIOptions {
    let seconds: Int
    let outputDir: URL

    static func parse() throws -> CLIOptions {
        let args = CommandLine.arguments
        var seconds = 30
        var outputDir: String?

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--seconds":
                guard args.indices.contains(i + 1), let value = Int(args[i + 1]) else {
                    throw RuntimeError("Missing integer after --seconds")
                }
                seconds = max(1, min(value, 60 * 60))
                i += 2
            case "--output-dir":
                guard args.indices.contains(i + 1) else {
                    throw RuntimeError("Missing path after --output-dir")
                }
                outputDir = args[i + 1]
                i += 2
            case "--help", "-h":
                print("""
                Usage:
                  swift run MeetingRecorder --seconds 30 [--output-dir recordings/test-meeting]

                Records two separate local tracks:
                  - system.m4a  macOS system/meeting audio via ScreenCaptureKit
                  - mic.caf     microphone audio via AVAudioEngine

                Keeping tracks separate makes debugging and later speaker-aware transcription easier.
                """)
                Foundation.exit(0)
            default:
                throw RuntimeError("Unknown argument: \(args[i])")
            }
        }

        let dirURL: URL
        if let outputDir {
            dirURL = URL(fileURLWithPath: outputDir).standardizedFileURL
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            dirURL = URL(fileURLWithPath: "recordings/meeting-\(stamp)").standardizedFileURL
        }
        return CLIOptions(seconds: seconds, outputDir: dirURL)
    }
}

final class SystemAudioFileRecorder: NSObject, SCStreamOutput {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var didStartSession = false
    private var didSeeAppendFailure = false

    private(set) var buffers: Int = 0
    private(set) var appendedBuffers: Int = 0
    private(set) var samples: Int64 = 0
    private(set) var firstPTS: CMTime?
    private(set) var lastPTS: CMTime?

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
        return TrackStats(buffers: buffers, writtenBuffers: appendedBuffers, samples: samples, duration: duration, failed: didSeeAppendFailure)
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

final class MicrophoneFileRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var buffers = 0
    private var samples: Int64 = 0
    private var failed = false

    let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            case .denied, .restricted:
                continuation.resume(returning: false)
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    func start() throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw RuntimeError("No microphone input channels available")
        }

        file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.file?.write(from: buffer)
                self.lock.lock()
                self.buffers += 1
                self.samples += Int64(buffer.frameLength)
                self.lock.unlock()
            } catch {
                self.lock.lock()
                self.failed = true
                self.lock.unlock()
                fputs("Failed to write microphone buffer: \(error.localizedDescription)\n", stderr)
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }

    func snapshot() -> TrackStats {
        lock.lock()
        defer { lock.unlock() }
        // Duration depends on the hardware sample rate; approximate from file format if available.
        let sampleRate = file?.processingFormat.sampleRate ?? 0
        let duration = sampleRate > 0 ? Double(samples) / sampleRate : nil
        return TrackStats(buffers: buffers, writtenBuffers: buffers, samples: samples, duration: duration, failed: failed)
    }
}

struct TrackStats {
    let buffers: Int
    let writtenBuffers: Int
    let samples: Int64
    let duration: Double?
    let failed: Bool
}

func runMeetingRecorder() async throws {
        let options = try CLIOptions.parse()
        try FileManager.default.createDirectory(at: options.outputDir, withIntermediateDirectories: true)
        let systemURL = options.outputDir.appendingPathComponent("system.m4a")
        let micURL = options.outputDir.appendingPathComponent("mic.caf")
        let manifestURL = options.outputDir.appendingPathComponent("manifest.json")

        print("EchoPilot — MeetingRecorder")
        print("Duration: \(options.seconds)s")
        print("Output dir: \(options.outputDir.path)")
        print("System track: \(systemURL.path)")
        print("Mic track: \(micURL.path)\n")

        guard await MicrophoneFileRecorder.requestPermission() else {
            throw RuntimeError("Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone for Terminal/iTerm/Xcode.")
        }

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

        let systemRecorder = try SystemAudioFileRecorder(outputURL: systemURL)
        let micRecorder = MicrophoneFileRecorder(outputURL: micURL)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let queue = DispatchQueue(label: "ai.openclaw.echopilot.meeting-recorder.system")
        try stream.addStreamOutput(systemRecorder, type: .audio, sampleHandlerQueue: queue)

        try micRecorder.start()
        try await stream.startCapture()
        print("Capture started. Play meeting/system audio and speak into the mic…")

        for i in 1...options.seconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let sys = systemRecorder.snapshot()
            let mic = micRecorder.snapshot()
            print("t=\(i)s system.appended=\(sys.writtenBuffers) mic.buffers=\(mic.writtenBuffers)")
        }

        try await stream.stopCapture()
        micRecorder.stop()
        try await systemRecorder.finish()

        let sys = systemRecorder.snapshot()
        let mic = micRecorder.snapshot()
        let manifest: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "duration_requested_seconds": options.seconds,
            "tracks": [
                "system": [
                    "path": systemURL.path,
                    "buffers": sys.buffers,
                    "written_buffers": sys.writtenBuffers,
                    "samples": sys.samples,
                    "approx_duration_seconds": sys.duration as Any,
                    "failed": sys.failed
                ],
                "microphone": [
                    "path": micURL.path,
                    "buffers": mic.buffers,
                    "written_buffers": mic.writtenBuffers,
                    "samples": mic.samples,
                    "approx_duration_seconds": mic.duration as Any,
                    "failed": mic.failed
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL)

        print("\nCapture stopped.")
        print("System buffers/appended: \(sys.buffers)/\(sys.writtenBuffers)")
        print("Mic buffers: \(mic.writtenBuffers)")
        print("Manifest: \(manifestURL.path)")

        if sys.writtenBuffers == 0 || mic.writtenBuffers == 0 {
            print("\nOne or both tracks did not record usable audio. Check Screen/System Audio and Microphone permissions.")
            Foundation.exit(2)
        }
        if sys.failed || mic.failed {
            print("\nAt least one track had write failures. Send the full output to AI agent.")
            Foundation.exit(3)
        }
    }

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
