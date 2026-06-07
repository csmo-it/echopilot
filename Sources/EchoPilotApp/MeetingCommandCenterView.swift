import SwiftUI

enum MeetingWorkflowStage {
    case prepare
    case record
    case transcribe
    case review
    case export

    var label: String {
        switch self {
        case .prepare: return "Prepare"
        case .record: return "Record"
        case .transcribe: return "Transcribe"
        case .review: return "Review"
        case .export: return "Export"
        }
    }

    var subtitle: String {
        switch self {
        case .prepare: return "Confirm context and consent before capturing audio."
        case .record: return "Capture system audio and microphone as separate local tracks."
        case .transcribe: return "The recording is ready. Run local Whisper next."
        case .review: return "Review transcripts, timeline, summaries, and handoff files."
        case .export: return "Package the meeting for follow-up or AI-agent processing."
        }
    }
}

extension MeetingCaptureViewModel {
    var selectedMeeting: MeetingRecord? {
        guard let selectedMeetingID else { return nil }
        return meetings.first(where: { $0.id == selectedMeetingID })
    }

    var workflowStage: MeetingWorkflowStage {
        if isRecording || isStarting { return .record }
        if outputDir == nil { return .prepare }
        if isTranscribing || isBatchTranscribing || !fileExists(transcriptURL(for: .kiHandover)) {
            return .transcribe
        }
        if let exportURL = selectedArtifactKIAgentExportURL, fileExists(exportURL) {
            return .export
        }
        return .review
    }

