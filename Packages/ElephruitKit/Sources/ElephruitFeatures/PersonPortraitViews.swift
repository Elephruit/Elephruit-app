import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The structured half of a person's page.
///
/// Cards appear only when they hold something, so an empty person is a name and an invitation rather
/// than fourteen blank fields. The free-text note sits among them rather than above them, because a
/// paragraph about somebody is one more thing that is true about them and not a different category of
/// information.
struct PersonPortraitSection: View {
    @Environment(\.services) private var services
    @Environment(\.prefersMonospacedEditor) private var prefersMonospaced

    let person: Item
    let portrait: PersonPortrait?
    @Binding var bodyText: String

    let onAddFact: (QuickFactSeed?) -> Void
    let onConfirm: (PortraitValue) -> Void
    let onCorrect: (PortraitValue) -> Void
    let onDelete: (PortraitValue) -> Void
    let onOpenSource: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader("Quick Facts", count: factCount)
                    Text("The useful things to remember")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                Spacer()
                Button {
                    onAddFact(nil)
                } label: {
                    Label("Add quick fact", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .font(Theme.Text.rowSubtitle)
                .accessibilityIdentifier(AccessibilityID.People.addFact)
            }

            if let stale = portrait?.staleFacts, !stale.isEmpty {
                StaleFactsBanner(count: stale.count)
            }

            if let cards = portrait?.cards, !cards.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: Theme.Spacing.medium)],
                    alignment: .leading,
                    spacing: Theme.Spacing.medium
                ) {
                    ForEach(cards) { card in
                        PortraitCardView(
                            card: card,
                            onConfirm: onConfirm,
                            onCorrect: onCorrect,
                            onDelete: onDelete,
                            onOpenSource: onOpenSource
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                quickFactEmptyState
            }

            NotesField(
                text: $bodyText,
                placeholder: "What is worth remembering about them?",
                isEditable: !person.isInTrash
            )
        }
        .padding(.horizontal, Theme.Spacing.large)
    }

    private var factCount: Int? {
        let count = portrait?.cards.reduce(0) { $0 + $1.values.count } ?? 0
        return count == 0 ? nil : count
    }

    private var quickFactEmptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Colors.selection)
                    .frame(width: 42, height: 42)
                    .background(Theme.Colors.selection.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Build a better mental picture")
                        .font(.system(.headline, weight: .semibold))
                    Text("Remember what makes time with \(person.displayTitle) thoughtful and easy.")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: Theme.Spacing.small)],
                spacing: Theme.Spacing.small
            ) {
                ForEach(Self.starters, id: \.value) { seed in
                    Button {
                        onAddFact(seed)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: seed.category.symbol)
                                .foregroundStyle(seed.category.tint)
                            Text(seed.value)
                                .font(Theme.Text.chip)
                                .foregroundStyle(Theme.Colors.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Spacing.small)
                        .frame(height: 32)
                        .background(seed.category.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Theme.Spacing.large)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.Colors.separator.opacity(0.55))
        }
    }

    private static let starters = [
        QuickFactSeed(category: .foodAndDrink, value: "Vegetarian"),
        QuickFactSeed(category: .foodAndDrink, value: "Doesn’t drink alcohol"),
        QuickFactSeed(category: .foodAndDrink, value: "Likes wine"),
        QuickFactSeed(category: .askAbout, value: "The kids"),
    ]
}

/// One card: an attribute, its current values, and how sure the app is about each.
///
/// ### Why the confidence label is beneath the value and not behind a disclosure
/// A reader who has to go looking for the caveat has already believed the number. "Estimated from
/// information shared 18 July 2026" sits in the same glance as the thing it qualifies, and only
/// appears when there is something to qualify — a confirmed fact carries no decoration at all.
struct PortraitCardView: View {
    let card: PortraitCard
    let onConfirm: (PortraitValue) -> Void
    let onCorrect: (PortraitValue) -> Void
    let onDelete: (PortraitValue) -> Void
    let onOpenSource: (UUID) -> Void

    @State private var isShowingHistory = false

    private var category: QuickFactCategory { .category(for: card.attribute) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: card.attribute.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(category.tint)
                    .frame(width: 30, height: 30)
                    .background(category.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))

                Text(card.attribute.displayName)
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(card.values) { value in
                    PortraitValueRow(
                        value: value,
                        tint: category.tint,
                        onConfirm: { onConfirm(value) },
                        onCorrect: { onCorrect(value) },
                        onDelete: { onDelete(value) },
                        onOpenSource: onOpenSource
                    )
                }

