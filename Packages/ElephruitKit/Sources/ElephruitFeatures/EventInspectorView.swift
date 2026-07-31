import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One event, and everything Elephruit knows about it that the calendar does not.
///
/// ### Why this is the distinguishing half of the module
/// A calendar tells you a meeting is at three. It cannot tell you what you promised the last time,
/// what has changed in the person's life since, which project the meeting is really about, or what
/// you decided when it was over. All of that already exists in this library; the inspector is where
/// the two halves meet.
///
/// **Everything on this side is local.** Nothing here is ever written into the calendar event —
/// there is no path from a linked person to an `EventDraft`, which is what makes the guarantee
/// structural rather than careful. A meeting on a work Exchange calendar can carry a private note
/// about somebody's illness and their employer will never see it.
public struct EventInspectorView: View {
    @Environment(\.services) private var services

    let event: CalendarEventSummary

    @State private var annotation: EventAnnotation?
    @State private var linkedPeople: [Item] = []
    @State private var linkedNotes: [Item] = []
    @State private var linkedProjects: [Item] = []
    @State private var priorMeetings: [Item] = []
    @State private var isShowingPersonPicker = false
    @State private var isShowingFollowUp = false
    @State private var debriefText = ""
    @State private var preparationText = ""

    var onOpenItem: (UUID) -> Void

    public init(event: CalendarEventSummary, onOpenItem: @escaping (UUID) -> Void) {
        self.event = event
        self.onOpenItem = onOpenItem
    }

