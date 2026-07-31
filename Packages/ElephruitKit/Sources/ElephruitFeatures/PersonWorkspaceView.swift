import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One person's page: who they are, what is true about them, and everything that has happened.
///
/// ### Why this replaced `PersonDetailView` rather than growing out of it
/// The old view was explicitly "the smallest form worth shipping" and said so in its own doc comment.
/// It showed a summary line, an editor, and two unmerged lists. What is needed instead is a
/// *portrait* — structured facts that say how sure they are — above a merged history, and that is a
/// different shape rather than more of the same one.
///
/// ### Progressive disclosure, not a form
/// Cards appear only when they hold something. An empty person is a name, an invitation to add a
/// fact, and nothing else — not fourteen empty fields implying homework. Every card is inline-
/// editable in place; nothing opens a sheet to change one line.
struct PersonWorkspaceView: View {
    @Environment(\.services) private var services

    let person: Item
    let navigation: NavigationModel

    @Binding var title: String
    @Binding var bodyText: String

    @State private var portrait: PersonPortrait?
    @State private var timeline: [PersonTimelineEntry] = []
    @State private var timelineFilter: TimelineGrouping.Filter = .everything
    @State private var isRecordingInteraction = false
    @State private var isAddingFact = false
    @State private var isShowingBrief = false
    @State private var chartKind: RelationshipChartKind?
    @State private var pendingAction: ContactActionRequest?
    @State private var correctionTarget: PortraitValue?
    @State private var loadFailure: AppError?

