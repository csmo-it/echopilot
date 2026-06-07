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
        return vm.meetingDeviceStatus.inMeeting ? "Meeting activity detected" : "No active meeting detected"
    }

    private var participants: String {
        let names = vm.meetingSuggestion?.participants ?? []
        return names.isEmpty ? "Participants not detected yet" : names.joined(separator: ", ")
    }

    var body: some View {
        EchoCard(
            "Smart meeting detection",
            subtitle: "Local Teams/Zoom/Webex/Meet/Slack/browser context stays optional and permission-aware.",
            systemImage: hasSuggestion ? "video.badge.checkmark" : "video.slash"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    StatusChip(
                        hasSuggestion ? "Suggested" : "Idle",
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
                    HStack(spacing: 10) {
                        PrimaryButton("Use", systemImage: "checkmark", tone: .primary) {
                            vm.prepareSuggestedRecording()
                        }
                        .frame(width: 110)
                        SecondaryCommandButton("Edit", systemImage: "pencil") {
                            vm.prepareSuggestedRecording()
                            vm.status = "Suggestion loaded. Edit the meeting fields before recording."
                        }
                        SecondaryCommandButton("Ignore", systemImage: "xmark") {
                            vm.meetingSuggestion = nil
                            vm.status = "Meeting suggestion ignored."
                        }
                    }
                }
            }
        }
    }
}
