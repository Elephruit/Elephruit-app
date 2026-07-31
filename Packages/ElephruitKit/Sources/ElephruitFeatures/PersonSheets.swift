import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

// MARK: - Contact actions

/// An action the user has asked for but which has not happened yet.
struct ContactActionRequest: Identifiable {
    let id = UUID()
    let channel: ContactChannel
    let person: Item
    let destinations: [ContactDestination]
}

/// What the confirmation sheet decided.
enum ContactActionOutcome {
    case performed(channel: ContactChannel, destination: ContactDestination)
    case cancelled
}

/// The step between pressing *Call* and anything happening.
///
/// ### Why this exists even when there is only one number
/// The requirement is that nothing externally visible happens silently. A sheet naming the person,
/// the channel, and the exact destination costs one keystroke — Return is the default — and removes
/// the entire class of "it rang the wrong Maya". When there are several numbers it is also the only
/// place the choice can be made honestly, because the app has no basis for picking one.
///
/// Handing the URL to `NSWorkspace` opens the user's own app with the fields filled in and stops
/// there. Elephruit never sends anything itself.
struct ContactActionConfirmationSheet: View {
    let request: ContactActionRequest
    let onFinish: (ContactActionOutcome) -> Void

    @State private var selection: ContactDestination?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label(request.channel.displayName, systemImage: request.channel.symbolName)
                .font(Theme.Text.title)

            Text("\(request.channel.verbPhrase) \(request.person.displayTitle)")
                .font(Theme.Text.rowTitle)
                .foregroundStyle(Theme.Colors.secondaryText)

            if request.destinations.count > 1 {
                Text("Which \(request.channel.destinationNoun)?")
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                ForEach(request.destinations) { destination in
                    Button {
                        selection = destination
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: selection?.id == destination.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Theme.Colors.selection)
                            Text(destination.displayText)
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection?.id == destination.id ? [.isSelected, .isButton] : .isButton)
                }
            }

            if request.channel.isExternallyVisible {
                Label(
                    "This opens your \(appNoun). Nothing is sent until you send it.",
                    systemImage: "info.circle"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onFinish(.cancelled) }
                    .keyboardShortcut(.cancelAction)

                Button(request.channel.displayName) { perform() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection == nil)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 380)
        .accessibilityIdentifier(AccessibilityID.People.contactConfirmation)
        .onAppear {
            // Preselect only when the app has a defensible basis for it: one candidate, or one the
            // user marked preferred. Two unmarked numbers means no default and a deliberate choice.
            selection = ContactDestinationPolicy.automatic(for: request.channel, from: request.destinations)
        }
    }

    private var appNoun: String {
        switch request.channel {
        case .email: "mail app"
        case .message: "messages app"
        case .call, .facetimeAudio, .facetimeVideo: "phone app"
        case .maps: "maps app"
        case .web: "browser"
        }
    }

    private func perform() {
        guard let selection,
              let url = ContactActionURL.url(for: request.channel, destination: selection.value)
        else {
            onFinish(.cancelled)
            return
        }

        NSWorkspace.shared.open(url)
        onFinish(.performed(channel: request.channel, destination: selection))
    }
}

// MARK: - Facts

/// Recording something new about somebody.
///
/// The observation date is editable and defaults to today. That field is the whole reason the sheet
/// exists rather than an inline text box: "Jack is six" learned last July means something different
/// from "Jack is six" learned this morning, and every estimate downstream depends on which.
struct AddFactSheet: View {
    let personName: String
    let onSave: (ObservationDraft, FactConfidence, FactSensitivity, Date) -> Void
    let onCancel: () -> Void

    @Environment(\.services) private var services

    @State private var attribute: FactAttribute = .lifeEvent
    @State private var value = ""
    @State private var confidence: FactConfidence = .stated
    @State private var sensitivity: FactSensitivity = .normal
    @State private var observedOn = Date()
    @FocusState private var isValueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("About \(personName)")
                .font(Theme.Text.title)