    var nextRecommendedAction: String {
        switch workflowStage {
        case .prepare: return canStartRecording ? "Start Recording" : "Complete consent and permissions"
        case .record: return "Stop Recording"
        case .transcribe: return "Transcribe locally"
        case .review: return "Review meeting notes"
        case .export: return "Share or collect handoff files"
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = MeetingCaptureViewModel()

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                MeetingSidebarView(vm: vm)
                Divider().overlay(EchoPilotTheme.stroke)
                commandCenter
                Divider().overlay(EchoPilotTheme.stroke)
                TranscriptionInspectorView(vm: vm)
            }
            .frame(minWidth: 1280, minHeight: 760)
            .background(EchoPilotTheme.background)
            .blur(radius: vm.showPermissionsOverlay ? 2 : 0)
            .disabled(vm.showPermissionsOverlay)

            if vm.showPermissionsOverlay {
                CommandCenterPermissionsOverlay(vm: vm)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    vm.prepareNewRecording()
                } label: {
                    Label("New Recording", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button {
                    vm.refreshPermissions(showOverlayIfNeeded: true)
                    vm.refreshDependencies(showOverlayIfNeeded: true)
                } label: {
                    Label("Check Permissions", systemImage: "lock.shield")
                }

                Button {
                    vm.checkForUpdates(showStatus: true)
                } label: {
                    Label("Check Updates", systemImage: "arrow.down.circle")
                }
                .disabled(vm.isCheckingForUpdates)
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

    private var commandCenter: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                commandHeader
                if let updateInfo = vm.updateInfo {
                    updateBanner(updateInfo)
                }
                MeetingDetectionCard(vm: vm)
                RecordingControlCard(vm: vm)
                if vm.workflowStage != .prepare && vm.workflowStage != .record {
                    postRecordingNextAction
                }
                if vm.workflowStage == .review || vm.workflowStage == .export {
                    MeetingReviewView(vm: vm)
                }
                statusFooter
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EchoPilotTheme.background)
    }

    private var commandHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            CommandCenterSectionHeader(
                step: workflowTrail,
                title: "Meeting Command Center",
                subtitle: vm.workflowStage.subtitle
            )
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                StatusChip(vm.workflowStage.label, tone: stageTone, systemImage: stageIcon)
                Text(vm.nextRecommendedAction)
                    .font(.headline)
                    .foregroundStyle(EchoPilotTheme.text)
                if vm.isRecording {
                    Text(echoPilotFormatDuration(vm.elapsed))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(EchoPilotTheme.recording)
                }
            }
        }
    }

    private var workflowTrail: String {
        "Prepare -> Record -> Transcribe -> Review -> Export"
    }

    private var stageTone: StatusChip.Tone {
        switch vm.workflowStage {
        case .prepare: return .primary
        case .record: return .danger
        case .transcribe: return .warning
        case .review: return .success
        case .export: return .success
        }
    }

    private var stageIcon: String {
        switch vm.workflowStage {
        case .prepare: return "checklist"
        case .record: return "record.circle"
        case .transcribe: return "waveform.and.magnifyingglass"
        case .review: return "doc.text.magnifyingglass"
        case .export: return "shippingbox"
        }
    }

    private var postRecordingNextAction: some View {
        EchoCard("Next action", subtitle: "EchoPilot keeps the workflow narrow so you always know what comes next.", systemImage: "arrow.forward.circle") {
            HStack(alignment: .center, spacing: 12) {
                StatusChip(vm.workflowStage.label, tone: stageTone)
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.nextRecommendedAction)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(EchoPilotTheme.text)
                    Text(nextActionDetail)
                        .font(.callout)
                        .foregroundStyle(EchoPilotTheme.secondaryText)
                }
                Spacer()
                nextActionButton
            }
        }
    }

    private var nextActionDetail: String {
        switch vm.workflowStage {
        case .prepare:
            return "Fill meeting context, choose the mic, confirm consent."
        case .record:
            return "The current recording is local. Stop it to prepare transcription input."
        case .transcribe:
            return "Run local Whisper before reviewing transcripts and generating handoff files."
        case .review:
            return "Check summary, timeline, transcripts, and source files before exporting."
        case .export:
            return "Open, share, or collect AI handoff packages from the Files tab."
        }
    }

    @ViewBuilder private var nextActionButton: some View {
        switch vm.workflowStage {
        case .prepare:
            EmptyView()
        case .record:
            EmptyView()
        case .transcribe:
            PrimaryButton("Transcribe locally", systemImage: "waveform.and.magnifyingglass", disabledReason: transcribeDisabledReason) {
                vm.transcribeCurrentRecording()
            }
            .frame(width: 210)
        case .review:
            SecondaryCommandButton("Generate AI handoff", systemImage: "shippingbox", disabledReason: vm.outputDir == nil ? "Select a meeting first." : nil) {
                vm.generateKIAgentExport()
            }
        case .export:
            SecondaryCommandButton("Open export folder", systemImage: "folder", action: vm.openKIAgentExportFolder)
        }
    }

    private var transcribeDisabledReason: String? {
        if vm.outputDir == nil { return "Select or record a meeting first." }
        if vm.isRecording { return "Stop recording before transcription." }
        if vm.isProcessing { return "Preparing transcription input." }
        if vm.isTranscribing { return "Transcription already running." }
        if !vm.ffmpegInstalled { return "Install FFmpeg first." }
        return nil
    }

    private func updateBanner(_ updateInfo: UpdateInfo) -> some View {
        EchoCard("Update available", subtitle: "Installed \(GitHubUpdateChecker.currentVersion), latest \(updateInfo.version)", systemImage: "arrow.down.circle") {
            HStack {
                Text(updateInfo.name)
                    .font(.callout)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                Spacer()
                SecondaryCommandButton("Open release", systemImage: "arrow.up.right.square") {
                    vm.openLatestRelease()
                }
                SecondaryCommandButton("Dismiss", systemImage: "xmark") {
                    vm.dismissUpdateInfo()
                }
            }
        }
    }

    private var statusFooter: some View {
        EchoCard("Status", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.status)
                    .font(.callout)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                    .textSelection(.enabled)
                if let outputDir = vm.outputDir {
                    Text(outputDir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(EchoPilotTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct CommandCenterPermissionsOverlay: View {
    @ObservedObject var vm: MeetingCaptureViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            EchoCard("EchoPilot setup", subtitle: "Recording needs macOS permissions and local tools before the workflow is reliable.", systemImage: "lock.shield") {
                VStack(alignment: .leading, spacing: 14) {
                    setupRow("Microphone", status: vm.microphonePermissionStatus, ready: vm.microphonePermissionGranted, primary: "Request") {
                        vm.requestMicrophonePermission()
                    } settings: {
                        vm.openMicrophoneSettings()
                    }
                    setupRow("Screen/System audio", status: vm.screenCapturePermissionStatus, ready: vm.screenCapturePermissionGranted, primary: "Request") {
                        vm.requestScreenCapturePermission()
                    } settings: {
                        vm.openScreenCaptureSettings()
                    }
                    setupRow("Homebrew", status: vm.homebrewStatus, ready: vm.homebrewInstalled, primary: "Install") {
                        vm.installHomebrew()
                    } settings: {}
                    setupRow("FFmpeg", status: vm.ffmpegStatus, ready: vm.ffmpegInstalled, primary: "Install") {
                        vm.installFFmpeg()
                    } settings: {}

                    HStack {
                        SecondaryCommandButton("Check again", systemImage: "arrow.clockwise") {
                            vm.refreshPermissions(showOverlayIfNeeded: true)
                            vm.refreshDependencies(showOverlayIfNeeded: true)
                        }
                        Spacer()
                        SecondaryCommandButton("Later", systemImage: "clock") {
                            vm.showPermissionsOverlay = false
                        }
                        PrimaryButton("Done", systemImage: "checkmark", disabledReason: vm.permissionsReady && vm.dependenciesReady ? nil : "Finish required permissions and tools first.") {
                            vm.showPermissionsOverlay = false
                        }
                        .frame(width: 120)
                    }
                }
            }
            .frame(width: 720)
            .shadow(color: .black.opacity(0.35), radius: 26)
        }
    }

    private func setupRow(
        _ title: String,
        status: String,
        ready: Bool,
        primary: String,
        action: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            StatusChip(ready ? "Ready" : "Missing", tone: ready ? .success : .warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(EchoPilotTheme.text)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
            Button(primary, action: action)
                .disabled(ready)
            if !ready {
                Button("Settings", action: settings)
                    .disabled(primary == "Install")
            }
        }
        .padding(12)
        .background(EchoPilotTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }
}
