import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The natural-language command bar.
///
/// ### Why the preview is the safety mechanism
/// A command bar that acts on Return is only trustworthy if the user can see what it understood
/// *before* pressing it. Every recognised span is shown as a chip while typing, the resulting action
/// is stated in a sentence, and anything reaching another person needs a second, explicit
/// confirmation on top of that.
///
/// So there are three gates, not one: what the parser recognised is visible, what it intends to do is
/// stated, and what leaves the machine is confirmed. A misparse costs a glance rather than a phone
/// call to a stranger.
///
/// ### Why it does not simply become search
/// A line the parser cannot claim *does* become a search — that is the honest fallback, and it means
/// the bar is never a dead end. What it must never do is guess: an unknown name produces an offer to
/// create that person, never a call to the closest match.
struct RecordsCommandBarView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let navigation: NavigationModel

    @State private var text = ""
    @State private var parsed: ParsedCommand?
    @State private var results: [RankedPerson] = []
    @State private var highlighted = 0
    @State private var pendingConfirmation: PendingCommand?
    @State private var feedback: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field

            if let parsed, !parsed.originalText.isEmpty {
                Divider()
                CommandPreview(
                    command: parsed,
                    onRun: { run(parsed) },
                    onCreatePerson: { createPerson(named: $0) }
                )
            }

            if !results.isEmpty {
                Divider()
                resultList
            }

            if let feedback {
                Divider()
                Label(feedback, systemImage: "checkmark.circle")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.completed)
                    .padding(Theme.Spacing.medium)
            }

            Divider()
            hints
        }
        .frame(width: 620)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.Records.commandBar)
        .sheet(item: $pendingConfirmation) { pending in
            CommandConfirmationSheet(pending: pending) { confirmed in
                pendingConfirmation = nil
                if confirmed { perform(pending) }
            }
        }
        .onAppear { isFocused = true }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(Theme.Colors.secondaryText)

            TextField("Type a name, or what you want to do", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.title3))
                .focused($isFocused)
                .onChange(of: text) { _, newValue in reparse(newValue) }
                .onSubmit { runHighlighted() }
                // Escape has to reach the sheet even though the field owns the keyboard, which is
                // the whole reason this sits on the field and not on the container around it.
                .onExitCommand { dismiss() }
                .accessibilityIdentifier(AccessibilityID.Records.commandField)
                .accessibilityLabel("Command bar")
                .accessibilityValue(parsed?.summary ?? "")

            if !text.isEmpty {
                Button {
                    text = ""
                    reparse("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .accessibilityLabel("Clear")
            }
        }
        .padding(Theme.Spacing.medium)
        // Arrow keys move through results without leaving the field, which is what makes the bar
        // usable without the mouse at all.
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(0, results.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    Button {
                        open(result.id)
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            PersonAvatar(name: result.name, colorName: nil, size: 24)

                            VStack(alignment: .leading, spacing: 0) {
                                Text(result.name)
                                    .font(Theme.Text.rowTitle)
                                if let reason = result.bestReason {
                                    Text(reason.text)
                                        .font(Theme.Text.metadata)
                                        .foregroundStyle(Theme.Colors.secondaryText)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            if let days = result.daysSinceContact {
                                Text(days < 30 ? "\(days)d" : "\(days / 30)mo")
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.medium)
                        .padding(.vertical, Theme.Spacing.small)
                        .background(
                            index == highlighted ? Theme.Colors.selectionFill : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == highlighted ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(Theme.Spacing.tight)
        }
        .frame(maxHeight: 260)
    }

    private var hints: some View {
        HStack(spacing: Theme.Spacing.small) {
            exampleChips

            Divider().frame(height: 16)

            // The way out, said in the place a way out is looked for. A bar that acts on Return has
            // to be as easy to leave as it is to open, or opening it by accident is a trap.
            Button("Close", action: dismiss.callAsFunction)
                .buttonStyle(.plain)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("records.commandBar.close")

            KeyHint("esc")
        }
        .padding(.trailing, Theme.Spacing.medium)
    }

    private var exampleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.medium) {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        text = example
                        reparse(example)
                    } label: {
                        Text(example)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.vertical, Theme.Spacing.tight)
                            .background(Theme.Colors.subtleFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Try this")
                }
            }
            .padding(Theme.Spacing.small)
        }
    }

    /// The lines the bar advertises, which are also the ones its tests are written against.
    static let examples = [
        "call Maya",
        "meet Maya next Tuesday at 2",
        "Maya moved to Austin",
        "Maya son Jack age 6 entering second grade",
        "note Maya prefers small restaurants",
        "task introduce Maya to Danielle Friday",
        "show Maya's family",
        "email Design Team",
    ]

    // MARK: - Parsing

    private func reparse(_ input: String) {
        guard let services else { return }
        highlighted = 0
        feedback = nil

        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            parsed = nil
            results = []
            return
        }

        let command = services.commandParser.parse(input, context: commandContext())
        parsed = command

        // A command that resolves to something specific does not also need a list of near misses
        // underneath it; a search does.
        if case .search(let query) = command.intent, !query.isEmpty {
            results = (try? services.personSearch.search(query, limit: 8)) ?? []
        } else {
            results = []
        }
    }

    /// Everything the parser is allowed to recognise.
    ///
    /// Rebuilt per keystroke, which is cheap at personal-library scale and means a person created a
    /// moment ago is recognised immediately rather than after a refresh nobody would think to do.
    private func commandContext() -> CommandContext {
        guard let services else { return .empty }

        let people = ((try? services.persons.allPeople(includingPlaceholders: true)) ?? []).map { person in
            KnownPerson(
                id: person.id,
                fullName: person.displayTitle,
                aliases: [person.personProfile?.nickname, person.personProfile?.givenName].compactMap { $0 }
            )
        }
        let groups = ((try? services.personGroups.allGroups()) ?? []).map {
            KnownGroup(id: $0.id, name: $0.name, memberCount: $0.memberCount)
        }

        return CommandContext(people: people, groups: groups)
    }

    // MARK: - Running

    private func runHighlighted() {
        if !results.isEmpty, highlighted < results.count {
            open(results[highlighted].id)
            return
        }
        if let parsed { run(parsed) }
    }

    private func run(_ command: ParsedCommand) {
        guard command.isRunnable else { return }

        // Everything that reaches another person stops here for an explicit yes.
        guard !command.requiresConfirmation else {
            pendingConfirmation = PendingCommand(command: command)
            return
        }
        apply(command)
    }

    private func perform(_ pending: PendingCommand) {
        apply(pending.command)
    }

    private func apply(_ command: ParsedCommand) {
        guard let services else { return }

        switch command.intent {
        case .search:
            break

        case .open(let personID), .reveal(let personID, _):
            open(personID)

        case .chart(let personID, _):
            open(personID)

        case .contact(let personID, let channel):
            guard let person = try? services.persons.person(id: personID) else { return }
            let destinations = ContactDestinationPolicy.candidates(
                for: channel, from: person.personProfile?.destinations() ?? []
            )
            guard let destination = destinations.first,
                  let url = ContactActionURL.url(for: channel, destination: destination.value)
            else { return }
            NSWorkspace.shared.open(url)
            feedback = "\(channel.displayName) opened for \(person.displayTitle). Nothing was sent."

        case .schedule(let personID, let day, let time):
            guard let person = try? services.persons.person(id: personID) else { return }
            services.perform {
                let meeting = try services.items.create(
                    ItemDraft(
                        kind: .meeting,
                        title: "Meeting with \(person.displayTitle)",
                        startAt: day.resolve(using: services.dateProvider, at: time)
                    )
                )
                try services.items.link(meeting, to: person, kind: .participant)
                services.noteChange(to: meeting)
                navigation.selectItem(meeting.id)
            }
            feedback = "Meeting created in Elephruit. Your calendar is untouched."

        case .createPerson(let fields):
            createPerson(fields)

        case .addDetails(let personID, let fields):
            guard let person = try? services.persons.person(id: personID) else { return }
            services.perform {
                try services.persons.addDetails(to: person, from: Self.draft(from: fields))
                services.noteChange(to: person)
            }
            feedback = "Added \(fields.summaryPhrase) to \(person.displayTitle)."

        case .setCelebration(let personID, let kind, let date):
            guard let person = try? services.persons.person(id: personID) else { return }
            services.perform {
                try services.persons.addCelebration(to: person, kind: kind, title: nil, date: date)
                services.noteChange(to: person)
            }
            feedback = "\(person.displayTitle)'s \(kind.displayName.lowercased()) recorded."

        case .recordFact(let personID, let draft):
            guard let person = try? services.persons.person(id: personID) else { return }
            services.perform {
                try services.persons.record(
                    draft, about: person, observedOn: services.dateProvider.now,
                    confidence: .stated, sensitivity: .normal, source: nil
                )
                services.noteChange(to: person)
            }
            feedback = "Recorded for \(person.displayTitle)."

        case .recordRelation(let personID, let kind, let label, let name, let observations):
            guard let person = try? services.persons.person(id: personID) else { return }

            // Through `apply` rather than resolve-relate-record by hand, which is what this did and
            // which threw on an empty name. "Maya son senior at South High" names nobody and is
            // still three facts; the command bar is now the third interface building the same
            // `PersonUpdate` rather than the last one with a write path of its own.
            services.perform {
                var capture = RelativeCapture(kind: kind, label: label, name: name.isEmpty ? nil : name)
                // The parser has no clock, so it flags a forward-looking grade with `effective`
                // rather than resolving a year. Carried across here, where there is one.
                if observations.contains(where: { $0.attribute == .schoolGrade && $0.effective != nil }) {
                    capture.schoolYearIntent = .starting
                }
                capture.gradeText = observations.first { $0.attribute == .schoolGrade }?.value
                capture.school = observations.first { $0.attribute == .school }?.value
                capture.age = observations.first { $0.attribute == .observedAge }.flatMap { Int($0.value) }

                let touched = try services.persons.apply(
                    PersonUpdate(subjectID: person.id, relatives: [capture]),
                    source: nil,
                    observedOn: services.dateProvider.now
                )

                // Anything the parser understood that a capture has no field for — a like, a
                // location — still belongs on the new person.
                let carried: Set<FactAttribute> = [.schoolGrade, .school, .observedAge]
                if let other = touched.first {
                    for draft in observations where !carried.contains(draft.attribute) {
                        try services.persons.record(
                            draft, about: other, observedOn: services.dateProvider.now,
                            confidence: .stated, sensitivity: .normal, source: nil
                        )
                    }
                    services.noteChange(to: other)
                }
            }
            feedback = name.isEmpty
                ? "Recorded a \(label ?? kind.displayName) of \(person.displayTitle)."
                : "\(name) linked to \(person.displayTitle)."

        case .addNote(let personID, let text):
            guard let person = try? services.persons.person(id: personID) else { return }
            services.perform {
                let note = try services.items.create(ItemDraft(kind: .note, title: text))
                try services.items.link(note, to: person, kind: .mentions)
                services.noteChange(to: note)
            }
            feedback = "Note added to \(person.displayTitle)'s history."

        case .createTask(let text, let personIDs, let day):
            services.perform {
                var draft = ItemDraft(kind: .reminder, title: text)
                draft.dueAt = day?.resolve(using: services.dateProvider)
                let task = try services.items.create(draft)
                for personID in personIDs {
                    if let person = try services.persons.person(id: personID) {
                        try services.items.link(task, to: person, kind: .mentions)
                    }
                }
                services.noteChange(to: task)
            }
            feedback = "Reminder created."

        case .groupAction(let groupID, let action):
            runGroupAction(action, groupID: groupID)
        }

        text = ""
        parsed = nil
        results = []
    }

    private func runGroupAction(_ action: GroupAction, groupID: UUID) {
        guard let services, let group = try? services.personGroups.group(id: groupID) else { return }
        guard let preview = try? services.personGroups.preview(action, for: group) else { return }

        switch action {
        case .tag(let slug):
            services.perform { try services.personGroups.applyTag(slug, to: group) }
            feedback = "Tagged \(preview.recipients.count) people."

        case .email, .message, .invite:
            guard let url = preview.url else { return }
            NSWorkspace.shared.open(url)
            feedback = "Opened a draft to \(preview.recipients.count) people. Nothing was sent."

        case .export:
            feedback = "Use File ▸ Export to save this group."
        }
    }

    private func createPerson(named name: String) {
        createPerson(PersonDraftFields(name: name))
    }

    private func createPerson(_ fields: PersonDraftFields) {
        guard let services else { return }
        services.perform {
            let person = try services.persons.createPerson(Self.draft(from: fields))
            services.noteChange(to: person)
            navigation.select(.kind(.person))
            navigation.selectItem(person.id)
        }
        feedback = "Created \(fields.name)."
        text = ""
        parsed = nil
        results = []
    }

    static func draft(from fields: PersonDraftFields) -> PersonDraft {
        PersonDraft(
            fullName: fields.name,
            roleTitle: fields.jobTitle,
            organizationName: fields.company,
            emails: fields.emails.map { LabelledValue(label: "email", value: $0) },
            phones: fields.phones.map { LabelledValue(label: "phone", value: $0) },
            addresses: fields.address.map { [LabelledValue(label: "home", value: $0)] } ?? []
        )
    }

    private func open(_ personID: UUID) {
        navigation.select(.kind(.person))
        navigation.selectItem(personID)
        dismiss()
    }
}

