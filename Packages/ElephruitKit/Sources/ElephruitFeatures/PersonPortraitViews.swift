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
                // No explanatory subtitle. NOTES and CONTACT beside it have none, and a heading that
                // needs a gloss is a heading that is not doing its job — "Quick Facts" is already the
                // useful things to remember.
                SectionHeader("Quick Facts", count: factCount)
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

    /// What the Quick Facts section says before anything has been recorded.
    ///
    /// ### Why the card went
    /// It was a sparkle glyph in a tinted rounded square, a headline — "Build a better mental
    /// picture" — a line of encouragement, and four filled pastel chips, all inside a bordered card.
    /// That is the generic assistant-dashboard idiom, and this app is not that: the rest of it is
    /// quiet, and one screen adopting a different voice reads as a component borrowed from somewhere
    /// else.
    ///
    /// The worse problem was the chips. Recorded facts render as filled tinted chips too, so four
    /// suggestions — "Vegetarian", "Likes wine" — sat under a real person's name looking exactly
    /// like things somebody had actually written down about them. Nothing distinguished an offer
    /// from a record. On a screen whose entire purpose is holding true things about people, that is
    /// the one confusion worth spending layout on avoiding.
    ///
    /// A leading `plus` on each one, and a real bordered control rather than a chip, says *this adds
    /// something* instead of *this is so*. The heading above already says "Quick Facts", so the
    /// section needs a sentence, not a pep talk.
    private var quickFactEmptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Nothing recorded yet. Add what you would want to remember before seeing \(person.displayTitle) again.")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ElephruitDesign.FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
                ForEach(Self.starters, id: \.value) { seed in
                    Button {
                        onAddFact(seed)
                    } label: {
                        Label(seed.value, systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Add fact: \(seed.value)")
                }
            }
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
    @State private var relationshipKind: RelationshipKind = .friend
    @State private var editingRelationship: PersonRelationship?
    @State private var childFactTarget: Item?
    @State private var relationships: [PersonRelationship] = []
    @State private var childPortraits: [UUID: PersonPortrait] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                SectionHeader("Relationships", count: relationships.isEmpty ? nil : relationships.count)
                Spacer()

                // ### Why three controls became two
                // *Charts*, *Add Child* and *Add* sat in a row at three different weights, and the
                // middle one is a shortcut to the third with an argument pre-filled. A header that
                // spends a third of its width on a shortcut reads as three equally important things
                // to do, none of which is what somebody came to this section for. The shortcut is
                // still one click — it is now the first line of the menu it belonged in.
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
                .font(Theme.Text.metadata)
                .accessibilityIdentifier(AccessibilityID.People.charts)

                Menu {
                    Button {
                        relationshipKind = .child
                        isAddingRelationship = true
                    } label: {
                        Label("Child…", systemImage: "figure.and.child.holdinghands")
                    }

                    Button {
                        relationshipKind = .partner
                        isAddingRelationship = true
                    } label: {
                        Label("Partner…", systemImage: "heart")
                    }

                    Divider()

                    Button {
                        relationshipKind = .friend
                        isAddingRelationship = true
                    } label: {
                        Label("Somebody Else…", systemImage: "person.badge.plus")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(Theme.Text.metadata)
                .accessibilityLabel("Add a relationship")
            }

            if relationships.isEmpty {
                Text("Nobody linked yet. Add a partner, a child, a colleague — or type “\(person.displayTitle) son Jack” in the command bar.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // ### Why children get cards and everybody else gets chips
                // Because the two are asked about differently. A child is somebody you are keeping a
                // running picture of — an age, a school year, what they are into this month — and a
                // card is the only shape that can hold four facts and invite a fifth. A colleague is
                // somebody you want to recognise and click through to, which is a name and a label.
                // The same treatment for both would either bloat the colleagues into cards holding
                // nothing or shrink the children into names with no room for what is known.
                //
                // What was missing was saying so. Two differently-shaped groups with no headers read
                // as one group rendered inconsistently.
                if !children.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        SectionHeader(children.count == 1 ? "Child" : "Children")

                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 210, maximum: 320), spacing: Theme.Spacing.small),
                            ],
                            alignment: .leading,
                            spacing: Theme.Spacing.small
                        ) {
                            ForEach(children, id: \.id) { relationship in
                                if let child = relationship.other {
                                    ChildProfileCard(
                                        child: child,
                                        portrait: childPortraits[child.id],
                                        onOpen: { onOpenPerson(child.id) },
                                        onAddDetail: { childFactTarget = child },
                                        onEdit: { editingRelationship = relationship }
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !otherRelationships.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        if !children.isEmpty {
                            SectionHeader("Everybody else")
                        }

                        // Wrapping rather than scrolling sideways. A horizontal scroller inside a
                        // vertically scrolling pane is a second direction of scrolling nobody finds,
                        // and it hid every relationship past the fourth.
                        ElephruitDesign.FlowLayout(
                            spacing: Theme.Spacing.small,
                            lineSpacing: Theme.Spacing.small
                        ) {
                            ForEach(otherRelationships, id: \.id) { relationship in
                                if let other = relationship.other {
                                    RelatedPersonChip(
                                        name: other.displayTitle,
                                        label: relationship.displayLabel,
                                        colorName: other.colorName,
                                        isPlaceholder: other.personProfile?.isPlaceholder ?? false
                                    ) {
                                        onOpenPerson(other.id)
                                    } onEdit: {
                                        editingRelationship = relationship
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .task(id: person.id) { reload() }
        .sheet(isPresented: $isAddingRelationship) {
            AddRelationshipSheet(person: person, initialKind: relationshipKind) {
                isAddingRelationship = false
                reload()
            }
        }
        .sheet(item: $editingRelationship) { relationship in
            EditRelationshipSheet(person: person, relationship: relationship) {
                editingRelationship = nil
                reload()
            }
        }
        .sheet(item: $childFactTarget) { child in
            AddFactSheet(
                personName: child.displayTitle,
                onSave: { draft, confidence, sensitivity, observedOn in
                    addFact(draft, to: child, confidence: confidence, sensitivity: sensitivity, observedOn: observedOn)
                    childFactTarget = nil
                },
                onCancel: { childFactTarget = nil }
            )
        }
    }

    private var children: [PersonRelationship] {
        relationships.filter { $0.kind == .child }
    }

    private var otherRelationships: [PersonRelationship] {
        relationships.filter { $0.kind != .child }
    }

    private func reload() {
        guard let services else { return }
        relationships = (try? services.persons.relationships(of: person)) ?? []
        childPortraits = Dictionary(uniqueKeysWithValues: relationships.compactMap { relationship in
            guard relationship.kind == .child, let child = relationship.other,
                  let portrait = try? services.personWorkspace.portrait(of: child)
            else { return nil }
            return (child.id, portrait)
        })
    }

    private func addFact(
        _ draft: ObservationDraft,
        to child: Item,
        confidence: FactConfidence,
        sensitivity: FactSensitivity,
        observedOn: Date
    ) {
        guard let services else { return }
        services.perform {
            try services.persons.record(
                draft,
                about: child,
                observedOn: observedOn,
                confidence: confidence,
                sensitivity: sensitivity,
                source: nil
            )
            services.noteChange(to: child)
        }
        reload()
    }
}

/// One child, with whatever is known about them.
///
/// ### Why this used to look wrong, and what changed
/// It was a pink card: a pink wash, a pink border, and pink glyphs on every fact inside it. Three
/// problems, in ascending order of seriousness. It named a literal colour, which is wrong in at
/// least one of light mode, dark mode, Increase Contrast, and a non-default accent — the exact
/// failure `SourceHygieneTests` exists to catch and did not, because a bare `Color.pink` is not a
/// constructor. It stacked a fill *and* a stroke on a surface that already sits inside a padded
/// pane, which is the decoration-accumulation `decorationDoesNotAccumulate` describes. And the
/// colour meant nothing: pink for children is a decision about who these people are, made by the
/// software, in a section that is otherwise scrupulous about not doing that.
///
/// Now the card is the same neutral fill every other grouped surface in the app uses, and the only
/// colour on it is the person's *own* — the avatar tint they already carry everywhere else. The
/// provenance line, which said "Elephruit only" on every single card, is a lock glyph with the
/// sentence in its tooltip: it is worth being able to check and not worth a line of every card.
private struct ChildProfileCard: View {
    let child: Item
    let portrait: PersonPortrait?
    let onOpen: () -> Void
    let onAddDetail: () -> Void
    let onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.tight) {
                Button(action: onOpen) {
                    HStack(spacing: Theme.Spacing.small) {
                        PersonAvatar(name: child.displayTitle, colorName: child.colorName, size: 34)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: Theme.Spacing.tight) {
                                Text(child.displayTitle)
                                    .font(.system(.callout, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.primaryText)
                                    .lineLimit(1)

                                if child.personProfile?.contactsIdentifier == nil {
                                    Image(systemName: "lock.shield")
                                        .font(Theme.Text.metadata)
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                        .help("Held in Elephruit only — never written to your address book")
                                        .accessibilityLabel("Elephruit only")
                                }
                            }

                            Text(detail)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .lineLimit(2)
                        }

                        Spacer(minLength: Theme.Spacing.tight)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                // A word rather than a glyph, for the reason set out on ``RelatedPersonChip``: an
                // unlabelled `…` is the one route to changing or removing this relationship, and it
                // reads as decoration. "Relationship" says which of the several things on this card
                // the button acts on, which "Edit" on its own would not.
                Button("Relationship", systemImage: "pencil", action: onEdit)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(Theme.Text.metadata)
                    .help("Change or remove this relationship")
                    .accessibilityLabel("Relationship with \(child.displayTitle)")
                    .accessibilityHint("Change or remove this relationship")
            }

            if !summaryFacts.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    ForEach(summaryFacts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                            Image(systemName: fact.symbol)
                                .foregroundStyle(Theme.Colors.familyAccent)
                                .frame(width: 14)

                            Text(fact.text)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.primaryText)
                                .lineLimit(2)

                            if fact.isUncertain {
                                Text("Unconfirmed")
                                    .font(Theme.Text.chip)
                                    .foregroundStyle(Theme.Colors.warning)
                            }
                        }
                    }
                }
            }

            Button("Add detail", systemImage: "plus.circle", action: onAddDetail)
                .buttonStyle(.borderless)
                .font(Theme.Text.metadata)
                .opacity(isHovering || summaryFacts.isEmpty ? 1 : 0)
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.familyAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colors.familyAccent.opacity(0.15))
        }
        .onHover { isHovering = $0 }
        .calmAnimation(value: isHovering)
        .help("Open \(child.displayTitle) to add age, school, interests, and notes")
        .contextMenu {
            Button("Edit Relationship…", systemImage: "pencil", action: onEdit)
        }
    }

    private var detail: String {
        if let line = portrait?.ageAndGradeLine { return line }
        if child.personProfile?.isPlaceholder == true { return "Sketch · add age, school, and interests" }
        return "Add age, school, and interests"
    }

    private var summaryFacts: [ChildSummaryFact] {
        guard let portrait else { return [] }
        return portrait.cards
            .filter { $0.attribute != .observedAge && $0.attribute != .schoolGrade }
            .flatMap { card in
                card.values.map {
                    ChildSummaryFact(
                        id: $0.id,
                        text: $0.text,
                        symbol: card.attribute.symbolName,
                        isUncertain: $0.confidence.needsLabel
                    )
                }
            }
            .prefix(4)
            .map { $0 }
    }
}

