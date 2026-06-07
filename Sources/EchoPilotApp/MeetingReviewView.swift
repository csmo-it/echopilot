import AppKit
import SwiftUI

enum MeetingReviewTab: String, CaseIterable, Identifiable {
    case summary
    case timeline
    case combined
    case system
    case microphone
    case handoff
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "Summary"
        case .timeline: return "Timeline"
        case .combined: return "Combined transcript"
        case .system: return "System transcript"
        case .microphone: return "Microphone transcript"
        case .handoff: return "AI handoff"
        case .files: return "Files"
        }
    }

    var previewKind: TranscriptPreviewKind? {
        switch self {
        case .summary, .files: return nil
        case .timeline: return .combinedTimeline
        case .combined: return .combinedHandover
        case .system: return .system
        case .microphone: return .microphone
        case .handoff: return .kiHandover
        }
    }
}

struct MeetingReviewView: View {
    @ObservedObject var vm: MeetingCaptureViewModel
    @State private var selectedTab: MeetingReviewTab = .summary

    var body: some View {
        EchoCard("Review", subtitle: "Everything after transcription lands here.", systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Review tab", selection: $selectedTab) {
                    ForEach(MeetingReviewTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                content
                    .frame(minHeight: 300)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch selectedTab {
        case .summary:
            summaryPane
        case .files:
            filesPane
        default:
            transcriptPane
        }
    }

    private var summaryPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PrimaryButton("Generate summary", systemImage: "doc.text", disabledReason: vm.outputDir == nil ? "Select a meeting first." : nil) {
                    vm.generateSummary()
                }
                .frame(width: 190)
                SecondaryCommandButton("Share", systemImage: "square.and.arrow.up", disabledReason: vm.shareableURL(vm.selectedArtifactSummaryURL) == nil ? "Generate a summary first." : nil) {
                    if let url = vm.shareableURL(vm.selectedArtifactSummaryURL) {
                        share(url)
                    }
                }
                SecondaryCommandButton("Generate AI handoff", systemImage: "shippingbox", disabledReason: vm.outputDir == nil ? "Select a meeting first." : nil) {
                    vm.generateKIAgentExport()
                }
                Spacer()
            }
            Text(vm.artifactStatus)
                .font(.callout)
                .foregroundStyle(EchoPilotTheme.secondaryText)
                .textSelection(.enabled)
            if let url = vm.selectedArtifactSummaryURL, vm.fileExists(url) {
                previewFile(url)
            } else {
                emptyState("No summary generated yet.", systemImage: "doc")
            }
        }
    }

    private var transcriptPane: some View {
        let kind = selectedTab.previewKind ?? .timeline
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.title)
                    .font(.headline)
                    .foregroundStyle(EchoPilotTheme.text)
                Spacer()
                if let url = vm.transcriptURL(for: kind) {
                    SecondaryCommandButton("Open file", systemImage: "arrow.up.right.square", disabledReason: vm.fileExists(url) ? nil : "File does not exist yet.") {
                        NSWorkspace.shared.open(url)
                    }
                    SecondaryCommandButton("Share", systemImage: "square.and.arrow.up", disabledReason: vm.fileExists(url) ? nil : "File does not exist yet.") {
                        share(url)
                    }
                }
            }
            ScrollView {
                Text(previewText(for: kind))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(EchoPilotTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(EchoPilotTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
        }
        .onAppear {
            vm.loadTranscriptPreview(kind)
        }
        .onChange(of: selectedTab) { _ in
            vm.loadTranscriptPreview(kind)
        }
    }

    private var filesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SecondaryCommandButton("Open meeting folder", systemImage: "folder", disabledReason: vm.outputDir == nil ? "Select a meeting first." : nil) {
                    vm.openOutputFolder()
                }
                SecondaryCommandButton("Open transcription input", systemImage: "folder.badge.gearshape", disabledReason: vm.transcriptionInputDir == nil ? "No transcription input folder yet." : nil) {
                    vm.openTranscriptionInputFolder()
                }
                SecondaryCommandButton("Collect AI exports", systemImage: "tray.and.arrow.down") {
                    vm.collectKIAgentExports()
                }
            }
            if let outputDir = vm.outputDir {
                Text(outputDir.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                    .textSelection(.enabled)
            }
            Text("Files are local. EchoPilot does not upload recordings or transcripts by itself.")
                .font(.caption)
                .foregroundStyle(EchoPilotTheme.secondaryText)
        }
    }

    private func previewText(for kind: TranscriptPreviewKind) -> String {
        if vm.transcriptPreviewKind != kind {
            return "Loading \(kind.title)..."
        }
        return vm.transcriptPreviewText
    }

    private func previewFile(_ url: URL) -> some View {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "Could not read \(url.lastPathComponent)."
        return ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(EchoPilotTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .background(EchoPilotTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }

    private func emptyState(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(EchoPilotTheme.mutedText)
            Text(text)
                .font(.headline)
                .foregroundStyle(EchoPilotTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(EchoPilotTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }

    private func share(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
