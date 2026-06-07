import SwiftUI

struct RecordingControlCard: View {
    @ObservedObject var vm: MeetingCaptureViewModel

    private var primaryTitle: String {
        if vm.isRecording { return "Stop Recording" }
        if vm.isStarting { return "Starting..." }
        return "Start Recording"
    }

    private var primaryIcon: String {
        vm.isRecording ? "stop.circle.fill" : "record.circle"
    }

    private var primaryTone: StatusChip.Tone {
        vm.isRecording ? .danger : .primary
    }

    private var disabledReason: String? {
        vm.isRecording ? nil : vm.startRecordingDisabledReason
    }

    var body: some View {
        EchoCard(
            "Recording",
            subtitle: "Prepare the meeting once, then use the one obvious recording action.",
            systemImage: "record.circle"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                metadataFields
                AudioHealthMeters(vm: vm)
                actionRow
            }
        }
    }

    private var metadataFields: some View {
        ViewThatFits(in: .horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    commandTextField("Meeting title", text: $vm.meetingTitle, prompt: "Weekly customer sync")
                    commandTextField("Participants", text: $vm.participants, prompt: "Names or roles")
                }
                GridRow {
                    commandTextField("Customer / project", text: $vm.customerProject, prompt: "Quartz, Synmedico, internal...")
                    microphonePicker
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                commandTextField("Meeting title", text: $vm.meetingTitle, prompt: "Weekly customer sync")
                commandTextField("Participants", text: $vm.participants, prompt: "Names or roles")
                commandTextField("Customer / project", text: $vm.customerProject, prompt: "Quartz, Synmedico, internal...")
                microphonePicker
            }
        }
        .onChange(of: vm.meetingTitle) { _ in vm.saveCurrentMetadata(showStatus: false) }
        .onChange(of: vm.participants) { _ in vm.saveCurrentMetadata(showStatus: false) }
        .onChange(of: vm.customerProject) { _ in vm.saveCurrentMetadata(showStatus: false) }
    }

    private func commandTextField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(EchoPilotTheme.secondaryText)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isRecording)
        }
    }

    private var microphonePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Microphone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(EchoPilotTheme.secondaryText)
            Picker("Microphone", selection: Binding(
                get: { vm.selectedAudioInputID ?? "" },
                set: { vm.selectedAudioInputID = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(vm.audioInputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(vm.isRecording)
        }
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                recordButton
                    .frame(width: 240)
                actionHint
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                recordButton
                actionHint
            }
        }
    }

    private var recordButton: some View {
        PrimaryButton(primaryTitle, systemImage: primaryIcon, tone: primaryTone, disabledReason: disabledReason) {
            vm.isRecording ? vm.stop() : vm.start()
        }
        .keyboardShortcut("r", modifiers: [.command])
    }

    private var actionHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(vm.isRecording ? "Recording \(echoPilotFormatDuration(vm.elapsed))" : nextActionHint)
                .font(.headline.monospacedDigit())
                .foregroundStyle(vm.isRecording ? EchoPilotTheme.recording : EchoPilotTheme.text)
            if let disabledReason, !vm.isRecording {
                Text(disabledReason)
                    .font(.caption)
                    .foregroundStyle(EchoPilotTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(vm.status)
                    .font(.caption)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nextActionHint: String {
        if vm.outputDir != nil && !vm.isRecording {
            return "Next: Transcribe locally"
        }
        return "Next: Prepare and record"
    }
}

struct AudioHealthMeters: View {
    @ObservedObject var vm: MeetingCaptureViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                systemTile
                microphoneTile
            }
            VStack(spacing: 12) {
                systemTile
                microphoneTile
            }
        }
    }

    private var systemTile: some View {
        healthTile(
            title: "System audio",
            granted: vm.screenCapturePermissionGranted,
            status: vm.screenCapturePermissionStatus,
            level: { vm.liveLevel(for: .system) }
        )
    }

    private var microphoneTile: some View {
        healthTile(
            title: "Microphone",
            granted: vm.microphonePermissionGranted,
            status: vm.microphonePermissionStatus,
            level: { vm.liveLevel(for: .microphone) }
        )
    }

    private func healthTile(title: String, granted: Bool, status: String, level: @escaping () -> Float) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                Spacer()
                StatusChip(granted ? "Ready" : "Missing", tone: granted ? .success : .warning)
            }
            LevelMeterView(title: "", isActive: vm.isRecording, levelProvider: level)
                .frame(height: 18)
            Text(status)
                .font(.caption2)
                .foregroundStyle(EchoPilotTheme.mutedText)
                .lineLimit(1)
        }
        .padding(11)
        .background(EchoPilotTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }
}
