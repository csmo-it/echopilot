import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

final class AudioCounter: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private(set) var buffers: Int = 0
    private(set) var samples: Int64 = 0
    private(set) var firstPTS: CMTime?
    private(set) var lastPTS: CMTime?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        lock.lock()
        buffers += 1
        samples += Int64(CMSampleBufferGetNumSamples(sampleBuffer))
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil { firstPTS = pts }
        lastPTS = pts
        lock.unlock()
    }

    func snapshot() -> (buffers: Int, samples: Int64, duration: Double?) {
        lock.lock()
        defer { lock.unlock() }
        let duration: Double?
        if let firstPTS, let lastPTS {
            duration = CMTimeGetSeconds(lastPTS - firstPTS)
        } else {
            duration = nil
        }
        return (buffers, samples, duration)
    }
}

func parseSeconds() -> Int {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--seconds"), args.indices.contains(index + 1), let value = Int(args[index + 1]) {
        return max(1, min(value, 300))
    }
    return 10
}

func runSystemAudioProbe() async throws {
        let seconds = parseSeconds()
        print("EchoPilot — SystemAudioProbe")
        print("Duration: \(seconds)s")
        print("Tip: Play meeting/browser audio now. If macOS asks for Screen/System Audio permission, allow it and rerun.\n")

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
        // Minimal video dimensions: we only attach an audio output, but SCK still expects sane config.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let counter = AudioCounter()
        let queue = DispatchQueue(label: "ai.openclaw.echopilot.audio")
        try stream.addStreamOutput(counter, type: .audio, sampleHandlerQueue: queue)

        try await stream.startCapture()
        print("Capture started. Waiting \(seconds)s…")

        for i in 1...seconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let snap = counter.snapshot()
            print("t=\(i)s buffers=\(snap.buffers) samples=\(snap.samples)")
        }

        try await stream.stopCapture()
        let snap = counter.snapshot()
        print("\nCapture stopped.")
        print("Buffers: \(snap.buffers)")
        print("Samples: \(snap.samples)")
        if let duration = snap.duration {
            print(String(format: "Approx audio span: %.2fs", duration))
        }

        if snap.buffers == 0 {
            print("\nNo audio buffers received. Check macOS Screen/System Audio permission and ensure audio was playing.")
            Foundation.exit(2)
        }
    }

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
