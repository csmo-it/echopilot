import SwiftUI

struct TranscriptionInspectorView: View {
    @ObservedObject var vm: MeetingCaptureViewModel
    let width: CGFloat?
    let compact: Bool

    init(vm: MeetingCaptureViewModel, width: CGFloat? = 330, compact: Bool = false) {
        self.vm = vm
        self.width = width
        self.compact = compact
    }

    private var installedModelSummary: String {
        let installed = vm.whisperModels.filter(\.installed).map(\.id)
        return installed.isEmpty ? L10n.text("inspector.models.none") : L10n.format("inspector.models.installed", installed.joined(separator: ", "))
    }

    private var transcribeDisabledReason: String? {
        if vm.outputDir == nil { return L10n.text("disabled.selectOrRecordMeeting") }
        if vm.isRecording { return L10n.text("disabled.stopBeforeTranscription") }
        if vm.isProcessing { return L10n.text("disabled.preparingTranscriptionInput") }
        if vm.isTranscribing { return L10n.text("disabled.transcriptionRunning") }
        if !vm.ffmpegInstalled { return L10n.text("disabled.installFFmpeg") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !compact {
                Text(L10n.text("inspector.title"))
                    .font(.title3.bold())
                    .foregroundStyle(EchoPilotTheme.text)
            }

            EchoCard(L10n.text("transcription.title"), subtitle: L10n.text("inspector.transcription.subtitle"), systemImage: "text.bubble") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.text("inspector.whisperModel"), selection: $vm.whisperModel) {
                        ForEach(vm.whisperModels) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                    Picker(L10n.text("transcription.language"), selection: $vm.whisperLanguage) {
                        Text(L10n.text("transcription.auto")).tag("auto")
                        Text(L10n.text("transcription.german")).tag("de")
                        Text(L10n.text("transcription.english")).tag("en")
                    }
                    Text(installedModelSummary)
                        .font(.caption)
                        .foregroundStyle(EchoPilotTheme.secondaryText)

                    HStack {
                        PrimaryButton(
                            L10n.text("command.next.transcribe"),
                            systemImage: "waveform.and.magnifyingglass",
                            tone: .primary,
                            disabledReason: transcribeDisabledReason
                        ) {
                            vm.transcribeCurrentRecording()
                        }
                        .keyboardShortcut("t", modifiers: [.command])
                    }
                    if vm.isTranscribing {
                        ProgressView(value: vm.transcriptionProgress)
                            .progressViewStyle(.linear)
                        SecondaryCommandButton(L10n.text("inspector.cancelTranscription"), systemImage: "xmark.circle") {
                            vm.cancelTranscription()
                        }
                    }
                    Text(vm.transcriptionStatus)
                        .font(.caption)
                        .foregroundStyle(EchoPilotTheme.secondaryText)
                        .textSelection(.enabled)
                }
            }

            EchoCard(L10n.text("inspector.files.title"), subtitle: L10n.text("inspector.files.subtitle"), systemImage: "folder") {
                VStack(alignment: .leading, spacing: 8) {
                    SecondaryCommandButton(L10n.text("command.next.reviewTranscripts"), systemImage: "doc.text.magnifyingglass", disabledReason: vm.outputDir == nil ? L10n.text("disabled.selectMeeting") : nil) {
                        vm.showTranscriptReview()
                    }
                    SecondaryCommandButton(L10n.text("transcripts.openFile"), systemImage: "arrow.up.right.square", disabledReason: currentTranscriptDisabledReason) {
                        vm.openCurrentTranscriptFile()
                    }
                    SecondaryCommandButton(L10n.text("transcripts.revealFile"), systemImage: "scope", disabledReason: currentTranscriptDisabledReason) {
                        vm.revealCurrentTranscriptFile()
                    }
                    Divider()
                    SecondaryCommandButton(L10n.text("review.openMeetingFolder"), systemImage: "folder", disabledReason: vm.outputDir == nil ? L10n.text("disabled.selectMeeting") : nil) {
                        vm.openOutputFolder()
                    }
                    SecondaryCommandButton(L10n.text("review.openTranscriptionInput"), systemImage: "folder.badge.gearshape", disabledReason: vm.transcriptionInputFolderURL == nil ? L10n.text("disabled.noTranscriptionInput") : nil) {
                        vm.openTranscriptionInputFolder()
                    }
                }
            }

            EchoCard(L10n.text("batch.automation"), subtitle: L10n.text("batch.automation.subtitle"), systemImage: "clock.arrow.2.circlepath") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L10n.format("sidebar.openCount", vm.batchOpenCount))
                            .font(.headline)
                            .foregroundStyle(vm.batchOpenCount == 0 ? EchoPilotTheme.secondaryText : EchoPilotTheme.warning)
                        Spacer()
                        SecondaryCommandButton(
                            L10n.text("batch.run"),
                            systemImage: "play.circle",
                            disabledReason: batchDisabledReason
                        ) {
                            vm.startBatchTranscriptionManually()
                        }
                    }
                    Toggle(L10n.text("batch.idleTranscription"), isOn: $vm.batchIdleEnabled)
                        .toggleStyle(.checkbox)
                    Stepper(L10n.format("batch.afterIdle", vm.batchIdleMinutes), value: $vm.batchIdleMinutes, in: 2...120, step: 5)
                        .disabled(!vm.batchIdleEnabled)
                    Toggle(L10n.text("batch.dailySchedule"), isOn: $vm.batchScheduleEnabled)
                        .toggleStyle(.checkbox)
                    DatePicker(L10n.text("batch.runAt"), selection: $vm.batchScheduledTime, displayedComponents: .hourAndMinute)
                        .disabled(!vm.batchScheduleEnabled)
                    if vm.isBatchTranscribing {
                        SecondaryCommandButton(L10n.text("batch.cancel"), systemImage: "stop.circle") {
                            vm.cancelTranscription()
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(EchoPilotTheme.background)
        .foregroundStyle(EchoPilotTheme.text)
    }

    private var batchDisabledReason: String? {
        if vm.batchOpenCount == 0 { return L10n.text("batch.none") }
        if vm.isRecording { return L10n.text("disabled.stopBeforeBatch") }
        if vm.isProcessing || vm.isTranscribing { return L10n.text("disabled.busy") }
        if !vm.ffmpegInstalled { return L10n.text("disabled.installFFmpeg") }
        return nil
    }

    private var currentTranscriptDisabledReason: String? {
        guard let url = vm.transcriptURL(for: vm.transcriptPreviewKind) else {
            return L10n.text("disabled.selectMeeting")
        }
        return vm.fileExists(url) ? nil : L10n.text("disabled.fileMissing")
    }
}
