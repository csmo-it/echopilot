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
}