    /// Whether the active Calendar Set wants private context on screen at all.
    private var showsPersonContext: Bool {
        services?.calendar.activeSet?.showsPersonContext ?? true
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                header
                facts

                if showsPersonContext {
                    people
                    if !priorMeetings.isEmpty { history }
                    notes
                    debrief
                } else {
                    hiddenContextNotice
                }

                provenance
            }
            .padding(Theme.Spacing.medium)
        }
        .task(id: event.id) { await load() }
        .sheet(isPresented: $isShowingPersonPicker) {
            EventPersonPicker(event: event) { Task { await load() } }
        }
        .sheet(isPresented: $isShowingFollowUp) {
            FollowUpSheet(event: event, people: linkedPeople) { Task { await load() } }
        }
        .accessibilityIdentifier(AccessibilityID.Calendar.inspector)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(spacing: Theme.Spacing.small) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.EventStyle.accent(colorName: event.calendarColorName))
                    .frame(width: 4, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.displayTitle)
                        .font(Theme.Text.title)
                        .lineLimit(3)

                    if let calendar = event.calendarName {
                        Text(accountLine(calendar: calendar))
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
            }

            Text(whenLine)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.primaryText)

            if let dual = dualZoneLine {
                Text(dual)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            if !event.isEditable {
                Label("Read-only", systemImage: "lock")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func accountLine(calendar: String) -> String {
        guard let account = event.accountName, !account.isEmpty else { return calendar }
        return "\(calendar) · \(account)"
    }

    private var whenLine: String {
        guard let services else { return "" }
        let zone = services.calendar.timeZoneDisplay.displayZone

        var dayStyle = Date.FormatStyle().weekday(.wide).day().month(.wide)
        dayStyle.timeZone = zone

        if event.isAllDay {
            let days = event.days(in: services.calendar.displayCalendar)
            guard days.count > 1, let first = days.first, let last = days.last else {
                return "All day · \(event.startAt.formatted(dayStyle))"
            }
            return "All day · \(first.formatted(dayStyle)) – \(last.formatted(dayStyle))"
        }

        let time = event.timeSummary(in: zone, calendar: services.calendar.displayCalendar)
        return "\(event.startAt.formatted(dayStyle)) · \(time)"
    }

    /// "3:00 PM for you · 1:00 PM for Maya" — shown only when it says something.
    private var dualZoneLine: String? {
        guard let services else { return nil }
        let display = services.calendar.timeZoneDisplay

        // The event's own zone first, then a linked person's, then the secondary ruler's.
        if let zone = event.timeZone, zone.identifier != display.displayZone.identifier {
            return display.dualLabel(
                for: event.startAt,
                otherZone: zone,
                otherLabel: EventPhraseParser.shortZoneName(zone.identifier)
            )
        }

        for person in linkedPeople {
            guard let identifier = person.personProfile?.timeZoneIdentifier,
                  let zone = TimeZone(identifier: identifier)
            else { continue }

            let name = person.displayTitle.split(separator: " ").first.map(String.init) ?? person.displayTitle
            if let label = display.dualLabel(for: event.startAt, otherZone: zone, otherLabel: name) {
                return label
            }
        }

        guard let secondary = display.secondaryZone else { return nil }
        return display.dualLabel(
            for: event.startAt,
            otherZone: secondary,
            otherLabel: EventPhraseParser.shortZoneName(secondary.identifier)
        )
    }

    // MARK: Facts

    @ViewBuilder
    private var facts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let location = event.locationName, !location.isEmpty {
                InspectorRow("Where") {
                    Text(location)
                        .font(Theme.Text.rowSubtitle)
                        .textSelection(.enabled)
                }
            }

            if let url = event.url {
                InspectorRow("Link") {
                    Link(url.absoluteString, destination: url)
                        .font(Theme.Text.rowSubtitle)
                        .lineLimit(1)
                }
            }

            if let recurrence = event.recurrence {
                InspectorRow("Repeats") {
                    Text(recurrence.summary)
                        .font(Theme.Text.rowSubtitle)
                }
            } else if event.isRecurring {
                InspectorRow("Repeats") {
                    Text(event.isDetached ? "Part of a series, edited on its own" : "Part of a series")
                        .font(Theme.Text.rowSubtitle)
                }
            }

            if !event.alarms.isEmpty {
                InspectorRow(event.alarms.count == 1 ? "Alert" : "Alerts") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(event.alarms) { alarm in
                            Text(alarm.displayName).font(Theme.Text.rowSubtitle)
                        }
                    }
                }
            }

            if event.availability != .busy, event.availability != .notSupported {
                InspectorRow("Shows as") {
                    Text(event.availability.displayName).font(Theme.Text.rowSubtitle)
                }
            }

            if let notes = event.notes, !notes.isEmpty {
                InspectorSection("From the calendar") {
                    Text(notes)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: People

    private var people: some View {
        InspectorSection("People") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(linkedPeople) { person in
                    EventPersonRow(person: person, isFromCalendar: false) {
                        onOpenItem(person.id)
                    } onUnlink: {
                        unlink(person)
                    }
                }

                // Attendees the calendar knows about who are not yet linked to anybody.
                ForEach(unmatchedAttendees, id: \.id) { attendee in
                    UnmatchedAttendeeRow(attendee: attendee) {
                        isShowingPersonPicker = true
                    }
                }

                if linkedPeople.isEmpty, unmatchedAttendees.isEmpty {
                    Text("Nobody linked yet.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Button("Link a person…") { isShowingPersonPicker = true }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
            }
        }
    }

    /// Attendees on the event that no CRM person is linked to.
    ///
    /// Matched by email first and name second, which is the order of certainty. An unmatched
    /// attendee is *offered*, never linked silently: two people called James Wilson is not a rare
    /// case, and picking one of them would attach somebody's private history to a stranger.
    private var unmatchedAttendees: [EventAttendee] {
        let linkedNames = Set(linkedPeople.map { TextNormalizer.foldedForMatching($0.displayTitle) })
        let linkedEmails = Set(
            linkedPeople.flatMap { $0.personProfile?.emails.map { ContactDetailRecognizer.normalizedEmail($0.value) } ?? [] }
        )

        return event.attendees.filter { attendee in
            guard !attendee.isCurrentUser else { return false }
            if let email = attendee.emailAddress,
               linkedEmails.contains(ContactDetailRecognizer.normalizedEmail(email)) {
                return false
            }
            return !linkedNames.contains(TextNormalizer.foldedForMatching(attendee.displayName))
        }
    }

    // MARK: History

    private var history: some View {
        InspectorSection("Before this") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(priorMeetings) { meeting in
                    Button {
                        onOpenItem(meeting.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(meeting.displayTitle)
                                .font(Theme.Text.rowSubtitle)
                                .lineLimit(1)
                            if let when = meeting.eventReference?.startAt {
                                Text(relativeLabel(when))
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(extending: Theme.Spacing.small)
                }
            }
        }
    }

    private func relativeLabel(_ date: Date) -> String {
        guard let services else { return "" }
        let days = services.dateProvider.calendar.dateComponents(
            [.day], from: date, to: services.dateProvider.now
        ).day ?? 0

        var style = Date.FormatStyle().day().month(.abbreviated).year()
        style.timeZone = services.calendar.timeZoneDisplay.displayZone

        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2...30: return "\(days) days ago"
        default: return date.formatted(style)
        }
    }

    // MARK: Notes and projects

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if !linkedProjects.isEmpty {
                InspectorSection("Projects") {
                    ForEach(linkedProjects) { project in
                        LinkedItemRow(item: project) { onOpenItem(project.id) }
                    }
                }
            }

            if !linkedNotes.isEmpty {
                InspectorSection("Notes") {
                    ForEach(linkedNotes) { note in
                        LinkedItemRow(item: note) { onOpenItem(note.id) }
                    }
                }
            }

            if let annotation, annotation.attachmentCount > 0 {
                InspectorRow("Files") {
                    Text("\(annotation.attachmentCount) attached")
                        .font(Theme.Text.rowSubtitle)
                }
            }
        }
    }

    // MARK: Preparation and debrief

    private var debrief: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            InspectorSection(isPast ? "Afterwards" : "Before the meeting") {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    TextEditor(text: isPast ? $debriefText : $preparationText)
                        .font(Theme.Text.rowSubtitle)
                        .frame(height: 84)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                                .strokeBorder(Theme.Colors.separator)
                        }

                    HStack {
                        Text("Kept in Elephruit. Never written to your calendar.")
                            .font(Theme.Text.keyHint)
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        Spacer()

                        Button("Save") { saveNotes() }
                            .buttonStyle(.borderless)
                            .font(Theme.Text.metadata)
                    }
                }
            }

            Button {
                isShowingFollowUp = true
            } label: {
                Label("Create a follow-up…", systemImage: "checkmark.circle")
                    .font(Theme.Text.metadata)
            }
            .buttonStyle(.borderless)
            .help("Adds a task in Tasks. It never appears in a calendar view.")
        }
    }

    private var isPast: Bool {
        guard let services else { return false }
        return event.endAt < services.dateProvider.now
    }

    /// Shown when the active set has private context switched off.
    private var hiddenContextNotice: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "eye.slash")
                .foregroundStyle(Theme.Colors.tertiaryText)
                .accessibilityHidden(true)

            Text("People and notes are hidden in this Calendar Set. Nothing has been deleted.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.small)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Provenance

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let created = event.createdAt {
                Text("Created \(created.formatted(date: .abbreviated, time: .shortened))")
            }
            if let modified = event.lastModifiedAt {
                Text("Last changed \(modified.formatted(date: .abbreviated, time: .shortened))")
            }
            if let organizer = event.organizerName {
                Text("Organised by \(organizer)")
            }
        }
        .font(Theme.Text.keyHint)
        .foregroundStyle(Theme.Colors.tertiaryText)
        .accessibilityElement(children: .combine)
    }

    // MARK: Loading

    private func load() async {
        guard let services else { return }

        let found = (try? services.eventLinks.annotation(for: event.identity)) ?? EventAnnotation(identity: event.identity)
        annotation = found

        linkedPeople = found.personIDs.compactMap { try? services.items.item(id: $0) }
        linkedNotes = found.noteIDs.compactMap { try? services.items.item(id: $0) }
        linkedProjects = found.projectIDs.compactMap { try? services.items.item(id: $0) }
        preparationText = found.preparationNotes
        debriefText = found.debriefNotes

        priorMeetings = (try? services.eventLinks.priorMeetings(
            withPeople: found.personIDs, before: event.startAt
        )) ?? []
    }

    private func unlink(_ person: Item) {
        guard let services else { return }
        services.perform { try services.eventLinks.unlink(person: person, from: event.identity) }
        Task { await load() }
    }

    private func saveNotes() {
        guard let services else { return }
        services.perform {
            if isPast {
                try services.eventLinks.setDebriefNotes(debriefText, for: event)
            } else {
                try services.eventLinks.setPreparationNotes(preparationText, for: event)
            }
        }
        Task { await load() }
    }
}

