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
        return installed.isEmpty ? "No Whisper models detected yet" : "Installed: \(installed.joined(separator: ", "))"
    }

    private var transcribeDisabledReason: String? {
        if vm.outputDir == nil { return "Select or record a meeting first." }
        if vm.isRecording { return "Stop the recording before transcribing." }
        if vm.isProcessing { return "EchoPilot is still preparing transcription input." }
        if vm.isTranscribing { return "Transcription is already running." }
        if !vm.ffmpegInstalled { return "FFmpeg is required for local transcription." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !compact {
                Text("Inspector")
                    .font(.title3.bold())
                    .foregroundStyle(EchoPilotTheme.text)
            }

            EchoCard("Transcription", subtitle: "Advanced controls stay here until they are relevant.", systemImage: "text.bubble") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Whisper model", selection: $vm.whisperModel) {
                        ForEach(vm.whisperModels) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                    Picker("Language", selection: $vm.whisperLanguage) {
                        Text("Auto").tag("auto")
                        Text("German").tag("de")
                        Text("English").tag("en")
                    }
                    Text(installedModelSummary)
                        .font(.caption)
                        .foregroundStyle(EchoPilotTheme.secondaryText)

                    HStack {
                        PrimaryButton(
                            "Transcribe locally",
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
                        SecondaryCommandButton("Cancel transcription", systemImage: "xmark.circle") {
                            vm.cancelTranscription()
                        }
                    }
                    Text(vm.transcriptionStatus)
                        .font(.caption)
                        .foregroundStyle(EchoPilotTheme.secondaryText)
                        .textSelection(.enabled)
                }
            }

            EchoCard("Batch automation", subtitle: "Use when EchoPilot should clear recordings outside meeting time.", systemImage: "clock.arrow.2.circlepath") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(vm.batchOpenCount) open")
                            .font(.headline)
                            .foregroundStyle(vm.batchOpenCount == 0 ? EchoPilotTheme.secondaryText : EchoPilotTheme.warning)
                        Spacer()
                        SecondaryCommandButton(
                            "Run batch",
                            systemImage: "play.circle",
                            disabledReason: batchDisabledReason
                        ) {
                            vm.startBatchTranscriptionManually()
                        }
                    }
                    Toggle("Idle transcription", isOn: $vm.batchIdleEnabled)
                        .toggleStyle(.checkbox)
                    Stepper("After \(vm.batchIdleMinutes) min idle", value: $vm.batchIdleMinutes, in: 2...120, step: 5)
                        .disabled(!vm.batchIdleEnabled)
                    Toggle("Daily schedule", isOn: $vm.batchScheduleEnabled)
                        .toggleStyle(.checkbox)
                    DatePicker("Run at", selection: $vm.batchScheduledTime, displayedComponents: .hourAndMinute)
                        .disabled(!vm.batchScheduleEnabled)
                    if vm.isBatchTranscribing {
                        SecondaryCommandButton("Cancel batch", systemImage: "stop.circle") {
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
        if vm.batchOpenCount == 0 { return "No untranscribed meetings found." }
        if vm.isRecording { return "Stop recording before batch transcription." }
        if vm.isProcessing || vm.isTranscribing { return "EchoPilot is busy." }
        if !vm.ffmpegInstalled { return "FFmpeg is required for transcription." }
        return nil
    }
}