/// A command waiting for an explicit yes.
struct PendingCommand: Identifiable {
    let id = UUID()
    let command: ParsedCommand
}

// MARK: - Preview

/// What the parser understood, live, while the user is still typing.
struct CommandPreview: View {
    let command: ParsedCommand
    let onRun: () -> Void
    let onCreatePerson: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if !command.entities.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.tight) {
                        ForEach(command.entities) { entity in
                            HStack(spacing: 3) {
                                Text(entity.displayLabel)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                Text(entity.text)
                            }
                            .font(Theme.Text.chip)
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.vertical, 2)
                            .background(Theme.Colors.subtleFill, in: Capsule())
                        }
                    }
                }
            }

            HStack(spacing: Theme.Spacing.small) {
                Text(command.summary)
                    .font(Theme.Text.rowTitle)

                Spacer()

                if command.isRunnable {
                    Button(command.requiresConfirmation ? "Review…" : "Do it", action: onRun)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    KeyHint("↩")
                }
            }

            ForEach(command.ambiguities, id: \.self) { ambiguity in
                HStack(spacing: Theme.Spacing.small) {
                    Label(ambiguity.message, systemImage: "questionmark.circle")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.warning)

                    if case .unknownPerson(let name) = ambiguity {
                        Button("Create \(name)") { onCreatePerson(name) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .accessibilityIdentifier(AccessibilityID.Records.commandPreview)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.summary)
    }
}

