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
    @State private var isAddingNote = false
    @State private var isAddingFact = false
    @State private var quickFactSeed: QuickFactSeed?
    @State private var isShowingBrief = false
    @State private var chartKind: RelationshipChartKind?
    @State private var pendingAction: ContactActionRequest?
    @State private var correctionTarget: PortraitValue?
    @State private var deletionTarget: PortraitValue?
    @State private var isEditingContactDetails = false
    @State private var pendingWriteBack: ContactDetailsEdit?
    @State private var loadFailure: AppError?
    @State private var isAddingRelationship = false
    @State private var presentedTimelineEntry: PersonTimelineEntry?

    /// The widest the profile's content is drawn, however wide its column becomes.
    static let measure: CGFloat = 860

    var body: some View {
        VStack(spacing: 0) {
            PersonHeaderView(
                person: person,
                portrait: portrait,
                title: $title,
                // Passed in rather than fetched again: the workspace has already loaded the
                // timeline, and a brief assembled from nothing is a heading and three empty
                // sections — which is worse than the action being off and saying so.
                hasHistory: !timeline.isEmpty,
                onAction: { pendingAction = $0 },
                onAddNote: { isAddingNote = true },
                onRecordInteraction: { isRecordingInteraction = true },
                onShowBrief: { isShowingBrief = true },
                onAddRelationship: { isAddingRelationship = true }
            )
            // The same measure as the content below it, so the name, the actions and the first
            // section under them share one left edge and one right edge. The divider still spans the
            // column, because what it separates is the whole header from the whole page.
            .frame(maxWidth: Self.measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

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
                        onAddFact: { seed in
                            quickFactSeed = seed
                            isAddingFact = true
                        },
                        onConfirm: confirm(_:),
                        onCorrect: { correctionTarget = $0 },
                        onDelete: { deletionTarget = $0 },
                        onOpenSource: { navigation.selectItem($0) }
                    )

                    PersonContactSection(
                        person: person,
                        onAction: { pendingAction = $0 },
                        onEdit: { isEditingContactDetails = true }
                    )

                    PersonRelationshipsSection(
                        person: person,
                        onOpenChart: { chartKind = $0 },
                        onOpenPerson: { navigation.selectItem($0) }
                    )

                    // Collapsed by default. Where a detail came from is worth being able to find and
                    // not worth scrolling past to reach what somebody wrote about a friend.
                    LinkedContactSection(person: person)

                    PersonTimelineSection(
                        entries: timeline,
                        filter: $timelineFilter,
                        dateProvider: services?.dateProvider ?? SystemDateProvider(),
                        onOpen: { id in
                            presentedTimelineEntry = timeline.first(where: { $0.id == id })
                        }
                    )
                }
                .padding(.vertical, Theme.Spacing.large)
                // ### Why the profile has a measure of its own
                // Because its column has no maximum — see `AppModule.shellLayout` — so the profile
                // is what absorbs whatever a window has spare. That is the right shape for the
                // column and the wrong shape for the content: a contact row whose label sits at the
                // far left and whose value sits eighteen hundred points away is not a wide row, it
                // is two rows the eye has to join.
                //
                // So the column takes the width and the content declines it past this point. Wider
                // than the note editor's eighty characters, because a profile is a grid of short
                // facts rather than prose and its relationship cards want room to sit two or three
                // abreast; narrow enough that nothing inside it has to be read across a desk.
                .frame(maxWidth: Self.measure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier(AccessibilityID.People.workspace)
        .task(id: person.id) { reload() }
        .onChange(of: person.updatedAt) { _, _ in reload() }
        // Most of this page is *other* items pointing at this person, and writing one of those
        // leaves the person's own row untouched — so `updatedAt` above cannot see it. A task added
        // from the quick actions, from the command bar, or from a capture belongs in the timeline
        // the moment it exists, not the next time somebody navigates back here.
        .onChange(of: services?.changeToken) { _, _ in reload() }
        .sheet(isPresented: $isRecordingInteraction) {
            LogInteractionSheet(
                person: person,
                onSave: { draft in
                    record(draft)
                    isRecordingInteraction = false
                },
                onCancel: { isRecordingInteraction = false }
            )
        }
        .sheet(item: $presentedTimelineEntry) { entry in
            PersonTimelineDetailSheet(
                entry: entry,
                personID: person.id,
                personName: person.displayTitle,
                onClose: {
                    presentedTimelineEntry = nil
                    reload()
                }
            )
        }
        .sheet(isPresented: $isAddingNote) {
            PersonNoteSheet(
                personName: person.displayTitle,
                onSave: { draft in
                    saveNote(draft)
                    isAddingNote = false
                },
                onCancel: { isAddingNote = false }
            )
        }
        .sheet(isPresented: $isAddingFact) {
            AddFactSheet(
                personName: person.displayTitle,
                seed: quickFactSeed,
                onSave: { draft, confidence, sensitivity, observedOn in
                    addFact(draft, confidence: confidence, sensitivity: sensitivity, observedOn: observedOn)
                    quickFactSeed = nil
                    isAddingFact = false
                },
                onCancel: {
                    quickFactSeed = nil
                    isAddingFact = false
                }
            )
        }
        .sheet(isPresented: $isShowingBrief) {
            MeetingBriefSheet(person: person) { navigation.selectItem($0) }
        }
        .sheet(isPresented: $isAddingRelationship) {
            AddRelationshipSheet(person: person) { isAddingRelationship = false }
        }
        .sheet(item: $chartKind) { kind in
            RelationshipChartSheet(person: person, initialKind: kind) { id in
                chartKind = nil
                navigation.selectItem(id)
            }
        }
        .sheet(isPresented: $isEditingContactDetails, onDismiss: { pendingWriteBack = nil }) {
            // One sheet owns the whole transaction. Dismissing the editor and racing to present a
            // second sheet could lose the write-back prompt while SwiftUI was still completing the
            // first dismissal, which made a linked edit look saved while Contacts kept the old value.
            if let edit = pendingWriteBack {
                ContactWriteBackSheet(person: person, edit: edit) {
                    pendingWriteBack = nil
                    isEditingContactDetails = false
                }
            } else {
                EditContactDetailsSheet(
                    person: person,
                    onSave: { edit in
                        reload()
                        offerContactWriteBack(for: edit)
                    },
                    onCancel: { isEditingContactDetails = false }
                )
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
        .confirmationDialog(
            "Delete this quick fact?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Quick Fact", role: .destructive) {
                if let deletionTarget { deleteFact(deletionTarget) }
                deletionTarget = nil
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("This removes the selected value from (person.displayTitle).")
        }
    }

    // MARK: - Loading

    /// Offers the address-book write only when it can actually be performed.
    ///
    /// A Contacts identifier survives permission being revoked and the integration being switched
    /// off, because the local person and their imported details survive too. The identifier alone
    /// therefore cannot decide whether to show a write prompt. Re-reading macOS authorization here
    /// also avoids trusting the state captured when the app launched.
    private func offerContactWriteBack(for edit: ContactDetailsEdit) {
        guard let services, person.personProfile?.contactsIdentifier != nil else {
            isEditingContactDetails = false
            return
        }

        Task {
            await services.contacts.refreshAuthorization()
            guard services.contacts.isEnabled, services.contacts.authorization.canRead else {
                isEditingContactDetails = false
                return
            }
            pendingWriteBack = edit
        }
    }

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

    private func record(_ draft: PersonInteractionDraft) {
        guard let services else { return }
        services.perform {
            let created = try services.people.recordInteractionBundle(
                with: interactionParticipants(for: draft, services: services),
                summary: draft.cleanedSummary,
                kind: draft.kind,
                at: draft.occurredAt,
                discussion: draft.cleanedDiscussion,
                followUps: draft.followUpItems,
                commitments: draft.commitmentItems
            )
            for item in created { services.noteChange(to: item) }
        }
        reload()
    }

    private func interactionParticipants(for draft: PersonInteractionDraft, services: AppServices) -> [Item] {
        draft.participantIDs.compactMap { id in
            try? services.persons.person(id: id)
        }
    }

    private func saveNote(_ draft: PersonNoteDraft) {
        guard let services else { return }
        services.perform {
            let note = try services.items.create(
                ItemDraft(
                    kind: .note,
                    title: draft.resolvedTitle(personName: person.displayTitle),
                    body: draft.cleanedBody,
                    tagSlugs: draft.tagSlugs
                )
            )
            try services.items.link(note, to: person, kind: .mentions)
            services.noteChange(to: note)
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

    private func deleteFact(_ value: PortraitValue) {
        guard let services else { return }
        services.perform {
            guard let record = try services.persons.observations(for: person)
                .first(where: { $0.id == value.observationID })
            else { return }
            try services.persons.remove(record)
            services.noteChange(to: person)
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

    let hasHistory: Bool

    let onAction: (ContactActionRequest) -> Void
    let onAddNote: () -> Void
    let onRecordInteraction: () -> Void
    let onShowBrief: () -> Void
    let onAddRelationship: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                PersonAvatar(name: person.displayTitle, colorName: person.colorName, size: 52)

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    HStack(spacing: Theme.Spacing.small) {
                        TextField("Name", text: $title)
                            .textFieldStyle(.plain)
                            .font(Theme.Text.title)
                            .tracking(Theme.Text.Tracking.title)
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
                                .foregroundStyle(person.isFavorite ? Theme.Colors.favorite : Theme.Colors.secondaryText)
                        }
                        .buttonStyle(.borderless)
                        .help(person.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        .accessibilityLabel(person.isFavorite ? "Remove from favorites" : "Add to favorites")
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

                    if let historyLine {
                        Text(historyLine)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }

                Spacer(minLength: Theme.Spacing.small)
            }

            PersonQuickActions(
                person: person,
                hasHistory: hasHistory,
                onAction: onAction,
                onAddNote: onAddNote,
                onRecordInteraction: onRecordInteraction,
                onShowBrief: onShowBrief,
                onAddRelationship: onAddRelationship
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

        return facts
    }

    /// Your history with this person, as its own line.
    ///
    /// It used to be appended to ``contextFacts`` and joined with the rest by a middle dot, which
    /// produced "Structural engineer · Austin · Nothing recorded yet" — one run-on line mixing two
    /// unrelated kinds of fact. The first two say *who this person is*; the third says *what has
    /// passed between you and them*, and reading them as a single series invites the eye to take
    /// "nothing recorded yet" as another attribute of Sam rather than a statement about the record.
    ///
    /// Separated, each line has one subject, and the quieter type says which of the two is
    /// background.
    private var historyLine: String? {
        guard let context = services?.people.context(for: person),
              let provider = services?.dateProvider
        else { return nil }
        return context.summary(using: provider)
    }

    private var relationshipLine: String? {
        guard let services, let relationships = try? services.persons.relationships(of: person) else { return nil }
        // "son Jack Chen", not "son of Jack Chen". The label describes what the *other* person is to
        // this one, so "of" inverts it and reads as though Maya were Jack's son.
        let closest = relationships.prefix(3).compactMap { relationship -> String? in
            guard let other = relationship.other else { return nil }
            return "\(relationship.displayLabel) \(other.displayTitle)"
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
///
/// ### Why it watches the row's prominence
/// The palette tint is a pale wash with the same colour written over it, which is legible on the
/// list's own background and nowhere near legible on the accent fill of a selected row — the circle
/// all but vanishes and the initials go muddy. On a selected row the avatar drops the colour and
/// borrows the system's own selected-row styles, which resolve against whatever accent the user
/// chose. This is the ``SwiftUICore/View/rowForeground(_:)`` rule applied to a shape: the colour is
/// worth less than being readable, and it comes straight back the moment the row is deselected.
struct PersonAvatar: View {
    @Environment(\.backgroundProminence) private var prominence

    let name: String
    let colorName: String?
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(fill)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .medium, design: .rounded))
                    .foregroundStyle(foreground)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// True only while the row is selected *and* the window is focused — the same condition under
    /// which the row is painted with the accent colour rather than an inert grey.
    private var isOnSelectedRow: Bool { prominence == .increased }

    private var fill: AnyShapeStyle {
        isOnSelectedRow
            ? AnyShapeStyle(.quaternary)
            : AnyShapeStyle(Theme.Palette.color(named: colorName).opacity(0.18))
    }

    private var foreground: AnyShapeStyle {
        isOnSelectedRow
            ? AnyShapeStyle(.primary)
            : AnyShapeStyle(Theme.Palette.color(named: colorName))
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

// MARK: - Quick actions

/// The actions a person's record can actually support, in the order that record makes sensible.
///
/// ### What this used to be
/// Ten bordered icon-only buttons in a fixed row — telephone, speech bubble, envelope, video,
/// telephone-with-a-waveform, map, compass, another speech bubble, a list, a tick — falling back to a
/// horizontal scroller when the pane narrowed. Three of those glyphs are near-identical at 15 points,
/// two of them are speech bubbles meaning different things, and the row was the same whether or not
/// the person had a phone number, so the first thing the eye landed on was frequently the one thing
/// that could not be pressed.
///
/// ### What it is now
/// Every action carries its verb. Which ones are available is decided by
/// ``PersonActionAvailability`` from the person's own data rather than here, so the same rule serves
/// this row, the command bar and the context menus. Unavailable actions sink to the bottom instead of
/// leading a row nobody can use, and they keep saying why — a control that is merely grey is
/// indistinguishable from one that is broken. ``AdaptiveActionBar`` decides how many words survive
/// the pane's current width, and whatever leaves the row is in the **More** menu rather than gone.
///
/// Everything that reaches another person still routes through ``ContactActionConfirmationSheet``
/// rather than firing on click.
struct PersonQuickActions: View {
    @Environment(\.services) private var services

    let person: Item
    let hasHistory: Bool

    let onAction: (ContactActionRequest) -> Void
    let onAddNote: () -> Void
    let onRecordInteraction: () -> Void
    let onShowBrief: () -> Void
    let onAddRelationship: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            actionDock(showsContactTitles: true)
            actionDock(showsContactTitles: false)
        }
            .accessibilityIdentifier(AccessibilityID.People.quickActions)
    }

    private func actionDock(showsContactTitles: Bool) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            // Exactly one prominent button, and it is the first way of reaching this person —
            // whichever channel their record actually supports. A row in which everything is
            // emphasised has no emphasis in it.
            ForEach(Array(primaryContactActions.enumerated()), id: \.element.id) { index, entry in
                PersonDockButton(
                    entry: entry,
                    showsTitle: showsContactTitles,
                    isProminent: index == 0
                ) { perform(entry) }
            }

            if !primaryContactActions.isEmpty {
                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 2)
            }

            if let interactionAction {
                PersonDockButton(
                    entry: interactionAction,
                    showsTitle: true,
                    isProminent: false
                ) { perform(interactionAction) }
            }

            if let noteAction {
                PersonDockButton(
                    entry: noteAction,
                    showsTitle: showsContactTitles,
                    isProminent: false
                ) { perform(noteAction) }
            }

            if !secondaryActions.isEmpty {
                Menu {
                    ForEach(secondaryActions) { entry in
                        Button {
                            perform(entry)
                        } label: {
                            Label(entry.title, systemImage: entry.symbolName)
                        }
                        .disabled(!entry.isAvailable)
                        .help(entry.unavailabilityReason ?? entry.detail ?? entry.title)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }
        }
        // ### Why the row is no longer a card
        // It was one: a filled rounded rectangle, a hairline border *and* a drop shadow, floating on
        // the header. Three surface treatments stacked on one element is the thing
        // `SourceHygieneTests.noViewStacksShadowsMaterialsOrGlass` exists to prevent, and the result
        // read as a web toolbar pasted into the window rather than as part of it.
        //
        // Ordinary buttons on the header need no container. What separated the row from the content
        // below was never the card; it is the divider that was already there.
        .fixedSize(horizontal: true, vertical: false)
    }

    private var primaryContactActions: [PersonActionAvailability] {
        availability.filter { entry in
            guard entry.isAvailable, case .contact(let channel) = entry.kind else { return false }
            return channel == .call || channel == .message || channel == .email
        }
    }

    private var interactionAction: PersonActionAvailability? {
        availability.first { if case .logInteraction = $0.kind { true } else { false } }
    }

    private var noteAction: PersonActionAvailability? {
        availability.first { if case .addNote = $0.kind { true } else { false } }
    }

    private var secondaryActions: [PersonActionAvailability] {
        let visible = Set(primaryContactActions.map(\.id) + [interactionAction?.id, noteAction?.id].compactMap { $0 })
        return availability.filter { !visible.contains($0.id) }
    }

    private var availability: [PersonActionAvailability] {
        PersonActionAvailability.all(
            destinations: person.personProfile?.destinations() ?? [],
            hasRelationships: !relationships.isEmpty,
            hasHistory: hasHistory
        )
    }

    private var relationships: [PersonRelationship] {
        guard let services else { return [] }
        return (try? services.persons.relationships(of: person)) ?? []
    }

    private func perform(_ entry: PersonActionAvailability) {
        switch entry.kind {
        case .contact(let channel):
            onAction(
                ContactActionRequest(
                    channel: channel,
                    person: person,
                    destinations: ContactDestinationPolicy.candidates(
                        for: channel,
                        from: person.personProfile?.destinations() ?? []
                    )
                )
            )

        case .addNote:
            onAddNote()

        case .logInteraction:
            onRecordInteraction()

        case .addTask:
            createTask()

        case .meetingBrief:
            onShowBrief()

        case .addRelationship:
            onAddRelationship()
        }
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

/// One action on a person's profile.
///
/// ### Why this is an ordinary button now
/// It used to be a hand-drawn one: a rounded rectangle filled with the action's own colour at 11%,
/// a border of the same colour at 16%, semibold text in that colour, and — when prominent — a
/// gradient and a coloured drop shadow. Each contact channel had a different hue, so the row read
/// Email in indigo, Log Interaction in magenta and Add Note in orange, three saturated pills side by
/// side above a person's name.
///
/// Three things were wrong with that. It is not a Mac control — nothing else on the system looks
/// like it, so it reads as a web toolbar embedded in the window. Six hues across one row is not a
/// hierarchy; when everything is coloured, nothing is emphasised, and the eye has no idea which of
/// the three it is meant to reach for. And a colour per channel spends the app's whole palette on a
/// distinction the icon already makes — an envelope is an envelope whatever colour it is.
///
/// So: `.bordered`, with exactly one `.borderedProminent` for the action a person came here to do.
/// One accent, which is the user's own, and it now means *this is the primary action* rather than
/// *this is email*. The icons carry the channel, as they always did.
struct PersonDockButton: View {
    let entry: PersonActionAvailability
    let showsTitle: Bool
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        button
            .controlSize(.large)
            .disabled(!entry.isAvailable)
            .help(entry.unavailabilityReason ?? entry.detail ?? entry.title)
            .accessibilityLabel(entry.title)
            .accessibilityHint(entry.unavailabilityReason ?? entry.detail ?? "")
            .accessibilityIdentifier("action.\(entry.id)")
    }

    /// The style is chosen rather than modified, because `buttonStyle` takes a concrete type and the
    /// two cannot be selected between with a ternary.
    @ViewBuilder
    private var button: some View {
        if isProminent {
            Button(action: action) { label }.buttonStyle(.borderedProminent)
        } else {
            Button(action: action) { label }.buttonStyle(.bordered)
        }
    }

    /// The colour of the glyph, and only the glyph.
    ///
    /// ### Why the hue came back, and why only here
    /// Removing the per-channel colour fixed the right problem the wrong way. Three saturated pills
    /// side by side were not a hierarchy — but a row of identical grey buttons is not one either, and
    /// it lost the one thing the colour was genuinely doing: letting you find *Log Interaction*
    /// without reading three labels.
    ///
    /// So the two jobs are separated. The **button** says how important this action is: one filled
    /// with the accent, the rest bordered and quiet, which is a hierarchy with two levels rather than
    /// six. The **glyph** says which action it is, and colour is very good at that — it is
    /// pre-attentive, so the eye lands on the orange pencil before it has read anything.
    ///
    /// Nothing is filled with a hue any more, which is what made the old row shout. A tinted 16-point
    /// symbol on a neutral control is an accent; a tinted rectangle behind a word is a button
    /// pretending to be a category.
    private var glyphColor: Color? {
        // On the accent-filled button the glyph must stay legible against the fill, so it inherits
        // `onAccent` rather than taking a hue that would sit blue-on-blue.
        guard !isProminent else { return nil }

        guard case .contact(let channel) = entry.kind else {
            // The two actions that are about the record rather than about reaching somebody.
            switch entry.kind {
            case .logInteraction: return Theme.Palette.purple.color
            case .addNote: return Theme.Palette.orange.color
            default: return nil
            }
        }

        switch channel {
        case .call: return ContactChannelPalette.phone
        case .message: return ContactChannelPalette.message
        case .email: return ContactChannelPalette.email
        case .facetimeVideo, .facetimeAudio: return ContactChannelPalette.facetime
        case .maps: return ContactChannelPalette.address
        case .web: return ContactChannelPalette.website
        }
    }

    /// Composed rather than a plain `Label`, because a `Label` colours its glyph and its title
    /// together and the whole point here is that they differ.
    @ViewBuilder
    private var label: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: entry.symbolName)
                .foregroundStyle(glyphColor ?? Theme.Colors.onAccent)

            if showsTitle {
                Text(entry.title)
            }
        }
        // The glyph's colour is decoration over a label VoiceOver already reads, and a disabled
        // control must not keep a saturated icon that says it is still available.
        .opacity(entry.isAvailable ? 1 : 0.5)
    }
}