                if card.historyCount > 0 {
                    Button {
                        isShowingHistory = true
                    } label: {
                        Text(card.historyCount == 1 ? "1 earlier value" : "\(card.historyCount) earlier values")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Nothing is ever overwritten — see what this used to say")
                    .popover(isPresented: $isShowingHistory) {
                        FactHistoryPopover(attribute: card.attribute, values: card.values)
                    }
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(category.tint.opacity(0.16))
        }
        .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.attribute.displayName)
    }
}

/// One value, with its provenance and the two things that can be done to it.
struct PortraitValueRow: View {
    let value: PortraitValue
    let tint: Color
    let onConfirm: () -> Void
    let onCorrect: () -> Void
    let onDelete: () -> Void
    let onOpenSource: (UUID) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(value.text)
                    .font(Theme.Text.rowTitle)
                    .textSelection(.enabled)

                if value.confidence.needsLabel {
                    Label(value.confidence.displayName, systemImage: value.confidence.symbolName)
                        .font(Theme.Text.chip)
                        .foregroundStyle(value.isStale ? Theme.Colors.warning : Theme.Colors.secondaryText)
                        .labelStyle(.titleAndIcon)
                }

                if value.sensitivity != .normal {
                    Image(systemName: "lock")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .help("\(value.sensitivity.displayName) — never exported")
                }

                Spacer(minLength: 0)