            Form {
                Picker("This is", selection: $attribute) {
                    ForEach(FactAttribute.curated, id: \.rawValue) { option in
                        Label(option.displayName, systemImage: option.symbolName).tag(option)
                    }
                }

                TextField("What is true", text: $value, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isValueFocused)

                DatePicker("Learned on", selection: $observedOn, displayedComponents: .date)
                    .help("Estimates advance from this date, so it matters more than when you typed it")

                Picker("Confidence", selection: $confidence) {
                    ForEach(FactConfidence.allCases, id: \.rawValue) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Picker("Sensitivity", selection: $sensitivity) {
                    ForEach(FactSensitivity.allCases, id: \.rawValue) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            .formStyle(.grouped)

            if sensitivity != .normal {
                Label("Never exported, and never included in a meeting brief.", systemImage: "lock")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onSave(
                        ObservationDraft(attribute: attribute, value: value.trimmingCharacters(in: .whitespaces)),
                        confidence,
                        sensitivity,
                        observedOn
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 460)
        .accessibilityIdentifier(AccessibilityID.People.addFactSheet)
        .onAppear {
            observedOn = services?.dateProvider.now ?? Date()
            isValueFocused = true
        }
    }
}

/// Correcting a fact, with the promise that the old one survives stated on the sheet itself.
struct CorrectFactSheet: View {
    let value: PortraitValue
    let onSave: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var newValue: String
    @State private var note = ""
    @FocusState private var isFocused: Bool

    init(value: PortraitValue, onSave: @escaping (String, String?) -> Void, onCancel: @escaping () -> Void) {
        self.value = value
        self.onSave = onSave
        self.onCancel = onCancel
        _newValue = State(initialValue: value.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Correct this")
                .font(Theme.Text.title)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("Currently")
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)
                Text(value.text)
                    .font(Theme.Text.rowTitle)
                Text("Recorded \(value.observedOn.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            TextField("Should say", text: $newValue, axis: .vertical)
                .lineLimit(1...4)
                .focused($isFocused)

            TextField("Why (optional)", text: $note)

            Label(
                "The previous value is kept. Nothing here is ever overwritten.",
                systemImage: "clock.arrow.circlepath"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Correct") {
                    onSave(
                        newValue.trimmingCharacters(in: .whitespaces),
                        note.isEmpty ? nil : note
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 420)
        .accessibilityIdentifier(AccessibilityID.People.correctFactSheet)
        .onAppear { isFocused = true }
    }
}

// MARK: - Relationships

/// Linking two people, with the reciprocal stated before it is written.
struct AddRelationshipSheet: View {
    @Environment(\.services) private var services

    let person: Item
    let onFinish: () -> Void

    @State private var kind: RelationshipKind = .friend
    @State private var label = ""
    @State private var name = ""
    @State private var matches: [Item] = []
    @State private var selected: Item?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Link somebody to \(person.displayTitle)")
                .font(Theme.Text.title)

            Form {
                Picker("Relationship", selection: $kind) {
                    ForEach(RelationshipKind.allCases, id: \.rawValue) { option in
                        Label(option.displayName.capitalized, systemImage: option.symbolName).tag(option)
                    }
                }

                TextField("Their name", text: $name)
                    .focused($isNameFocused)
                    .onChange(of: name) { _, newValue in search(newValue) }

                TextField("Call them (optional)", text: $label)
                    .help("“son” rather than “child” — the app uses your word and never guesses one")
            }
            .formStyle(.grouped)

            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Existing people")
                        .font(Theme.Text.sectionHeader)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    ForEach(matches, id: \.id) { match in
                        Button {
                            selected = match
                            name = match.displayTitle
                            matches = []
                        } label: {
                            HStack(spacing: Theme.Spacing.small) {
                                PersonAvatar(name: match.displayTitle, colorName: match.colorName, size: 22)
                                Text(match.displayTitle)
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if !trimmedName.isEmpty, selected == nil {
                Label(
                    "“\(trimmedName)” is new. A lightweight record will be created — you can fill it in later.",
                    systemImage: "person.badge.plus"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !trimmedName.isEmpty {
                Text(reciprocalSentence)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onFinish)
                    .keyboardShortcut(.cancelAction)
                Button("Link", action: link)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 440)
        .accessibilityIdentifier(AccessibilityID.People.addRelationshipSheet)
        .onAppear { isNameFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Says both halves before either is written, because writing one is writing both.
    private var reciprocalSentence: String {
        let word = label.isEmpty ? kind.displayName : label
        return "\(trimmedName) becomes \(person.displayTitle)'s \(word), "
            + "and \(person.displayTitle) becomes \(trimmedName)'s \(kind.inverse.displayName)."
    }

    private func search(_ query: String) {
        guard let services, query.count >= 2 else {
            matches = []
            return
        }
        selected = nil

        let key = TextNormalizer.foldedForMatching(query)
        matches = ((try? services.persons.allPeople(includingPlaceholders: true)) ?? [])
            .filter { $0.id != person.id && TextNormalizer.foldedForMatching($0.displayTitle).contains(key) }
            .prefix(5)
            .map { $0 }
    }

    private func link() {
        guard let services else { return }
        services.perform {
            let other = try selected ?? services.persons.resolveOrCreatePlaceholder(named: trimmedName)
            try services.persons.relate(
                person, to: other, as: kind, label: label.isEmpty ? nil : label
            )
            services.noteChange(to: other)
        }
        onFinish()
    }
}
