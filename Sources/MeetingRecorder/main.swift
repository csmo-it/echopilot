import Foundation

Task {
    do {
        try await runMeetingRecorder()
        Foundation.exit(0)
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        Foundation.exit(1)
    }
}
RunLoop.main.run()
