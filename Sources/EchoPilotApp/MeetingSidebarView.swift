import SwiftUI

enum MeetingSidebarFilter: String, CaseIterable, Identifiable {
    case all
    case needsTranscription
    case transcribed
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .needsTranscription: return "Needs transcription"
        case .transcribed: return "Transcribed"
        case .archived: return "Archived"
        }
    }
}

struct MeetingSidebarView: View {
    @ObservedObject var vm: MeetingCaptureViewModel
    @State private var query = ""
    @State private var filter: MeetingSidebarFilter = .all

    private var visibleMeetings: [MeetingRecord] {
        vm.meetings.filter { meeting in
            let matchesQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.url.lastPathComponent.localizedCaseInsensitiveContains(query)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .needsTranscription: matchesFilter = !meeting.isFullyTranscribed
            case .transcribed: matchesFilter = meeting.isFullyTranscribed
            case .archived: matchesFilter = meeting.isArchived
            }
            return matchesQuery && matchesFilter
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meetings")
                        .font(.title3.bold())
                    Text("\(visibleMeetings.count) shown")
                        .font(.caption)
                        .foregroundStyle(EchoPilotTheme.secondaryText)
                }
                Spacer()
                Button {
                    vm.prepareNewRecording()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Prepare a new recording")
                .keyboardShortcut("n", modifiers: [.command])
            }

            TextField("Search meetings", text: $query)
                .textFieldStyle(.roundedBorder)

            Picker("Filter", selection: $filter) {
                ForEach(MeetingSidebarFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)

            Toggle("Show archived", isOn: $vm.showArchivedMeetings)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(EchoPilotTheme.secondaryText)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleMeetings) { meeting in
                        MeetingRowView(
                            meeting: meeting,
                            isSelected: meeting.id == vm.selectedMeetingID,
                            select: { vm.selectMeeting(meeting) },
                            archive: { vm.setArchive(!meeting.isArchived, for: meeting) },
                            delete: {
                                vm.selectedMeetingID = meeting.id
                                vm.deleteSelectedMeeting()
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if visibleMeetings.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.largeTitle)
                            .foregroundStyle(EchoPilotTheme.mutedText)
                        Text("No meetings")
                            .font(.headline)
                        Text("Start a recording or adjust your filter.")
                            .font(.caption)
                            .foregroundStyle(EchoPilotTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
        }
        .padding(16)
        .frame(width: 310)
        .background(EchoPilotTheme.background)
        .foregroundStyle(EchoPilotTheme.text)
    }
}

struct MeetingRowView: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let select: () -> Void
    let archive: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meeting.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Image(systemName: meeting.isFullyTranscribed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(meeting.isFullyTranscribed ? EchoPilotTheme.success : EchoPilotTheme.warning)
                }
                Text(meeting.subtitle())
                    .font(.caption)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    StatusChip(
                        meeting.isFullyTranscribed ? "Ready" : "To transcribe",
                        tone: meeting.isFullyTranscribed ? .success : .warning,
                        systemImage: meeting.isFullyTranscribed ? "checkmark" : "text.badge.plus"
                    )
                    if meeting.isArchived {
                        StatusChip("Archived", tone: .neutral, systemImage: "archivebox")
                    }
                    if meeting.pendingTranscriptCount > 0 {
                        StatusChip("\(meeting.pendingTranscriptCount) open", tone: .warning)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? EchoPilotTheme.primary.opacity(0.20) : EchoPilotTheme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? EchoPilotTheme.primary.opacity(0.65) : EchoPilotTheme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(meeting.isArchived ? "Unarchive" : "Archive", action: archive)
            Button("Delete", role: .destructive, action: delete)
        }
    }
}
