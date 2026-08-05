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
        .accessibilityIdentifier(AccessibilityID.Records.contactConfirmation)
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

struct QuickFactSeed: Equatable {
    let category: QuickFactCategory
    let value: String
}

enum QuickFactCategory: String, CaseIterable, Identifiable {
    case askAbout
    case foodAndDrink
    case family
    case age
    case school
    case interests
    case likes
    case avoid
    case life
    case work
    case goodToKnow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askAbout: "Ask about"
        case .foodAndDrink: "Food & drink"
        case .family: "Family"
        case .age: "Age"
        case .school: "School"
        case .interests: "Interests"
        case .likes: "Likes"
        case .avoid: "Avoid"
        case .life: "Life"
        case .work: "Work"
        case .goodToKnow: "Good to know"
        }
    }

    var symbol: String {
        switch self {
        case .askAbout: "questionmark.bubble"
        case .foodAndDrink: "fork.knife"
        case .family: "figure.2.and.child.holdinghands"
        case .age: "birthday.cake"
        case .school: "graduationcap"
        case .interests: "star.fill"
        case .likes: "hand.thumbsup.fill"
        case .avoid: "hand.thumbsdown.fill"
        case .life: "sparkles"
        case .work: "briefcase.fill"
        case .goodToKnow: "lightbulb.fill"
        }
    }

    var tint: Color {
        switch self {
        case .askAbout: Theme.Palette.blue.color
        case .foodAndDrink: Theme.Palette.green.color
        case .family: Theme.Palette.pink.color
        case .age: Theme.Palette.orange.color
        case .school: Theme.Palette.indigo.color
        case .interests: Theme.Palette.purple.color
        case .likes: Theme.Palette.cyan.color
        case .avoid: Theme.Palette.orange.color
        case .life: Theme.Palette.indigo.color
        case .work: Theme.Colors.workDetail
        case .goodToKnow: Theme.Palette.yellow.color
        }
    }

    var attribute: FactAttribute {
        switch self {
        case .askAbout: .conversationTopic
        case .foodAndDrink: .foodAndDrink
        case .family: .family
        case .age: .observedAge
        case .school: .schoolGrade
        case .interests: .interest
        case .likes: .like
        case .avoid: .dislike
        case .life: .lifeEvent
        case .work: .role
        case .goodToKnow: .quickFact
        }
    }

    var prompt: String {
        switch self {
        case .askAbout: "What would be thoughtful to ask next time?"
        case .foodAndDrink: "Diet, allergies, favorite drinks, restaurants…"
        case .family: "Names, ages, milestones, or family context…"
        case .age: "Age now, or the age when you learned it…"
        case .school: "Grade, school, teacher, or what needs confirming…"
        case .interests: "Hobbies, teams, books, music, travel…"
        case .likes: "Something they enjoy or appreciate…"
        case .avoid: "Something they dislike or would rather skip…"
        case .life: "Something happening in their life…"
        case .work: "Role, project, goal, or professional context…"
        case .goodToKnow: "Anything useful that does not fit elsewhere…"
        }
    }

    var suggestions: [String] {
        switch self {
        case .askAbout: ["The kids", "Upcoming trip", "Current project", "How they’re doing"]
        case .foodAndDrink: ["Vegetarian", "Gluten-free", "Doesn’t drink alcohol", "Likes wine"]
        case .family: ["Has 2 children", "Names to confirm", "Partner", "New baby"]
        case .age: ["5 years old", "About 8", "Age to confirm"]
        case .school: ["2nd grade", "2nd or 3rd grade", "School to confirm"]
        case .interests: ["Wine", "Golf", "Art", "Running"]
        case .likes: ["Coffee", "Live music", "Thoughtful gifts"]
        case .avoid: ["Crowded places", "Early meetings", "Spicy food"]
        case .life: ["Moving", "Planning a trip", "New home"]
        case .work: ["New role", "Hiring", "Launching a project"]
        case .goodToKnow: []
        }
    }

    static func category(for attribute: FactAttribute) -> QuickFactCategory {
        allCases.first(where: { $0.attribute == attribute }) ?? .goodToKnow
    }
}