                if isHovering {
                    actions
                }
            }

            if let sentence = value.provenanceSentence {
                Text(sentence)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let sourceID = value.sourceItemID {
                Button {
                    onOpenSource(sourceID)
                } label: {
                    Label("Where this came from", systemImage: "arrow.up.right.square")
                        .font(Theme.Text.metadata)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.link)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Still true", action: onConfirm)
            Button("Correct this…", action: onCorrect)
            Divider()
            Button("Delete Quick Fact", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityActions {
            Button("Confirm still true", action: onConfirm)
            Button("Correct", action: onCorrect)
            Button("Delete quick fact", action: onDelete)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button(action: onConfirm) {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Still true — confirms without changing it")
            .accessibilityLabel("Confirm still true")

            Button(action: onCorrect) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Correct this — the previous value is kept")
            .accessibilityLabel("Correct")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this quick fact")
            .accessibilityLabel("Delete quick fact")
        }
        .font(Theme.Text.metadata)
    }

    /// Spoken as one sentence, with the hedge included.
    ///
    /// VoiceOver reading "approximately 7 to 8 years old" and then, separately, "estimated" would let
    /// a listener act on the first half. One label keeps them inseparable.
    private var accessibilityDescription: String {
        var parts = [value.text]
        if value.confidence.needsLabel { parts.append(value.confidence.displayName.lowercased()) }
        if let sentence = value.provenanceSentence { parts.append(sentence) }
        return parts.joined(separator: ". ")
    }
}

/// What a fact used to say.
struct FactHistoryPopover: View {
    let attribute: FactAttribute
    let values: [PortraitValue]

    @Environment(\.services) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("\(attribute.displayName) over time")
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            ForEach(values) { value in
                VStack(alignment: .leading, spacing: 1) {
                    Text(value.text)
                        .font(Theme.Text.rowSubtitle)
                    Text("Recorded \(value.observedOn.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Text("Correcting a fact keeps what it used to say. Nothing here was ever overwritten.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 280, alignment: .leading)
    }
}

/// Facts the app has stopped vouching for.
///
/// A banner rather than a badge on each card: the useful action is "go through these", and scattering
/// the prompt across six cards turns a five-minute tidy into a hunt.
struct StaleFactsBanner: View {
    let count: Int

    var body: some View {
        Label(
            count == 1
                ? "One fact has not been confirmed in a while."
                : "\(count) facts have not been confirmed in a while.",
            systemImage: "clock.badge.questionmark"
        )
        .font(Theme.Text.rowSubtitle)
        .foregroundStyle(Theme.Colors.secondaryText)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.Colors.warning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        )
        .accessibilityIdentifier(AccessibilityID.People.staleFacts)
    }
}

// MARK: - Relationships

/// Who this person is connected to, and the four ways of looking at it.
struct PersonRelationshipsSection: View {
    @Environment(\.services) private var services

    let person: Item
    let onOpenChart: (RelationshipChartKind) -> Void
    let onOpenPerson: (UUID) -> Void

    @State private var isAddingRelationship = false
    @State private var relationships: [PersonRelationship] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                SectionHeader("Relationships", count: relationships.isEmpty ? nil : relationships.count)
                Spacer()

                Menu {
                    ForEach(RelationshipChartKind.allCases) { kind in
                        Button {
                            onOpenChart(kind)
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("Charts", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(Theme.Text.rowSubtitle)
                .accessibilityIdentifier(AccessibilityID.People.charts)

                Button {
                    isAddingRelationship = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(Theme.Text.rowSubtitle)
                .accessibilityLabel("Add a relationship")
            }

            if relationships.isEmpty {
                Text("Nobody linked yet. Add a partner, a child, a colleague — or type “\(person.displayTitle) son Jack” in the command bar.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.small) {
                        ForEach(relationships, id: \.id) { relationship in
                            if let other = relationship.other {
                                RelatedPersonChip(
                                    name: other.displayTitle,
                                    label: relationship.displayLabel,
                                    colorName: other.colorName,
                                    isPlaceholder: other.personProfile?.isPlaceholder ?? false
                                ) {
                                    onOpenPerson(other.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.hairline)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .task(id: person.id) { reload() }
        .sheet(isPresented: $isAddingRelationship) {
            AddRelationshipSheet(person: person) { isAddingRelationship = false; reload() }
        }
    }

    private func reload() {
        guard let services else { return }
        relationships = (try? services.persons.relationships(of: person)) ?? []
    }
}

struct RelatedPersonChip: View {
    let name: String
    let label: String
    let colorName: String?
    let isPlaceholder: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.small) {
                PersonAvatar(name: name, colorName: colorName, size: 26)

                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(Theme.Text.rowSubtitle)
                        .lineLimit(1)
                    Text(isPlaceholder ? "\(label) · sketch" : label)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(Theme.Colors.subtleFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isPlaceholder ? "\(name) — a lightweight record with no details yet" : name)
        .accessibilityLabel("\(name), \(label)")
    }
}

// MARK: - Timeline

/// Everything that has happened, newest first.
struct PersonTimelineSection: View {
    let entries: [PersonTimelineEntry]
    @Binding var filter: TimelineGrouping.Filter
    let dateProvider: any DateProvider
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                SectionHeader("History", count: filtered.count)
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(TimelineGrouping.Filter.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Filter the history")
            }

            if filtered.isEmpty {
                EmptyStateView(
                    symbolName: "clock",
                    headline: entries.isEmpty ? "Nothing yet" : "Nothing of that kind",
                    message: entries.isEmpty
                        ? "Notes, meetings, and tasks that mention this person appear here automatically."
                        : "Try a different filter."
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(grouped, id: \.month) { group in
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        Text(group.month.formatted(.dateTime.month(.wide).year()))
                            .font(Theme.Text.sectionHeader)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .padding(.top, Theme.Spacing.small)

                        ForEach(group.entries) { entry in
                            TimelineEntryRow(entry: entry, dateProvider: dateProvider) { onOpen(entry.id) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .accessibilityIdentifier(AccessibilityID.People.timeline)
    }

    private var filtered: [PersonTimelineEntry] {
        entries.filter(filter.matches)
    }

    private var grouped: [(month: Date, entries: [PersonTimelineEntry])] {
        TimelineGrouping.byMonth(filtered, calendar: dateProvider.calendar)
    }
}

struct TimelineEntryRow: View {
    let entry: PersonTimelineEntry
    let dateProvider: any DateProvider
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                VStack(spacing: 0) {
                    Image(systemName: entry.kind.symbolName)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(entry.isContact ? Theme.Colors.selection : Theme.Colors.secondaryText)
                        .frame(width: Theme.Size.rowGlyph)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(entry.title)
                            .font(entry.isOpen ? Theme.Text.rowTitleEmphasised : Theme.Text.rowTitle)
                            .lineLimit(1)

                        if entry.isPromise {
                            Label("task", systemImage: "checkmark.circle")
                                .font(Theme.Text.chip)
                                .foregroundStyle(Theme.Colors.selection)
                                .labelStyle(.titleAndIcon)
                        }

                        Spacer(minLength: Theme.Spacing.small)

                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }

                    Text(entry.provenanceLine)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    if let excerpt = entry.excerpt {
                        Text(excerpt)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(2)
                    }

                    if !entry.tagSlugs.isEmpty {
                        TagChipRow(slugs: entry.tagSlugs)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title). \(entry.provenanceLine). \(entry.date.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityAddTraits(.isButton)
    }
}
