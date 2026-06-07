import SwiftUI

enum MeetingSidebarFilter: String, CaseIterable, Identifiable {
    case all
    case needsTranscription
    case transcribed
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.text("sidebar.filter.all")
        case .needsTranscription: return L10n.text("sidebar.filter.needsTranscription")
        case .transcribed: return L10n.text("sidebar.filter.transcribed")
        case .archived: return L10n.text("sidebar.filter.archived")
        }
    }
}

struct MeetingSidebarView: View {
    @ObservedObject var vm: MeetingCaptureViewModel
    let width: CGFloat
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
                    Text(L10n.text("sidebar.meetings"))
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text(L10n.format("sidebar.shownCount", visibleMeetings.count))
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
                .help(L10n.text("sidebar.new.help"))
                .keyboardShortcut("n", modifiers: [.command])
            }

            TextField(L10n.text("sidebar.search"), text: $query)
                .textFieldStyle(.roundedBorder)

            Picker(L10n.text("sidebar.filter"), selection: $filter) {
                ForEach(MeetingSidebarFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)

            if width >= 270 {
                Toggle(L10n.text("sidebar.showArchived"), isOn: $vm.showArchivedMeetings)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(EchoPilotTheme.secondaryText)
            }

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
                        Text(L10n.text("sidebar.empty.title"))
                            .font(.headline)
                        Text(L10n.text("sidebar.empty.subtitle"))
                            .font(.caption)
                            .foregroundStyle(EchoPilotTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
        }
        .padding(width < 270 ? 12 : 16)
        .frame(width: width)
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
                        meeting.isFullyTranscribed ? L10n.text("sidebar.status.ready") : L10n.text("sidebar.status.open"),
                        tone: meeting.isFullyTranscribed ? .success : .warning,
                        systemImage: meeting.isFullyTranscribed ? "checkmark" : "text.badge.plus"
                    )
                    if meeting.isArchived {
                        StatusChip(L10n.text("sidebar.filter.archived"), tone: .neutral, systemImage: "archivebox")
                    }
                    if meeting.pendingTranscriptCount > 0 {
                        StatusChip(L10n.format("sidebar.openCount", meeting.pendingTranscriptCount), tone: .warning)
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
            Button(meeting.isArchived ? L10n.text("sidebar.unarchive") : L10n.text("sidebar.archive"), action: archive)
            Button(L10n.text("sidebar.delete"), role: .destructive, action: delete)
        }
    }
}
