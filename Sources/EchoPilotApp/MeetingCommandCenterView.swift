import SwiftUI

enum MeetingWorkflowStage {
    case prepare
    case record
    case transcribe
    case review
    case export

    var label: String {
        switch self {
        case .prepare: return L10n.text("workflow.prepare")
        case .record: return L10n.text("workflow.record")
        case .transcribe: return L10n.text("workflow.transcribe")
        case .review: return L10n.text("workflow.review")
        case .export: return L10n.text("workflow.export")
        }
    }

    var subtitle: String {
        switch self {
        case .prepare: return L10n.text("workflow.prepare.subtitle")
        case .record: return L10n.text("workflow.record.subtitle")
        case .transcribe: return L10n.text("workflow.transcribe.subtitle")
        case .review: return L10n.text("workflow.review.subtitle")
        case .export: return L10n.text("workflow.export.subtitle")
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
        case .prepare: return canStartRecording ? L10n.text("button.startRecording") : L10n.text("command.next.completePermissions")
        case .record: return L10n.text("button.stopRecording")
        case .transcribe: return L10n.text("command.next.transcribe")
        case .review: return L10n.text("command.next.review")
        case .export: return L10n.text("command.next.export")
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = MeetingCaptureViewModel()
    @State private var inspectorVisible = true

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let layout = CommandCenterLayout(width: proxy.size.width)
                HStack(spacing: 0) {
                    MeetingSidebarView(vm: vm, width: layout.sidebarWidth)
                    Divider().overlay(EchoPilotTheme.stroke)
                    commandCenter(showCompactInspector: inspectorVisible && !layout.showSideInspector)
                    if inspectorVisible && layout.showSideInspector {
                        Divider().overlay(EchoPilotTheme.stroke)
                        TranscriptionInspectorView(vm: vm, width: layout.inspectorWidth)
                    }
                }
            }
            .frame(minWidth: 860, minHeight: 640)
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
                    Label(L10n.text("button.newRecording"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button {
                    vm.refreshPermissions(showOverlayIfNeeded: true)
                    vm.refreshDependencies(showOverlayIfNeeded: true)
                } label: {
                    Label(L10n.text("actions.checkPermissions"), systemImage: "lock.shield")
                }

                Button {
                    vm.checkForUpdates(showStatus: true)
                } label: {
                    Label(L10n.text("actions.checkUpdates"), systemImage: "arrow.down.circle")
                }
                .disabled(vm.isCheckingForUpdates)

                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label(inspectorVisible ? L10n.text("command.hideInspector") : L10n.text("command.showInspector"), systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
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
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.cancelAutoRecordingRequested)) { _ in
            vm.cancelAutoRecordingCountdown()
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
            EchoPilotUserNotifier.configureActions()
            vm.refreshLocalizedText()
        }
        .onReceive(NotificationCenter.default.publisher(for: EchoPilotNotifications.autoRecordSettingChanged)) { _ in
            vm.autoRecordMeetingsEnabled = AppSettings.autoRecordMeetingsEnabled
        }
    }

    private func commandCenter(showCompactInspector: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                commandHeader
                if let updateInfo = vm.updateInfo {
                    updateBanner(updateInfo)
                }
                if !vm.permissionsReady {
                    permissionWarning
                }
                MeetingDetectionCard(vm: vm)
                RecordingControlCard(vm: vm)
                if vm.workflowStage != .prepare && vm.workflowStage != .record {
                    postRecordingNextAction
                }
                if vm.workflowStage == .review || vm.workflowStage == .export {
                    MeetingReviewView(vm: vm)
                }
                if showCompactInspector {
                    TranscriptionInspectorView(vm: vm, width: nil, compact: true)
                }
                statusFooter
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EchoPilotTheme.background)
    }

