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
        case .summary: return L10n.text("review.tab.summary")
        case .timeline: return L10n.text("review.tab.timeline")
        case .combined: return L10n.text("review.tab.combined")
        case .system: return L10n.text("review.tab.system")
        case .microphone: return L10n.text("review.tab.microphone")
        case .handoff: return L10n.text("review.tab.handoff")
        case .files: return L10n.text("review.tab.files")
        }
    }

}

struct MeetingReviewView: View {
    @ObservedObject var vm: MeetingCaptureViewModel

    var body: some View {
        EchoCard(L10n.text("workflow.review"), subtitle: L10n.text("review.subtitle"), systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 12) {
                reviewTabPicker
                content
                    .frame(minHeight: 260)
            }
        }
        .onAppear(perform: loadSelectedPreview)
        .onChange(of: vm.selectedReviewTab) { _ in
            loadSelectedPreview()
        }
        .onChange(of: vm.selectedMeetingID) { _ in
            loadSelectedPreview()
        }
        .onChange(of: vm.outputDir) { _ in
            loadSelectedPreview()
        }
    }

    private var reviewTabPicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker(L10n.text("review.tabPicker"), selection: $vm.selectedReviewTab) {
                ForEach(MeetingReviewTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Picker(L10n.text("review.tabPicker"), selection: $vm.selectedReviewTab) {
                ForEach(MeetingReviewTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        switch vm.selectedReviewTab {
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
            ViewThatFits(in: .horizontal) {
                HStack {
                    summaryActions
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    summaryActions
                }
            }
            Text(vm.artifactStatus)
                .font(.callout)
                .foregroundStyle(EchoPilotTheme.secondaryText)
                .textSelection(.enabled)
            if let url = vm.selectedArtifactSummaryURL, vm.fileExists(url) {
                previewFile(url)
            } else {
                emptyState(L10n.text("review.summary.empty"), systemImage: "doc")
            }
        }
    }

    @ViewBuilder private var summaryActions: some View {
        PrimaryButton(L10n.text("review.generateSummary"), systemImage: "doc.text", disabledReason: vm.outputDir == nil ? L10n.text("disabled.selectMeeting") : nil) {
            vm.generateSummary()
        }
        .frame(width: 190)
        SecondaryCommandButton(L10n.text("review.share"), systemImage: "square.and.arrow.up", disabledReason: vm.shareableURL(vm.selectedArtifactSummaryURL) == nil ? L10n.text("disabled.generateSummaryFirst") : nil) {
            if let url = vm.shareableURL(vm.selectedArtifactSummaryURL) {
                share(url)
            }
        }
        SecondaryCommandButton(L10n.text("review.generateHandoff"), systemImage: "shippingbox", disabledReason: vm.outputDir == nil ? L10n.text("disabled.selectMeeting") : nil) {
            vm.generateKIAgentExport()
        }
    }

    private var transcriptPane: some View {
        let kind = previewKind(for: vm.selectedReviewTab) ?? .timeline
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    transcriptTitle(kind)
                    Spacer()
                    transcriptActions(for: kind)
                }
                VStack(alignment: .leading, spacing: 8) {
                    transcriptTitle(kind)
                    HStack {
                        transcriptActions(for: kind)
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
    }

    private func transcriptTitle(_ kind: TranscriptPreviewKind) -> some View {
        Text(kind.title)
            .font(.headline)
            .foregroundStyle(EchoPilotTheme.text)
    }

    @ViewBuilder private func transcriptActions(for kind: TranscriptPreviewKind) -> some View {
        if let url = vm.transcriptURL(for: kind) {
            SecondaryCommandButton(L10n.text("review.openFile"), systemImage: "arrow.up.right.square", disabledReason: vm.fileExists(url) ? nil : L10n.text("disabled.fileMissing")) {
                NSWorkspace.shared.open(url)
            }
            SecondaryCommandButton(L10n.text("review.share"), systemImage: "square.and.arrow.up", disabledReason: vm.fileExists(url) ? nil : L10n.text("disabled.fileMissing")) {
                share(url)
            }
        }
    }

    private var filesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    fileActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    fileActions
                }
            }
            if let outputDir = vm.outputDir {
                Text(outputDir.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                    .textSelection(.enabled)
            }
            Text(L10n.text("review.files.localNotice"))
                .font(.caption)
                .foregroundStyle(EchoPilotTheme.secondaryText)
        }
    }

    @ViewBuilder private var fileActions: some View {
        SecondaryCommandButton(L10n.text("review.openMeetingFolder"), systemImage: "folder", disabledReason: vm.outputDir == nil ? L10n.text("disabled.selectMeeting") : nil) {
            vm.openOutputFolder()
        }
        SecondaryCommandButton(L10n.text("review.openTranscriptionInput"), systemImage: "folder.badge.gearshape", disabledReason: vm.transcriptionInputDir == nil ? L10n.text("disabled.noTranscriptionInput") : nil) {
            vm.openTranscriptionInputFolder()
        }
        SecondaryCommandButton(L10n.text("review.collectExports"), systemImage: "tray.and.arrow.down") {
            vm.collectKIAgentExports()
        }
    }

    private func previewText(for kind: TranscriptPreviewKind) -> String {
        if vm.transcriptPreviewKind != kind {
            return L10n.format("review.loading", kind.title)
        }
        return vm.transcriptPreviewText
    }

    private func loadSelectedPreview() {
        guard let kind = previewKind(for: vm.selectedReviewTab) else { return }
        vm.loadTranscriptPreview(kind)
    }

    private func previewKind(for tab: MeetingReviewTab) -> TranscriptPreviewKind? {
        switch tab {
        case .summary, .files:
            return nil
        case .timeline:
            return vm.fileExists(vm.transcriptURL(for: .combinedTimeline)) ? .combinedTimeline : .timeline
        case .combined:
            return .combinedHandover
        case .system:
            return .system
        case .microphone:
            return .microphone
        case .handoff:
            return .kiHandover
        }
    }

    private func previewFile(_ url: URL) -> some View {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? L10n.format("review.readFailed", url.lastPathComponent)
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