// MARK: - Rows

/// A person linked to this event.
private struct EventPersonRow: View {
    let person: Item
    let isFromCalendar: Bool
    var onOpen: () -> Void
    var onUnlink: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            PersonAvatar(name: person.displayTitle, colorName: person.colorName, size: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(person.displayTitle)
                    .font(Theme.Text.rowSubtitle)
                    .lineLimit(1)

                if let local = localTime {
                    Text(local)
                        .font(Theme.Text.keyHint)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            Spacer(minLength: 0)

            Button(action: onUnlink) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .accessibilityLabel("Unlink \(person.displayTitle)")
        }
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .hoverHighlight(extending: Theme.Spacing.small)
        .accessibilityElement(children: .combine)
    }

    /// "It is 4:12 pm there" — only when it differs from here.
    private var localTime: String? {
        person.personProfile?.localTime(at: Date())
    }
}

/// Somebody on the invitation who is not yet linked to a person in the library.
private struct UnmatchedAttendeeRow: View {
    let attendee: EventAttendee
    var onLink: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(attendee.initials)
                .font(Theme.Text.keyHint)
                .frame(width: 22, height: 22)
                .background { Circle().fill(Theme.Colors.subtleFill) }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(attendee.displayName)
                    .font(Theme.Text.rowSubtitle)
                    .lineLimit(1)
                Text(statusLine)
                    .font(Theme.Text.keyHint)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            Spacer(minLength: 0)

