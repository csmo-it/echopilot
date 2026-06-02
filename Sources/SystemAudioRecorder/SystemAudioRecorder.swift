import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

struct CLIOptions {
    let seconds: Int
    let outputURL: URL

    static func parse() throws -> CLIOptions {
        let args = CommandLine.arguments
        var seconds = 30
        var output: String?

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--seconds":
                guard args.indices.contains(i + 1), let value = Int(args[i + 1]) else {
                    throw RuntimeError("Missing integer after --seconds")
                }
                seconds = max(1, min(value, 60 * 60))
                i += 2
            case "--output":
                guard args.indices.contains(i + 1) else {
                    throw RuntimeError("Missing path after --output")
                }
                output = args[i + 1]
                i += 2
            case "--help", "-h":
                print("""
                Usage:
                  swift run SystemAudioRecorder --seconds 30 [--output recordings/test.m4a]

                Records macOS system audio via ScreenCaptureKit to an AAC .m4a file.
                This does not record the microphone yet; that is the next spike.
                """)
                Foundation.exit(0)
            default:
                throw RuntimeError("Unknown argument: \(args[i])")
            }
        }

        let outputURL: URL
        if let output {
            outputURL = URL(fileURLWithPath: output).standardizedFileURL
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            outputURL = URL(fileURLWithPath: "recordings/system-audio-\(stamp).m4a").standardizedFileURL
        }

        return CLIOptions(seconds: seconds, outputURL: outputURL)
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
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
            throw RuntimeError("AVAssetWriter cannot add audio input for \(outputURL.path)")
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
                fputs("Failed to start AVAssetWriter: \(err)\n", stderr)
                return
            }
            writer.startSession(atSourceTime: pts)
            didStartSession = true
        }

        guard input.isReadyForMoreMediaData else {
            lock.unlock()
            return
        }

        let ok = input.append(sampleBuffer)
        if ok {
            appendedBuffers += 1
        } else {
            didSeeAppendFailure = true
            let err = writer.error?.localizedDescription ?? "unknown append error"
            lock.unlock()
            fputs("Failed to append audio sample buffer: \(err)\n", stderr)
            return
        }
        lock.unlock()
    }

    func snapshot() -> (buffers: Int, appendedBuffers: Int, samples: Int64, duration: Double?, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let duration: Double?
        if let firstPTS, let lastPTS {
            duration = CMTimeGetSeconds(lastPTS - firstPTS)
        } else {
            duration = nil
        }
        return (buffers, appendedBuffers, samples, duration, didSeeAppendFailure)
    }

    func finish() async throws {
        lock.lock()
        let didStart = didStartSession
        lock.unlock()

        guard didStart else { return }
        input.markAsFinished()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = self.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

func runSystemAudioRecorder() async throws {
        let options = try CLIOptions.parse()
        print("EchoPilot — SystemAudioRecorder")
        print("Duration: \(options.seconds)s")
        print("Output: \(options.outputURL.path)")
        print("Scope: system audio only. Microphone track comes next.\n")

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

        let recorder = try SystemAudioFileRecorder(outputURL: options.outputURL)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let queue = DispatchQueue(label: "ai.openclaw.echopilot.system-audio-recorder")
        try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: queue)

        try await stream.startCapture()
        print("Capture started. Play meeting/browser audio now…")

        for i in 1...options.seconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let snap = recorder.snapshot()
            print("t=\(i)s buffers=\(snap.buffers) appended=\(snap.appendedBuffers) samples=\(snap.samples)")
        }

        try await stream.stopCapture()
        try await recorder.finish()

        let snap = recorder.snapshot()
        print("\nCapture stopped.")
        print("Buffers: \(snap.buffers)")
        print("Appended buffers: \(snap.appendedBuffers)")
        print("Samples: \(snap.samples)")
        if let duration = snap.duration {
            print(String(format: "Approx audio span: %.2fs", duration))
        }
        print("File: \(options.outputURL.path)")

        if snap.buffers == 0 || snap.appendedBuffers == 0 {
            print("\nNo usable audio was written. Check macOS Screen/System Audio permission and ensure audio was playing.")
            Foundation.exit(2)
        }
        if snap.failed {
            print("\nAt least one append/write failure occurred. Try opening the file; if broken, share the full output with the maintainer.")
            Foundation.exit(3)
        }
    }

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