/// A fast, human-shaped way to remember something useful about somebody.
struct AddFactSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let personName: String
    let onSave: (ObservationDraft, FactConfidence, FactSensitivity, Date) -> Void
    let onCancel: () -> Void

    @Environment(\.services) private var services

    @State private var category: QuickFactCategory
    @State private var value: String
    @State private var confidence: FactConfidence = .stated
    @State private var sensitivity: FactSensitivity = .normal
    @State private var observedOn = Date()
    @State private var showsDetails = false
    @FocusState private var isValueFocused: Bool

    init(
        personName: String,
        seed: QuickFactSeed? = nil,
        onSave: @escaping (ObservationDraft, FactConfidence, FactSensitivity, Date) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.personName = personName
        self.onSave = onSave
        self.onCancel = onCancel
        _category = State(initialValue: seed?.category ?? .askAbout)
        _value = State(initialValue: seed?.value ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.medium) {
                IconTile(systemImage: category.symbol, tint: category.tint, size: .large)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a quick fact")
                        .font(Theme.Text.title)
                    Text("Something useful to remember about \(personName)")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.section)
            .padding(.vertical, Theme.Spacing.large)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("What kind of detail is this?")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.small)],
                            spacing: Theme.Spacing.small
                        ) {
                            ForEach(QuickFactCategory.allCases) { option in
                                Button {
                                    withAnimation(
                                        Theme.Motion.respectingReduceMotion(
                                            Theme.Motion.appearance, reduceMotion: reduceMotion
                                        )
                                    ) { category = option }
                                } label: {
                                    HStack(spacing: Theme.Spacing.small) {
                                        Image(systemName: option.symbol)
                                            .foregroundStyle(option.tint)
                                            .frame(width: 20)
                                        Text(option.title)
                                            .font(.system(.callout, weight: category == option ? .semibold : .regular))
                                            .foregroundStyle(Theme.Colors.primaryText)
                                        Spacer()
                                        if category == option {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(option.tint)
                                        }
                                    }
                                    .padding(.horizontal, Theme.Spacing.small)
                                    .frame(height: 38)
                                    .background(
                                        category == option ? Theme.Colors.tintedFill(option.tint) : Theme.Colors.subtleFill,
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !category.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                            SectionHeader("Quick Picks")

                            HStack(spacing: Theme.Spacing.small) {
                                ForEach(category.suggestions, id: \.self) { suggestion in
                                    Button(suggestion) {
                                        value = suggestion
                                        isValueFocused = true
                                    }
                                    .buttonStyle(.plain)
                                    .font(Theme.Text.chip)
                                    .padding(.horizontal, Theme.Spacing.small)
                                    .frame(height: 28)
                                    .background(Theme.Colors.tintedFill(category.tint), in: Capsule())
                                    .foregroundStyle(category.tint)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        Text(category.title)
                            .font(.system(.headline, weight: .semibold))
                        Text(category.prompt)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        TextField("", text: $value, axis: .vertical)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.system(.title3, weight: .medium))
                            .lineLimit(1...4)
                            .padding(Theme.Spacing.medium)
                            .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.large)
                                    .strokeBorder(category.tint.opacity(isValueFocused ? 0.7 : 0.2), lineWidth: isValueFocused ? 2 : 1)
                            }
                            .focused($isValueFocused)
                            .accessibilityLabel(category.title)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("How certain is this?")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Picker("Confidence", selection: $confidence) {
                            ForEach(FactConfidence.allCases, id: \.rawValue) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    DisclosureGroup("Details", isExpanded: $showsDetails) {
                        VStack(spacing: Theme.Spacing.medium) {
                            DatePicker("Learned on", selection: $observedOn, displayedComponents: .date)

                            Picker("Privacy", selection: $sensitivity) {
                                ForEach(FactSensitivity.allCases, id: \.rawValue) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }

                            if sensitivity != .normal {
                                Label("Never exported or included in a meeting brief.", systemImage: "lock.fill")
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        }
                        .padding(.top, Theme.Spacing.medium)
                    }
                    .font(Theme.Text.rowSubtitle)
                }
                .padding(Theme.Spacing.section)
            }

            Divider()

            HStack {
                Text("Quick facts are searchable across everyone.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Quick Fact") {
                    onSave(
                        ObservationDraft(
                            attribute: category.attribute,
                            value: normalizedValue
                        ),
                        confidence,
                        sensitivity,
                        observedOn
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(category.tint)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Theme.Spacing.section)
            .frame(height: 60)
            .background(Theme.Colors.contentBackground)
        }
        .frame(width: 620, height: 650)
        .background(Theme.Colors.windowBackground)
        .accessibilityIdentifier(AccessibilityID.Records.addFactSheet)
        .onAppear {
            observedOn = services?.dateProvider.now ?? Date()
            isValueFocused = true
        }
    }

    /// Estimators need a clean numeric age or grade, while ambiguous wording must remain exactly
    /// as entered so the interface never turns “2nd or 3rd” into a confident “2nd.”
    private var normalizedValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let numbers = trimmed.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }

        if category == .age, let age = numbers.first {
            return "\(age)"
        }

        if category == .school, numbers.count == 1, !trimmed.localizedCaseInsensitiveContains(" or ") {
            return "\(numbers[0])"
        }

        return trimmed
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
        .accessibilityIdentifier(AccessibilityID.Records.correctFactSheet)
        .onAppear { isFocused = true }
    }
}