/// The second gate, for anything that leaves the machine.
struct CommandConfirmationSheet: View {
    let pending: PendingCommand
    let onDecide: (Bool) -> Void

    @Environment(\.services) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label("Before this happens", systemImage: "exclamationmark.bubble")
                .font(Theme.Text.title)

            Text(pending.command.summary)
                .font(Theme.Text.rowTitle)

            if let preview = groupPreview {
                GroupRecipientList(preview: preview)
            }

            if pending.command.intent.isExternallyVisible {
                Label(
                    "This opens a draft in your own app. Elephruit never sends anything itself.",
                    systemImage: "info.circle"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDecide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { onDecide(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 460)
        .accessibilityIdentifier(AccessibilityID.Records.groupActionPreview)
    }

    private var groupPreview: GroupActionPreview? {
        guard case .groupAction(let groupID, let action) = pending.command.intent,
              let services,
              let group = try? services.personGroups.group(id: groupID)
        else { return nil }
        return try? services.personGroups.preview(action, for: group)
    }
}

/// Who exactly is about to receive something.
struct GroupRecipientList: View {
    let preview: GroupActionPreview

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(preview.summary)
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    ForEach(preview.recipients) { recipient in
                        HStack(spacing: Theme.Spacing.small) {
                            Text(recipient.name)
                            Text(recipient.destination)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Spacer()
                        }
                        .font(Theme.Text.metadata)
                    }
                }
            }
            .frame(maxHeight: 140)

            if !preview.excluded.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(preview.excluded) { exclusion in
                        Text("\(exclusion.name) — \(exclusion.reason)")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
            }

            if let note = preview.privacyNote {
                Label(note, systemImage: preview.usesBlindCopy ? "eye.slash" : "eye")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(preview.usesBlindCopy ? Theme.Colors.secondaryText : Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import AppKit