private struct ChildSummaryFact: Identifiable {
    let id: UUID
    let text: String
    let symbol: String
    let isUncertain: Bool
}

struct RelatedPersonChip: View {
    let name: String
    let label: String
    let colorName: String?
    let isPlaceholder: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.hairline) {
            Button(action: onOpen) {
                HStack(spacing: Theme.Spacing.small) {
                    PersonAvatar(name: name, colorName: colorName, size: 26)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(name)
                            .font(Theme.Text.rowSubtitle)
                            .lineLimit(1)

                        if isPlaceholder {
                            Text("sketch")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.tight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ### Why the relationship type *is* the control
            // Editing and deleting a relationship both worked and both had a confirmation. The only
            // way in was a bare `…` with a tooltip, beside the relationship type drawn as static
            // text — so the one thing on the chip a person would want to change looked like a label,
            // and the thing that changed it looked like nothing in particular.
            //
            // Making the type itself the button says both facts in one control: this is the
            // relationship, and this is what you press to change it. The chevron is what makes it
            // read as editable rather than as a caption, and the whole word is the hit target rather
            // than a 24-point circle.
            //
            // The context menu stays, as a second route rather than the only one.
            Button(action: onEdit) {
                HStack(spacing: Theme.Spacing.hairline) {
                    Text(label)
                        .font(Theme.Text.metadata)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(Theme.Text.keyHint)
                }
                .foregroundStyle(Theme.Colors.secondaryText)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.tight)
                .background(Theme.Colors.subtleFill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Change or remove this relationship")
            .accessibilityLabel("Relationship with \(name): \(label)")
            .accessibilityHint("Change or remove this relationship")
        }
        .padding(.trailing, Theme.Spacing.tight)
        .background(Theme.Colors.subtleFill, in: Capsule())
        .help(isPlaceholder ? "\(name) — a lightweight record with no details yet" : name)
        .contextMenu {
            Button("Change Relationship…", systemImage: "pencil", action: onEdit)
        }
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
