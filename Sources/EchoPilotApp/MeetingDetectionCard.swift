import SwiftUI

struct MeetingDetectionCard: View {
    @ObservedObject var vm: MeetingCaptureViewModel

    private var hasSuggestion: Bool {
        vm.meetingSuggestion != nil || vm.meetingDeviceStatus.inMeeting
    }

    private var title: String {
        if let suggested = vm.meetingSuggestion?.title, !suggested.isEmpty {
            return suggested
        }
        if let suggestion = vm.meetingSuggestion {
            return suggestion.detail
        }
        return vm.meetingDeviceStatus.inMeeting ? L10n.text("detection.activityDetected") : L10n.text("detection.noneDetected")
    }

    private var participants: String {
        let names = vm.meetingSuggestion?.participants ?? []
        return names.isEmpty ? L10n.text("detection.participantsMissing") : names.joined(separator: ", ")
    }

    var body: some View {
        EchoCard(
            L10n.text("detection.title"),
            subtitle: L10n.text("detection.subtitle"),
            systemImage: hasSuggestion ? "video.badge.checkmark" : "video.slash"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $vm.autoRecordMeetingsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("autoRecord.toggle"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(EchoPilotTheme.text)
                        Text(L10n.text("autoRecord.help"))
                            .font(.caption)
                            .foregroundStyle(EchoPilotTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if vm.autoRecordMeetingsEnabled {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            countdownStepper
                            stopDelayStepper
                            Text(L10n.text("autoRecord.microphoneFallback"))
                                .font(.caption)
                                .foregroundStyle(EchoPilotTheme.secondaryText)
                            Spacer()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            countdownStepper
                            stopDelayStepper
                            Text(L10n.text("autoRecord.microphoneFallback"))
                                .font(.caption)
                                .foregroundStyle(EchoPilotTheme.secondaryText)
                        }
                    }
                }

                if let prompt = vm.autoRecordingPrompt {
                    autoRecordingCountdown(prompt)
                }
                if let stopPrompt = vm.autoRecordingStopPrompt {
                    autoRecordingStopCountdown(stopPrompt)
                }

                HStack(alignment: .top, spacing: 12) {
                    StatusChip(
                        hasSuggestion ? L10n.text("detection.suggested") : L10n.text("detection.idle"),
                        tone: hasSuggestion ? .success : .neutral,
                        systemImage: hasSuggestion ? "sparkles" : "moon"
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(EchoPilotTheme.text)
                            .lineLimit(2)
                        Text(participants)
                            .font(.callout)
                            .foregroundStyle(EchoPilotTheme.secondaryText)
                            .lineLimit(2)
                        Text(vm.meetingDeviceStatus.summary())
                            .font(.caption)
                            .foregroundStyle(EchoPilotTheme.mutedText)
                            .lineLimit(2)
                    }
                    Spacer()
                }

                if hasSuggestion && !vm.isRecording && !vm.isStarting {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            detectionActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            detectionActions
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var detectionActions: some View {
        PrimaryButton(L10n.text("detection.use"), systemImage: "checkmark", tone: .primary) {
            vm.prepareSuggestedRecording()
        }
        .frame(width: 110)
        SecondaryCommandButton(L10n.text("detection.edit"), systemImage: "pencil") {
            vm.prepareSuggestedRecording()
            vm.status = L10n.text("detection.status.loaded")
        }
        SecondaryCommandButton(L10n.text("detection.ignore"), systemImage: "xmark") {
            vm.meetingSuggestion = nil
            vm.status = L10n.text("detection.status.ignored")
        }
    }

    private var countdownStepper: some View {
        Stepper(
            L10n.format("autoRecord.countdownSetting", vm.autoRecordCountdownSeconds),
            value: $vm.autoRecordCountdownSeconds,
            in: 1...60,
            step: 1
        )
        .font(.caption.weight(.semibold))
    }

    private var stopDelayStepper: some View {
        Stepper(
            L10n.format("autoRecord.stopDelaySetting", vm.autoRecordStopDelaySeconds),
            value: $vm.autoRecordStopDelaySeconds,
            in: 0...300,
            step: 1
        )
        .font(.caption.weight(.semibold))
    }

    private func autoRecordingCountdown(_ prompt: AutoRecordingPrompt) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                countdownCopy(prompt)
                Spacer()
                countdownActions
            }
            VStack(alignment: .leading, spacing: 10) {
                countdownCopy(prompt)
                countdownActions
            }
        }
        .padding(12)
        .background(EchoPilotTheme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(EchoPilotTheme.warning.opacity(0.35), lineWidth: 1)
        )
    }

    private func autoRecordingStopCountdown(_ prompt: AutoRecordingStopPrompt) -> some View {
        Label {
            Text(L10n.format("autoRecord.stopCountdown", prompt.remainingSeconds))
                .font(.headline)
                .foregroundStyle(EchoPilotTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "stopwatch")
                .foregroundStyle(EchoPilotTheme.warning)
        }
        .padding(12)
        .background(EchoPilotTheme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(EchoPilotTheme.warning.opacity(0.35), lineWidth: 1)
        )
    }

    private func countdownCopy(_ prompt: AutoRecordingPrompt) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.format("autoRecord.countdown", prompt.title, prompt.remainingSeconds))
                    .font(.headline)
                    .foregroundStyle(EchoPilotTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.detail)
                    .font(.caption)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: "timer")
                .foregroundStyle(EchoPilotTheme.warning)
        }
    }

    private var countdownActions: some View {
        HStack(spacing: 8) {
            SecondaryCommandButton(L10n.text("autoRecord.cancel"), systemImage: "xmark.circle") {
                vm.cancelAutoRecordingCountdown()
            }
            PrimaryButton(L10n.text("autoRecord.startNow"), systemImage: "record.circle") {
                vm.startPendingAutoRecordingNow()
            }
            .frame(width: 140)
        }
    }
}