            Button("Link", action: onLink)
                .buttonStyle(.borderless)
                .font(Theme.Text.keyHint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attendee.displayName), on the invitation, not yet linked")
    }

    private var statusLine: String {
        var parts = ["from the invitation"]
        switch attendee.participation {
        case .accepted: parts.append("accepted")
        case .declined: parts.append("declined")
        case .tentative: parts.append("maybe")
        case .pending: parts.append("no reply")
        case .unknown: break
        }
        return parts.joined(separator: " · ")
    }
}

/// A note or project linked to this event.
private struct LinkedItemRow: View {
    let item: Item
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: item.effectiveSymbolName)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Palette.color(named: item.colorName))
                    .frame(width: Theme.Size.rowGlyph)

                Text(item.displayTitle)
                    .font(Theme.Text.rowSubtitle)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(extending: Theme.Spacing.small)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Linking a person

/// Choosing somebody to link to an event.
struct EventPersonPicker: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let event: CalendarEventSummary
    var onLinked: () -> Void

    @State private var query = ""
    @State private var candidates: [Item] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Link a person to “\(event.displayTitle)”")
                .font(Theme.Text.title)
                .lineLimit(2)

            TextField("Search people", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, _ in search() }

            if candidates.isEmpty {
                Text(query.isEmpty ? "Start typing a name." : "Nobody matches “\(query)”.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { person in
                            Button { link(person) } label: {
                                HStack(spacing: Theme.Spacing.small) {
                                    PersonAvatar(
                                        name: person.displayTitle, colorName: person.colorName, size: 22
                                    )
                                    Text(person.displayTitle)
                                        .font(Theme.Text.rowSubtitle)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .hoverHighlight(extending: Theme.Spacing.small)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Text("The link is kept in Elephruit. It is never added to the calendar event.")
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.tertiaryText)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 380)
        .task { seedFromAttendees() }
    }

    /// Offers the event's own attendees first, since they are who somebody is most likely to want.
    private func seedFromAttendees() {
        guard let services else { return }
        let names = event.attendeeNames
        guard !names.isEmpty else { return }

        let all = (try? services.persons.allPeople(includingPlaceholders: false)) ?? []
        candidates = all.filter { person in
            names.contains { TextNormalizer.foldedForMatching($0) == TextNormalizer.foldedForMatching(person.displayTitle) }
        }
    }

    private func search() {
        guard let services, !query.isEmpty else {
            seedFromAttendees()
            return
        }
        let all = (try? services.persons.allPeople(includingPlaceholders: false)) ?? []
        let folded = TextNormalizer.foldedForMatching(query)
        candidates = all.filter { TextNormalizer.foldedForMatching($0.displayTitle).contains(folded) }
    }

    private func link(_ person: Item) {
        guard let services else { return }
        services.perform { try services.eventLinks.link(person: person, to: event) }
        onLinked()
        dismiss()
    }
}

// MARK: - Follow-ups

/// Creating a task about a meeting.
///
/// The task lands in Tasks and **never appears in a calendar view**. A calendar that lists its own
/// follow-ups turns into a to-do list with dates, which is a different and worse product.
struct FollowUpSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let event: CalendarEventSummary
    let people: [Item]
    var onCreated: () -> Void

    @State private var title = ""
    @State private var hasDueDate = true
    @State private var dueAt = Date()
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Follow up on “\(event.displayTitle)”")
                .font(Theme.Text.title)
                .lineLimit(2)

            TextField("What needs doing?", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .onSubmit(create)

            Toggle("Due", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("", selection: $dueAt, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }

            if !people.isEmpty {
                Text("Linked to \(people.map(\.displayTitle).formatted(.list(type: .and)))")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Text("Appears in Tasks. Never in a calendar view.")
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.tertiaryText)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 400)
        .onAppear {
            isTitleFocused = true
            dueAt = services?.dateProvider.startOfTomorrow ?? Date()
        }
    }

    private func create() {
        guard let services else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            let task = try services.eventLinks.createFollowUp(
                title: trimmed,
                dueAt: hasDueDate ? dueAt : nil,
                for: event,
                aboutPeople: people
            )
            services.noteChange(to: task)
        }
        onCreated()
        dismiss()
    }
}