// MARK: - Relationships

/// Repairs or removes an existing relationship while keeping both people's records in agreement.
struct EditRelationshipSheet: View {
    @Environment(\.services) private var services

    let person: Item
    let relationship: PersonRelationship
    let onFinish: () -> Void

    @State private var kind: RelationshipKind
    @State private var label: String
    @State private var isConfirmingDeletion = false

    init(person: Item, relationship: PersonRelationship, onFinish: @escaping () -> Void) {
        self.person = person
        self.relationship = relationship
        self.onFinish = onFinish
        _kind = State(initialValue: relationship.kind)
        _label = State(initialValue: relationship.customLabel ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit relationship")
                    .font(Theme.Text.title)
                Text(relationship.other?.displayTitle ?? "Unknown person")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Form {
                Picker("Relationship", selection: $kind) {
                    ForEach(RelationshipKind.allCases, id: \.rawValue) { option in
                        Label(option.displayName.capitalized, systemImage: option.symbolName).tag(option)
                    }
                }

                TextField("Your wording (optional)", text: $label)
                    .help("For example: son, daughter, best friend, or former colleague")
            }
            .formStyle(.grouped)

            Text(reciprocalSentence)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Delete Relationship", systemImage: "trash", role: .destructive) {
                    isConfirmingDeletion = true
                }

                Spacer()

                Button("Cancel", role: .cancel, action: onFinish)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 440)
        .confirmationDialog(
            "Delete this relationship?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Relationship", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the relationship from both people.")
        }
    }

    private var reciprocalSentence: String {
        guard let other = relationship.other else { return "Both sides will be updated together." }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = trimmed.isEmpty ? kind.displayName : trimmed
        return "\(other.displayTitle) is \(person.displayTitle)'s \(word); "
            + "\(person.displayTitle) is \(other.displayTitle)'s \(kind.inverse.displayName)."
    }

    private func save() {
        guard let services else { return }
        services.perform {
            try services.persons.update(relationship, kind: kind, label: label)
            services.noteChange(to: person)
            if let other = relationship.other { services.noteChange(to: other) }
        }
        onFinish()
    }

    private func delete() {
        guard let services else { return }
        let other = relationship.other
        services.perform {
            try services.persons.unrelate(relationship)
            services.noteChange(to: person)
            if let other { services.noteChange(to: other) }
        }
        onFinish()
    }
}