    private var commandHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    CommandCenterSectionHeader(
                        step: workflowTrail,
                        title: L10n.text("command.title"),
                        subtitle: vm.workflowStage.subtitle
                    )
                    Spacer()
                    stageSummary(trailing: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    CommandCenterSectionHeader(
                        step: workflowTrail,
                        title: L10n.text("command.title"),
                        subtitle: vm.workflowStage.subtitle
                    )
                    stageSummary(trailing: false)
                }
            }

            consentNotice
        }
    }

    private func stageSummary(trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 8) {
            StatusChip(vm.workflowStage.label, tone: stageTone, systemImage: stageIcon)
            Text(vm.nextRecommendedAction)
                .font(.headline)
                .foregroundStyle(EchoPilotTheme.text)
                .lineLimit(2)
                .multilineTextAlignment(trailing ? .trailing : .leading)
            if vm.isRecording {
                Text(echoPilotFormatDuration(vm.elapsed))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(EchoPilotTheme.recording)
            }
        }
    }

    private var consentNotice: some View {
        Label {
            Text(L10n.text("command.recordingAgreementNotice"))
                .font(.caption)
                .foregroundStyle(EchoPilotTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised")
                .foregroundStyle(EchoPilotTheme.warning)
        }
    }

    private struct CommandCenterLayout {
        let width: CGFloat

        var sidebarWidth: CGFloat {
            if width < 980 { return 248 }
            if width < 1160 { return 272 }
            return 310
        }

        var inspectorWidth: CGFloat {
            if width < 1280 { return 292 }
            return 330
        }

        var showSideInspector: Bool {
            width >= 1080
        }
    }

    private var workflowTrail: String {
        "\(L10n.text("workflow.prepare")) -> \(L10n.text("workflow.record")) -> \(L10n.text("workflow.transcribe")) -> \(L10n.text("workflow.review")) -> \(L10n.text("workflow.export"))"
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    nextActionCopy
                    Spacer()
                    nextActionButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    nextActionCopy
                    nextActionButton
                }
            }
        }
    }

    private var nextActionCopy: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusChip(vm.workflowStage.label, tone: stageTone)
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.nextRecommendedAction)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(EchoPilotTheme.text)
                    .lineLimit(2)
                Text(nextActionDetail)
                    .font(.callout)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nextActionDetail: String {
        switch vm.workflowStage {
        case .prepare:
            return L10n.text("command.nextDetail.prepare")
        case .record:
            return L10n.text("command.nextDetail.record")
        case .transcribe:
            return L10n.text("command.nextDetail.transcribe")
        case .review:
            return L10n.text("command.nextDetail.review")
        case .export:
            return L10n.text("command.nextDetail.export")
        }
    }

    @ViewBuilder private var nextActionButton: some View {
        switch vm.workflowStage {
        case .prepare:
            EmptyView()
        case .record:
            EmptyView()
        case .transcribe:
            PrimaryButton(L10n.text("command.next.transcribe"), systemImage: "waveform.and.magnifyingglass", disabledReason: transcribeDisabledReason) {
                vm.transcribeCurrentRecording()
            }
            .frame(width: 210)
        case .review:
            SecondaryCommandButton(L10n.text("review.generateHandoff"), systemImage: "shippingbox", disabledReason: vm.outputDir == nil ? L10n.text("disabled.selectMeeting") : nil) {
                vm.generateKIAgentExport()
            }
        case .export:
            SecondaryCommandButton(L10n.text("review.openExportFolder"), systemImage: "folder", action: vm.openKIAgentExportFolder)
        }
    }

    private var transcribeDisabledReason: String? {
        if vm.outputDir == nil { return L10n.text("disabled.selectOrRecordMeeting") }
        if vm.isRecording { return L10n.text("disabled.stopBeforeTranscription") }
        if vm.isProcessing { return L10n.text("disabled.preparingTranscriptionInput") }
        if vm.isTranscribing { return L10n.text("disabled.transcriptionRunning") }
        if !vm.ffmpegInstalled { return L10n.text("disabled.installFFmpeg") }
        return nil
    }

    private func updateBanner(_ updateInfo: UpdateInfo) -> some View {
        EchoCard(L10n.text("update.cardTitle"), subtitle: L10n.format("update.subtitle", GitHubUpdateChecker.currentVersion, updateInfo.version), systemImage: "arrow.down.circle") {
            HStack {
                Text(updateInfo.name)
                    .font(.callout)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                Spacer()
                SecondaryCommandButton(L10n.text("update.openRelease"), systemImage: "arrow.up.right.square") {
                    vm.openLatestRelease()
                }
                SecondaryCommandButton(L10n.text("update.dismiss"), systemImage: "xmark") {
                    vm.dismissUpdateInfo()
                }
            }
        }
    }

    private var permissionWarning: some View {
        EchoCard(L10n.text("permissions.warning.title"), subtitle: L10n.text("permissions.warning.subtitle"), systemImage: "exclamationmark.triangle") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    permissionWarningText
                    Spacer()
                    permissionWarningActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    permissionWarningText
                    permissionWarningActions
                }
            }
        }
    }

    private var permissionWarningText: some View {
        Text(L10n.text("permissions.warning.text"))
            .font(.callout)
            .foregroundStyle(EchoPilotTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var permissionWarningActions: some View {
        SecondaryCommandButton(L10n.text("permissions.reviewSetup"), systemImage: "lock.shield") {
            vm.showPermissionsOverlay = true
        }
        SecondaryCommandButton(L10n.text("permissions.settings"), systemImage: "gearshape") {
            EchoPilotPreferencesWindowController.shared.show()
        }
    }

    private var statusFooter: some View {
        EchoCard(L10n.text("status.title"), systemImage: "info.circle") {
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
            EchoCard(L10n.text("setup.title"), subtitle: L10n.text("setup.subtitle"), systemImage: "lock.shield") {
                VStack(alignment: .leading, spacing: 14) {
                    setupRow(L10n.text("audio.microphone"), status: vm.microphonePermissionStatus, ready: vm.microphonePermissionGranted, primary: L10n.text("setup.request")) {
                        vm.requestMicrophonePermission()
                    } settings: {
                        vm.openMicrophoneSettings()
                    }
                    setupRow(L10n.text("audio.systemAudio"), status: vm.screenCapturePermissionStatus, ready: vm.screenCapturePermissionGranted, primary: L10n.text("setup.request")) {
                        vm.requestScreenCapturePermission()
                    } settings: {
                        vm.openScreenCaptureSettings()
                    }
                    setupRow("Homebrew", status: vm.homebrewStatus, ready: vm.homebrewInstalled, primary: L10n.text("setup.install")) {
                        vm.installHomebrew()
                    } settings: {}
                    setupRow("FFmpeg", status: vm.ffmpegStatus, ready: vm.ffmpegInstalled, primary: L10n.text("setup.install")) {
                        vm.installFFmpeg()
                    } settings: {}

                    HStack {
                        SecondaryCommandButton(L10n.text("setup.checkAgain"), systemImage: "arrow.clockwise") {
                            vm.refreshPermissions(showOverlayIfNeeded: true)
                            vm.refreshDependencies(showOverlayIfNeeded: true)
                        }
                        Spacer()
                        SecondaryCommandButton(L10n.text("setup.later"), systemImage: "clock") {
                            vm.showPermissionsOverlay = false
                        }
                        PrimaryButton(L10n.text("setup.done"), systemImage: "checkmark", disabledReason: vm.permissionsReady && vm.dependenciesReady ? nil : L10n.text("setup.done.disabled")) {
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
            StatusChip(ready ? L10n.text("status.readyShort") : L10n.text("status.missing"), tone: ready ? .success : .warning)
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
                Button(L10n.text("permissions.settings"), action: settings)
                    .disabled(primary == L10n.text("setup.install"))
            }
        }
        .padding(12)
        .background(EchoPilotTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }
}