    var body: some View {
        VStack(spacing: 0) {
            PersonHeaderView(
                person: person,
                portrait: portrait,
                title: $title,
                onAction: { pendingAction = $0 },
                onRecordInteraction: { isRecordingInteraction = true },
                onShowBrief: { isShowingBrief = true }
            )

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.section, pinnedViews: []) {
                    if let loadFailure {
                        FailureStateView(error: loadFailure) { _ in reload() }
                            .padding(.horizontal, Theme.Spacing.large)
                    }

                    PersonPortraitSection(
                        person: person,
                        portrait: portrait,
                        bodyText: $bodyText,
                        onAddFact: { isAddingFact = true },
                        onConfirm: confirm(_:),
                        onCorrect: { correctionTarget = $0 },
                        onOpenSource: { navigation.selectItem($0) }
                    )

                    PersonRelationshipsSection(
                        person: person,
                        onOpenChart: { chartKind = $0 },
                        onOpenPerson: { navigation.selectItem($0) }
                    )

                    PersonTimelineSection(
                        entries: timeline,
                        filter: $timelineFilter,
                        dateProvider: services?.dateProvider ?? SystemDateProvider(),
                        onOpen: { navigation.selectItem($0) }
                    )
                }
                .padding(.vertical, Theme.Spacing.large)
            }
        }
        .accessibilityIdentifier(AccessibilityID.People.workspace)
        .task(id: person.id) { reload() }
        .onChange(of: person.updatedAt) { _, _ in reload() }
        .sheet(isPresented: $isRecordingInteraction) {
            RecordInteractionSheet(
                personName: person.displayTitle,
                onSave: { summary, notes, date in
                    record(summary: summary, notes: notes, at: date)
                    isRecordingInteraction = false
                },
                onCancel: { isRecordingInteraction = false }
            )
        }
        .sheet(isPresented: $isAddingFact) {
            AddFactSheet(
                personName: person.displayTitle,
                onSave: { draft, confidence, sensitivity, observedOn in
                    addFact(draft, confidence: confidence, sensitivity: sensitivity, observedOn: observedOn)
                    isAddingFact = false
                },
                onCancel: { isAddingFact = false }
            )
        }
        .sheet(isPresented: $isShowingBrief) {
            MeetingBriefSheet(person: person) { navigation.selectItem($0) }
        }
        .sheet(item: $chartKind) { kind in
            RelationshipChartSheet(person: person, initialKind: kind) { id in
                chartKind = nil
                navigation.selectItem(id)
            }
        }
        .sheet(item: $correctionTarget) { value in
            CorrectFactSheet(
                value: value,
                onSave: { newValue, note in
                    correct(value, to: newValue, note: note)
                    correctionTarget = nil
                },
                onCancel: { correctionTarget = nil }
            )
        }
        .sheet(item: $pendingAction) { request in
            ContactActionConfirmationSheet(request: request) { outcome in
                pendingAction = nil
                if case .performed(let channel, let destination) = outcome {
                    logInitiatedContact(channel: channel, destination: destination)
                }
            }
        }
    }

    // MARK: - Loading

    private func reload() {
        guard let services else { return }
        services.noteViewed(person: person)

        do {
            portrait = try services.personWorkspace.portrait(of: person)
            timeline = try services.personWorkspace.timeline(for: person)
            loadFailure = nil
        } catch {
            // A page that cannot assemble says so and offers a retry, rather than looking empty —
            // an empty person and a failed read are different states and must not look alike.
            loadFailure = error
            Diagnostics.features.error("Could not assemble a person's page: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Actions

    private func record(summary: String, notes: String, at date: Date) {
        guard let services else { return }
        services.perform {
            let interaction = try services.people.recordInteraction(
                with: person, summary: summary, at: date, notes: notes
            )
            // Written down by hand, so it counts as contact — see `InteractionProvenance`.
            try services.items.update(interaction) { $0.sourceIdentifier = InteractionProvenance.logged.rawValue }
            services.noteChange(to: interaction)
        }
        reload()
    }

    private func addFact(
        _ draft: ObservationDraft,
        confidence: FactConfidence,
        sensitivity: FactSensitivity,
        observedOn: Date
    ) {
        guard let services else { return }
        services.perform {
            try services.persons.record(
                draft, about: person, observedOn: observedOn,
                confidence: confidence, sensitivity: sensitivity, source: nil
            )
        }
        reload()
    }

    private func confirm(_ value: PortraitValue) {
        guard let services else { return }
        services.perform {
            guard let record = try services.persons.observations(for: person)
                .first(where: { $0.id == value.observationID })
            else { return }
            try services.persons.confirm(record)
        }
        reload()
    }

    private func correct(_ value: PortraitValue, to newValue: String, note: String?) {
        guard let services else { return }
        services.perform {
            guard let record = try services.persons.observations(for: person)
                .first(where: { $0.id == value.observationID })
            else { return }
            try services.persons.correct(record, to: newValue, note: note)
        }
        reload()
    }

    /// Records that the user *started* reaching somebody — never that they spoke.
    ///
    /// The app saw a button press and nothing more. Recording "spoke to Maya" on that basis would put
    /// a fact in the timeline nobody stated, and the last-contact line is only worth having because
    /// it is never wrong in that direction.
    private func logInitiatedContact(channel: ContactChannel, destination: ContactDestination) {
        guard let services else { return }
        services.perform {
            let interaction = try services.people.recordInteraction(
                with: person,
                summary: "\(channel.displayName) started",
                at: services.dateProvider.now
            )
            try services.items.update(interaction) { subject in
                subject.sourceIdentifier = InteractionProvenance.initiated.rawValue
                subject.sourceURLString = ContactActionURL.url(for: channel, destination: destination.value)?
                    .absoluteString
            }
            services.noteChange(to: interaction)
        }
        reload()
    }
}

// MARK: - Header

/// Photo or initials, name, pronunciation, pronouns, context, local time, and the quick actions.
struct PersonHeaderView: View {
    @Environment(\.services) private var services

    let person: Item
    let portrait: PersonPortrait?
    @Binding var title: String

    let onAction: (ContactActionRequest) -> Void
    let onRecordInteraction: () -> Void
    let onShowBrief: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                PersonAvatar(name: person.displayTitle, colorName: person.colorName, size: 52)

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    HStack(spacing: Theme.Spacing.small) {
                        TextField("Name", text: $title)
                            .textFieldStyle(.plain)
                            .font(Theme.Text.title)
                            .disabled(person.isInTrash)
                            .accessibilityLabel("Name")

                        if let pronouns = profile?.pronouns, !pronouns.isEmpty {
                            Text(pronouns)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .padding(.horizontal, Theme.Spacing.tight)
                                .padding(.vertical, 1)
                                .background(Theme.Colors.subtleFill, in: Capsule())
                                .accessibilityLabel("Pronouns: \(pronouns)")
                        }

                        Button {
                            toggleFavorite()
                        } label: {
                            Image(systemName: person.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(person.isFavorite ? Theme.Colors.dueToday : Theme.Colors.secondaryText)
                        }
                        .buttonStyle(.borderless)
                        .help(person.isFavorite ? "Remove from Favourites" : "Add to Favourites")
                        .accessibilityLabel(person.isFavorite ? "Remove from favourites" : "Add to favourites")
                    }

                    if let pronunciation = profile?.pronunciation, !pronunciation.isEmpty {
                        Label("said “\(pronunciation)”", systemImage: "waveform")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .labelStyle(.titleAndIcon)
                    }

                    ContextLine(facts: contextFacts)

                    if let relationship = relationshipLine {
                        Text(relationship)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }

                Spacer(minLength: Theme.Spacing.small)
            }

            PersonQuickActions(
                person: person,
                onAction: onAction,
                onRecordInteraction: onRecordInteraction,
                onShowBrief: onShowBrief
            )
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.People.header)
    }

    private var profile: PersonProfile? { person.personProfile }

    /// Company and role, location, local time, last contact, next important date.
    private var contextFacts: [String] {
        var facts: [String] = []

        let role = [profile?.roleTitle, profile?.organizationName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !role.isEmpty { facts.append(role.joined(separator: " · ")) }

        if let location = profile?.locationText, !location.isEmpty {
            // The local time joins the place rather than sitting on its own line — it is a property
            // of where somebody is, and only shown when it differs from here.
            let now = services?.dateProvider.now ?? Date()
            if let localTime = profile?.localTime(at: now) {
                facts.append("\(location) · \(localTime) there")
            } else {
                facts.append(location)
            }
        }

        if let line = portrait?.ageAndGradeLine {
            facts.append(portrait?.ageAndGradeIsEstimate == true ? line : line)
        }

        if let context = services?.people.context(for: person),
           let provider = services?.dateProvider {
            facts.append(context.summary(using: provider))
        }

        return facts
    }

    private var relationshipLine: String? {
        guard let services, let relationships = try? services.persons.relationships(of: person) else { return nil }
        let closest = relationships.prefix(3).compactMap { relationship -> String? in
            guard let other = relationship.other else { return nil }
            return "\(relationship.displayLabel) of \(other.displayTitle)"
        }
        return closest.isEmpty ? nil : closest.joined(separator: " · ")
    }

    private func toggleFavorite() {
        guard let services else { return }
        services.perform { try services.items.update(person) { $0.isFavorite.toggle() } }
        services.refreshDerivedState()
    }
}

/// Initials in a tinted circle. No photo is stored, and none is read from Contacts.
///
/// Contact photos are the largest thing Contacts holds and the app displays none of them, so the key
/// is never fetched — see `ContactsWriteSafetyTests`. Initials are legible, cost nothing, and cannot
/// leak.
struct PersonAvatar: View {
    let name: String
    let colorName: String?
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(Theme.Palette.color(named: colorName).opacity(0.18))
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.Palette.color(named: colorName))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

// MARK: - Quick actions

/// Call, message, email, FaceTime, schedule, note, task, record.
///
/// Every one that reaches another person routes through ``ContactActionConfirmationSheet`` rather
/// than firing on click. A disabled button says *why* in its help text — "no phone number recorded" —
/// because a control that is simply grey is indistinguishable from one that is broken.
struct PersonQuickActions: View {
    @Environment(\.services) private var services

    let person: Item
    let onAction: (ContactActionRequest) -> Void
    let onRecordInteraction: () -> Void
    let onShowBrief: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            actionRow
            ScrollView(.horizontal, showsIndicators: false) { actionRow }
        }
        .accessibilityIdentifier(AccessibilityID.People.quickActions)
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(ContactChannel.allCases) { channel in
                let available = destinations(for: channel)
                Button {
                    onAction(ContactActionRequest(channel: channel, person: person, destinations: available))
                } label: {
                    Label(channel.displayName, systemImage: channel.symbolName)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(available.isEmpty)
                .help(available.isEmpty ? "No \(channel.destinationNoun) recorded" : channel.displayName)
                .accessibilityLabel(channel.displayName)
                .accessibilityHint(available.isEmpty ? "No \(channel.destinationNoun) recorded" : "")
            }

            Divider().frame(height: 16)

            Button {
                onRecordInteraction()
            } label: {
                Label("Record", systemImage: "text.bubble")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("Record a conversation")
            .accessibilityLabel("Record a conversation")
            .accessibilityIdentifier(AccessibilityID.People.recordInteraction)

            Button {
                onShowBrief()
            } label: {
                Label("Brief", systemImage: "list.bullet.rectangle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("Meeting brief")
            .accessibilityLabel("Meeting brief")
            .accessibilityIdentifier(AccessibilityID.People.meetingBrief)

            Button {
                createTask()
            } label: {
                Label("Task", systemImage: "checkmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("New task about \(person.displayTitle)")
            .accessibilityLabel("New task")
        }
    }

    private func destinations(for channel: ContactChannel) -> [ContactDestination] {
        ContactDestinationPolicy.candidates(
            for: channel,
            from: person.personProfile?.destinations() ?? []
        )
    }

    private func createTask() {
        guard let services else { return }
        services.perform {
            let task = try services.items.create(
                ItemDraft(kind: .task, title: "Follow up with \(person.displayTitle)")
            )
            try services.items.link(task, to: person, kind: .mentions)
            services.noteChange(to: task)
        }
    }
}
